//
//  ContainerMountStore.swift
//  AppPorts
//

import Darwin
import Foundation

/// Atomic mount, legacy-cleanup, and data-transfer document. Execution must use the throwing reads.
final class ContainerMountStore: @unchecked Sendable {
    static let shared = ContainerMountStore()

    /// Test hosts may initialize shared services before an individual test can inject its fixture.
    /// Keep that default document outside the user's Application Support directory for the entire process.
    private static let isolatedTestFileURL: URL? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPortsTestRecords-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("container-mounts.plist")
    }()

    private static var defaultFileURL: URL {
        if let isolatedTestFileURL { return isolatedTestFileURL }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AppPorts/container-mounts.plist")
    }
    private static let registryLock = NSLock()
    private static var fileLocks: [String: NSLock] = [:]
    private static func lock(for url: URL) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = fileLocks[key] { return existing }
        let value = NSLock()
        fileLocks[key] = value
        return value
    }

    private let fileURL: URL
    /// The privileged deletion preflight binds the exact current document;
    /// the elevated command never writes this ledger.
    var fileURLForDeletionAuthorization: URL { fileURL }
    private let fileManager = FileManager.default
    private let lock: NSLock
    private let writeData: @Sendable (Data, URL) throws -> Void
    // Protected by the store lock. Only facts about immutable manifest bytes
    // are reusable; the document and filesystem are always read again.
    private let baselineValidation = BaselineValidation()

    private struct Document: Codable, Equatable {
        var schemaVersion = 3
        var mounts: [ContainerMountRecord] = []
        var cleanups: [ContainerCleanupRecord] = []
        var transfers: [DataTransferRecord] = []
        var managedLinks: [ManagedDataLinkRecord] = []
        var remountInterventions: [String: String] = [:]
        var manualMountPauses: [String: String] = [:]
        var preservedMaterials: [DataTransferMaterial] = []

        enum CodingKeys: String, CodingKey { case schemaVersion, mounts, cleanups, transfers, managedLinks, remountInterventions, preservedMaterials, manualMountPauses }
        init(mounts: [ContainerMountRecord] = []) { self.mounts = mounts }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            guard (2...13).contains(schemaVersion) else { throw StoreError.unsupportedSchema(schemaVersion) }
            manualMountPauses = try values.decodeIfPresent([String: String].self, forKey: .manualMountPauses) ?? [:]
            mounts = try values.decode([ContainerMountRecord].self, forKey: .mounts)
            cleanups = try values.decode([ContainerCleanupRecord].self, forKey: .cleanups)
            transfers = schemaVersion == 2 ? [] : try values.decode([DataTransferRecord].self, forKey: .transfers)
            managedLinks = schemaVersion == 2 ? [] : try values.decodeIfPresent([ManagedDataLinkRecord].self, forKey: .managedLinks) ?? []
            remountInterventions = schemaVersion == 2 ? [:] : try values.decodeIfPresent([String: String].self, forKey: .remountInterventions) ?? [:]
            preservedMaterials = try values.decodeIfPresent([DataTransferMaterial].self, forKey: .preservedMaterials) ?? []
        }
    }

    enum StoreError: LocalizedError, Sendable {
        case unreadable
        case unsupportedSchema(Int)
        case invalidState(String)
        case conflict(String)
        case missingTransfer(UUID)
        case deletionNotConfirmed
        var errorDescription: String? {
            // Existing localized message is intentionally shared; associated facts go to diagnostics.
            return "迁移记录无法读取，数据和记录已保留，未继续更改。".localized
        }
    }

    init(fileURL: URL? = nil,
         writeData: @escaping @Sendable (Data, URL) throws -> Void = { try DurableFileIO.write($0, to: $1) }) {
        let resolved = fileURL ?? Self.defaultFileURL
        self.fileURL = resolved
        self.lock = Self.lock(for: resolved)
        self.writeData = writeData
    }

    /// Check the live writers for this dataset again at each mutation boundary.
    /// Injected fixture stores remain independent of the user's running app.
    func recheckWriterAdmission() throws {
        try WriterAdmission.recheck(dataDirectory: fileURL.deletingLastPathComponent())
    }

    struct Inspection: Sendable {
        let mounts: [ContainerMountRecord]
        let cleanups: [ContainerCleanupRecord]
        let transfers: [DataTransferRecord]
        let managedLinks: [ManagedDataLinkRecord]
        let remountInterventions: [String: String]
        let preservedMaterials: [DataTransferMaterial]
        let validationError: StoreError?
    }

    /// Parsed facts for diagnostics only; conflicting records are preserved in original order.
    /// Callers must surface validationError and must not execute from this snapshot.
    func recordsForInspection() throws -> Inspection {
        lock.lock()
        defer { baselineValidation.boundMemory(); lock.unlock() }
        let document = try load(validateState: false)
        var failure: StoreError?
        do { try validate(document, using: baselineValidation) }
        catch let error as StoreError { failure = error }
        return Inspection(mounts: document.mounts, cleanups: document.cleanups, transfers: document.transfers,
                          managedLinks: document.managedLinks, remountInterventions: document.remountInterventions,
                          preservedMaterials: document.preservedMaterials, validationError: failure)
    }

    /// Display fallback only. A failed read must never authorize an operation.
    func records() -> [ContainerMountRecord] {
        do { return try recordsStrict() }
        catch {
            AppLogger.shared.logError("挂载记录无法读取，保留原文件", error: error,
                errorCode: "CONTAINER-MOUNT-STORE-CORRUPT", relatedURLs: [("file", fileURL)])
            return []
        }
    }

    func isManuallyUnmounted(_ record: ContainerMountRecord) throws -> Bool {
        try read { $0.manualMountPauses[record.volumeUUID.uppercased()] == record.mountPointPath }
    }

    /// The caller holds OperationLock across saving intent and changing mounts.
    func setManuallyUnmounted(_ paused: Bool, record: ContainerMountRecord) throws {
        try mutate { document in
            guard document.mounts.contains(record) else { throw StoreError.conflict(record.mountPointPath) }
            document.manualMountPauses[record.volumeUUID.uppercased()] = paused ? record.mountPointPath : nil
        }
    }

    func manualMountPauseBlocks(_ transfer: DataTransferRecord) throws -> Bool {
        try read { document in
            document.manualMountPauses.contains { uuid, path in
                [transfer.originalPath, transfer.activePath, transfer.destinationPath].contains(path)
                    || [transfer.createdVolumeUUID, transfer.sourceIdentity.volumeUUID,
                        transfer.recoveryMountRecord?.volumeUUID].compactMap { $0?.uppercased() }.contains(uuid)
            }
        }
    }

    func remountIntervention(forVolumeUUID uuid: String) throws -> String? {
        try read { $0.remountInterventions[uuid.uppercased()] }
    }
    func setRemountIntervention(volumeUUID uuid: String, reason: String?) throws {
        try mutate { document in
            guard document.mounts.contains(where: { self.sameUUID($0.volumeUUID, uuid) }) else {
                throw StoreError.conflict("No recorded mount owns this intervention")
            }
            if let reason, reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw StoreError.invalidState("Intervention requires an explanation")
            }
            document.remountInterventions[uuid.uppercased()] = reason
        }
    }

    func recordsStrict() throws -> [ContainerMountRecord] {
        try read { $0.mounts.sorted { $0.createdAt < $1.createdAt } }
    }
    func pendingCleanups() throws -> [ContainerCleanupRecord] { try read { $0.cleanups } }
    func preservedMaterials() throws -> [DataTransferMaterial] { try read { $0.preservedMaterials } }

    /// Update scheduling only, using the current journal rather than a stale
    /// pre-recovery record. Deleted records remain deleted.
    func recordCleanupRetry(_ target: CleanupRetryTarget, failed: Bool, now: Date = Date()) throws {
        try mutate { current in
            func state(_ count: Int?) -> (Int?, Date?) {
                guard failed else { return (nil, nil) }
                let next = CleanupRetryBackoff.afterFailure(count ?? 0, now: now)
                return (next.count, next.nextAttempt)
            }
            switch target {
            case .transfer(let id):
                guard let index = current.transfers.firstIndex(where: { $0.operationID == id }) else { return }
                (current.transfers[index].retryFailureCount, current.transfers[index].nextAutomaticRetryAt)
                    = state(current.transfers[index].retryFailureCount)
            case .legacy(let id):
                guard let index = current.cleanups.firstIndex(where: { $0.id == id }) else { return }
                (current.cleanups[index].retryFailureCount, current.cleanups[index].nextAutomaticRetryAt)
                    = state(current.cleanups[index].retryFailureCount)
            case .material(let id):
                guard let index = current.preservedMaterials.firstIndex(where: { $0.id == id }) else { return }
                (current.preservedMaterials[index].retryFailureCount, current.preservedMaterials[index].nextAutomaticRetryAt)
                    = state(current.preservedMaterials[index].retryFailureCount)
            }
        }
    }
    func preservedMaterial(id: UUID) throws -> DataTransferMaterial? {
        try read { $0.preservedMaterials.first { $0.id == id } }
    }


    func checkpointPreservedRemoval(_ baseline: Data, expected: DataTransferMaterial) throws -> DataTransferMaterial {
        var updated = expected
        try mutate { current in
            guard let index = current.preservedMaterials.firstIndex(of: expected),
                  var recovery = expected.recoveryRecord,
                  recovery.preparationRemovalBaseline == nil else {
                throw StoreError.conflict("Preserved removal checkpoint changed")
            }
            recovery.preparationRemovalBaseline = baseline
            recovery.preparationRemovalParentIdentity = recovery.preparationParentIdentity
            updated.recoveryRecord = recovery
            current.preservedMaterials[index] = updated
        }
        return updated
    }

    /// Remove only the exact summary the service inspected. This mutation
    /// grants no filesystem or volume deletion authority and reserves no path.
    func removePreservedMaterialRecord(_ expected: DataTransferMaterial) throws {
        try mutate { current in
            guard let index = current.preservedMaterials.firstIndex(where: { $0.id == expected.id }),
                  current.preservedMaterials[index] == expected else {
                throw StoreError.conflict("Preserved material summary changed")
            }
            current.preservedMaterials.remove(at: index)
        }
    }
    func transfers() throws -> [DataTransferRecord] {
        try read { $0.transfers.sorted { $0.createdAt == $1.createdAt ? $0.operationID.uuidString < $1.operationID.uuidString : $0.createdAt < $1.createdAt } }
    }

    /// Explicitly detach this exact symlink entry. Old copies remain historical
    /// material and no longer reserve the entry or participate in automatic completion.
    func detachSymlinkHistory(at local: URL, transfers expected: [DataTransferRecord],
                              link expectedLink: ManagedDataLinkRecord?, reason: String,
                              verifyingFilesystem: () throws -> Void) throws {
        try mutate { current in
            let related = current.transfers.filter { $0.originalPath == local.path }
            let links = current.managedLinks.filter { $0.originalPath == local.path }
            let ids = Set(expected.map(\.operationID))
            guard !reason.isEmpty, related.count == expected.count,
                  related.allSatisfy({ expected.contains($0) && $0.mode == .symlink }),
                  links == (expectedLink.map({ [$0] }) ?? []),
                  !current.transfers.contains(where: {
                      !ids.contains($0.operationID) && $0.priorOperationID.map(ids.contains) == true
                  }),
                  !current.managedLinks.contains(where: {
                      $0.originalPath != local.path && ids.contains($0.operationID)
                  }) else {
                throw StoreError.conflict("Symlink history changed or belongs to another path")
            }
            try verifyingFilesystem()
            for transfer in related {
                guard !current.preservedMaterials.contains(where: { $0.id == transfer.operationID }) else {
                    throw StoreError.conflict("Transfer already has preserved material")
                }
                current.preservedMaterials.append(DataTransferMaterial(transfer: transfer, reason: reason))
            }
            if let link = expectedLink, !ids.contains(link.operationID) {
                guard !current.preservedMaterials.contains(where: { $0.id == link.operationID }) else {
                    throw StoreError.conflict("Link already has preserved material")
                }
                current.preservedMaterials.append(DataTransferMaterial(detachedLink: link, reason: reason))
            }
            current.transfers.removeAll { ids.contains($0.operationID) }
            current.managedLinks.removeAll { $0.originalPath == local.path }
        }
    }

    func managedLinks() throws -> [ManagedDataLinkRecord] { try read { $0.managedLinks.sorted { $0.originalPath < $1.originalPath } } }
    func managedLink(forOriginalPath path: String) throws -> ManagedDataLinkRecord? {
        try managedLinks().first { DataPathTopology.relationship($0.originalPath, path) == .same }
    }
    func upsertManagedLink(_ link: ManagedDataLinkRecord) throws {
        try mutate { try self.putLink(link, into: &$0) }
    }
    /// Startup only returns durable facts, including cleanupRequested; it never deletes or resumes work.
    func unfinishedTransfers() throws -> [DataTransferRecord] { try transfers() }
    func transfer(operationID: UUID) throws -> DataTransferRecord? { try read { $0.transfers.first { $0.operationID == operationID } } }
    func record(forMountPoint url: URL) -> ContainerMountRecord? {
        records().first { DataPathTopology.relationship($0.mountPointPath, url.path) == .same }
    }

    func upsert(_ record: ContainerMountRecord) throws {
        try mutate { current in try self.putMount(record, into: &current) }
    }
    func remove(mountPointPath: String) throws {
        try mutate { current in
            guard !current.transfers.contains(where: { DataPathTopology.relationship($0.originalPath, mountPointPath) == .same }) else {
                throw StoreError.conflict("Use the transfer transaction to remove an active mount")
            }
            current.mounts.removeAll { DataPathTopology.relationship($0.mountPointPath, mountPointPath) == .same }
        }
    }

    // Existing schema-2 callers remain source compatible; they do not gain verified baselines.
    func recordMigration(_ record: ContainerMountRecord, cleanup: ContainerCleanupRecord) throws {
        try mutate { current in
            try self.putMount(record, into: &current)
            if !current.cleanups.contains(where: { $0.id == cleanup.id }) { current.cleanups.append(cleanup) }
        }
    }
    func beginRestore(_ cleanup: ContainerCleanupRecord) throws {
        try mutate { current in
            try self.checkLegacyMutation(cleanup.mountRecord.mountPointPath, current)
            current.mounts.removeAll { $0.mountPointPath == cleanup.mountRecord.mountPointPath }
            if !current.cleanups.contains(where: { $0.id == cleanup.id }) { current.cleanups.append(cleanup) }
        }
    }
    func cancelRestore(_ cleanup: ContainerCleanupRecord) throws {
        try mutate { current in
            try self.checkLegacyMutation(cleanup.mountRecord.mountPointPath, current)
            current.cleanups.removeAll { $0.id == cleanup.id }
            try self.putMount(cleanup.mountRecord, into: &current)
        }
    }
    func finishCleanup(_ id: UUID) throws { try mutate { $0.cleanups.removeAll { $0.id == id } } }

    /// Record-only completion must validate the exact displayed legacy task
    /// while holding the writer lock, including its current filesystem guards.
    func finishCleanup(_ expected: ContainerCleanupRecord, preservingDetachedVolume: Bool = false,
                       verifyingFilesystem: () throws -> Void) throws {
        try mutate { current in
            guard let recorded = current.cleanups.first(where: { $0.id == expected.id }), recorded == expected else {
                throw StoreError.conflict("Legacy cleanup record changed")
            }
            try verifyingFilesystem()
            if preservingDetachedVolume {
                guard expected.kind == .restoredVolume,
                      !current.mounts.contains(where: { self.sameUUID($0.volumeUUID, expected.mountRecord.volumeUUID) }),
                      !current.transfers.contains(where: { $0.originalPath == expected.localPath
                          && !$0.isDataSwitchComplete && $0.rollbackCompletedAt == nil }) else {
                    throw StoreError.conflict("Legacy restore still has an active operation")
                }
                current.preservedMaterials.append(DataTransferMaterial(legacyCleanup: expected, retainingDetachedVolume: true))
            }
            current.cleanups.removeAll { $0.id == expected.id }
        }
    }

    /// A stopped restore may already have removed its ordinary mount entry.
    /// Execution still validates the exact saved operation before using it.
    func recordForRestore(at path: URL) throws -> ContainerMountRecord? {
        if let record = record(forMountPoint: path) { return record }
        return try transfers().last {
            $0.mode == .mount && !$0.isDataSwitchComplete && $0.rollbackCompletedAt == nil
                && $0.originalPath == path.standardizedFileURL.path
        }?.recoveryMountRecord
    }

    /// Call before any copy, rename, or volume creation. Exact retries have no side effects.
    func beginTransfer(_ transfer: DataTransferRecord) throws {
        try mutate { current in
            if let previous = current.transfers.first(where: { $0.operationID == transfer.operationID }) {
                guard previous == transfer else { throw StoreError.conflict("Operation ID already has different intent") }
                return
            }
            guard transfer.phase == .preparing else { throw StoreError.invalidState("New intent must be preparing") }
            if let prior = transfer.priorOperationID {
                guard current.transfers.contains(where: { $0.operationID == prior })
                    || current.managedLinks.contains(where: { $0.operationID == prior }) else {
                    throw StoreError.conflict("Referenced migration is missing")
                }
            }
            current.transfers.append(transfer)
        }
    }

    /// Supersede bookkeeping for this exact live volume without granting any
    /// permission to delete its old files. Other cleanup reservations stay put.
    func reconcileLegacyCleanups(for record: ContainerMountRecord) throws {
        let related = try pendingCleanups().filter {
            $0.mountRecord.mountPointPath == record.mountPointPath
                && sameUUID($0.mountRecord.volumeUUID, record.volumeUUID)
        }
        guard !related.isEmpty else { return }
        try mutate { current in
            guard current.mounts.contains(record), related.allSatisfy({ current.cleanups.contains($0) }) else {
                throw StoreError.conflict("Restore mount or legacy cleanup changed")
            }
            for cleanup in related {
                let material = DataTransferMaterial(legacyCleanup: cleanup)
                if !material.paths.isEmpty {
                    guard !current.preservedMaterials.contains(where: { $0.id == material.id }) else {
                        throw StoreError.conflict("Legacy cleanup already has different preserved material")
                    }
                    current.preservedMaterials.append(material)
                }
            }
            let ids = Set(related.map(\.id))
            current.cleanups.removeAll { ids.contains($0.id) }
        }
    }

    /// Filesystem rollback is complete before this atomic journal update.
    /// It restores the original mount authority and releases this attempt's
    /// reservation together, so the ordinary operation can be retried.
    func finishAutomaticMountRollback(_ expected: DataTransferRecord, preserving reason: String? = nil,
                                      additionalMaterialPaths: [String] = [],
                                      verifyingFilesystem: () throws -> Void) throws {
        try mutate { current in
            guard expected.mode == .mount, !expected.isDataSwitchComplete,
                  let index = current.transfers.firstIndex(where: { $0.operationID == expected.operationID }),
                  current.transfers[index] == expected,
                  !current.transfers.contains(where: { $0.priorOperationID == expected.operationID }) else {
                throw StoreError.conflict("Rollback operation changed or already completed")
            }
            let existing = current.mounts.first { $0.mountPointPath == expected.originalPath }
            if expected.rollbackCompletedAt != nil {
                // This record owns only obsolete staging. A later operation
                // may already have replaced the mount at the original path.
            } else if expected.direction == .restore {
                guard let record = expected.recoveryMountRecord,
                      record.mountPointPath == expected.originalPath,
                      self.sameUUID(record.volumeUUID, expected.sourceIdentity.volumeUUID),
                      existing == nil || existing == record else {
                    throw StoreError.conflict("Rollback no longer owns the original mount")
                }
                try self.putMount(record, into: &current)
                current.remountInterventions.removeValue(forKey: record.volumeUUID.uppercased())
            } else if let existing {
                guard existing == expected.recoveryMountRecord else {
                    throw StoreError.conflict("Rollback cannot remove a different mount")
                }
                current.mounts.removeAll { $0 == existing }
                current.remountInterventions.removeValue(forKey: existing.volumeUUID.uppercased())
            }
            try verifyingFilesystem()
            if let reason {
                guard !reason.isEmpty else { throw StoreError.invalidState("Preserved material requires a reason") }
                var pending = expected
                pending.rollbackCompletedAt = pending.rollbackCompletedAt ?? Date()
                pending.phase = .needsRecovery
                pending.recoverableReason = reason
                current.transfers[index] = pending
                current.schemaVersion = max(current.schemaVersion, 9)
            } else {
                current.transfers.remove(at: index)
            }
        }
    }

    /// Early 1.9.1 restores unnecessarily changed a legacy noowners volume to
    /// owners. Adopt its original read policy only when every destination UID
    /// and GID remains exactly the same. Content and identity evidence is kept.
    func adoptLegacyRestoreOwnership(_ expected: DataTransferRecord) throws -> DataTransferRecord {
        guard expected.mode == .mount, expected.direction == .restore, expected.priorOperationID == nil,
              let owner = expected.legacyRootOwnership, owner.uid == geteuid(), owner.gid == getegid(),
              (expected.originalSourceMountFlags ?? expected.legacyMountFlags).map({ $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 }) == true,
              expected.sourceBaseline != nil else { return expected }
        var result = expected
        func adapt(_ data: Data?) throws -> Data? {
            guard let data else { return nil }
            var baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: data)
            guard baseline.ownershipCompatibility == nil else { return data }
            guard baseline.restoredRootOwnership == owner,
                  baseline.entries.allSatisfy({
                      let destination = baseline.destinationEntry($0)
                      return destination.uid == owner.uid && destination.gid == owner.gid
                  }) else { return data }
            baseline.ownershipCompatibility = .init(sourceIgnoresOwnership: true,
                destinationIgnoresOwnership: false, projectedSourceOwner: owner)
            return try PropertyListEncoder().encode(baseline)
        }
        result.sourceBaseline = try adapt(expected.sourceBaseline)
        result.baseline = try adapt(expected.baseline)
        guard result != expected else { return expected }
        try mutate { current in
            guard let index = current.transfers.firstIndex(where: { $0 == expected }),
                  let record = expected.recoveryMountRecord ?? current.mounts.first(where: { $0.mountPointPath == expected.originalPath }),
                  record.ownershipPolicy == nil, self.sameUUID(record.volumeUUID, expected.sourceIdentity.volumeUUID),
                  !current.transfers.contains(where: { $0.priorOperationID == expected.operationID }) else {
                throw StoreError.conflict("Legacy ownership evidence changed")
            }
            current.transfers[index] = result
        }
        return result
    }

    /// Resume only an unchanged intent for which no copying could have begun.
    /// Caller additionally verifies expected path templates, absence and current volume.
    func resumeUnstartedMountRestore(_ expected: DataTransferRecord, record: ContainerMountRecord,
                                    useProjectedOwnership: Bool = false) throws -> DataTransferRecord {
        var resumed = expected
        try mutate { current in
            guard let index = current.transfers.firstIndex(where: { $0.operationID == expected.operationID }),
                  current.transfers[index] == expected, expected.isUnstartedMountRestore,
                  current.mounts.contains(record), expected.originalPath == record.mountPointPath,
                  self.sameUUID(expected.sourceIdentity.volumeUUID, record.volumeUUID),
                  expected.appName == record.appName, expected.bundleIdentifier == record.bundleIdentifier,
                  expected.dataDirType == record.dataDirType else { throw StoreError.conflict("Restore intent changed or already started") }
            if let priorID = expected.priorOperationID {
                guard current.transfers.contains(where: {
                    $0.operationID == priorID && $0.mode == .mount && $0.direction == .migrate
                        && $0.originalPath == expected.originalPath
                        && self.sameUUID($0.createdVolumeUUID, record.volumeUUID)
                        && [.awaitingUserVerification, .cleanupRequested].contains($0.phase)
                }) else { throw StoreError.conflict("Restore migration lineage changed") }
            }
            if useProjectedOwnership {
                // The caller has proved the legacy source still uses noowners
                // and its staging path is absent. No saved copy contract may
                // be reinterpreted, even when its destination was never claimed.
                guard record.ownershipPolicy == nil, expected.priorOperationID == nil,
                      expected.sourceBaseline == nil, expected.preparationRemovalBaseline == nil,
                      expected.preparationRemovalParentIdentity == nil else {
                    throw StoreError.conflict("Restore ownership contract already exists")
                }
                resumed.originalSourceMountFlags = resumed.originalSourceMountFlags ?? resumed.legacyMountFlags
                resumed.legacyRootOwnership = nil
                resumed.legacyMountFlags = nil
            }
            resumed.phase = .preparing
            resumed.recoverableReason = nil
            current.transfers[index] = resumed
        }
        return resumed
    }

    /// A created volume UUID can be filled once immediately after creation, never replaced.
    func updateTransfer(_ transfer: DataTransferRecord) throws {
        try mutate { current in try self.replaceTransfer(transfer, in: &current) }
    }

    /// Called under OperationLock. Compare the full journal snapshot so a
    /// decision never applies to work that advanced while its sheet was open.
    func setCleanupDisposition(_ disposition: DataTransferRecord.CleanupDisposition?,
                               expected: DataTransferRecord) throws {
        try mutate { current in
            guard let index = current.transfers.firstIndex(where: { $0.operationID == expected.operationID }),
                  current.transfers[index] == expected, expected.retainedCopyRemovedAt == nil,
                  disposition != .keep || expected.isDataSwitchComplete else {
                throw StoreError.conflict("Cleanup decision no longer matches the transfer")
            }
            current.transfers[index].cleanupDisposition = disposition
        }
    }

    func prepareCopy(operationID: UUID, path: URL, parentIdentity: DataPathIdentity,
                     baseline: TreeCopySnapshot) throws {
        try mutate { current in
            guard var transfer = current.transfers.first(where: { $0.operationID == operationID }),
                  transfer.isPreparationRecoverable else { throw StoreError.conflict("Copy preparation changed") }
            transfer.preparationPath = path.standardizedFileURL.path
            transfer.preparationParentIdentity = parentIdentity
            transfer.sourceBaseline = try PropertyListEncoder().encode(baseline)
            try self.replaceTransfer(transfer, in: &current)
        }
    }

    func claimCopyDestination(operationID: UUID, identity: DataPathIdentity) throws {
        try mutate { current in
            guard var transfer = current.transfers.first(where: { $0.operationID == operationID }),
                  transfer.isPreparationRecoverable, transfer.sourceBaseline != nil,
                  transfer.preparationParentIdentity != nil else { throw StoreError.conflict("Missing copy creation intent") }
            transfer.destinationIdentity = identity
            try self.replaceTransfer(transfer, in: &current)
        }
    }

    /// The source/entry proof runs while the exact document is writer-locked.
    /// Unknown artifacts become independent visible material before releasing
    /// the reservation; ending an attempt never grants permission to delete it.
    func endUnswitchedTransfer(_ expected: DataTransferRecord, preserving reason: String? = nil,
                               verifyingFilesystem: () throws -> Void) throws {
        try mutate { current in
            guard let index = current.transfers.firstIndex(where: { $0.operationID == expected.operationID }),
                  current.transfers[index] == expected, !expected.isDataSwitchComplete,
                  !current.transfers.contains(where: { $0.priorOperationID == expected.operationID }),
                  !current.managedLinks.contains(where: { $0.operationID == expected.operationID }) else {
                throw StoreError.conflict("Attempt has changed or already switched")
            }
            try verifyingFilesystem()
            if let reason {
                guard !reason.isEmpty else { throw StoreError.invalidState("Preserved material requires a reason") }
                current.preservedMaterials.removeAll { $0.id == expected.operationID }
                current.preservedMaterials.append(DataTransferMaterial(transfer: expected, reason: reason))
            }
            current.transfers.remove(at: index)
        }
    }

    /// Only forget an exact unstarted intent. Filesystem verification runs under
    /// the document's writer lock; this method never removes any data directory.
    func cancelUnstartedMigration(_ expected: DataTransferRecord, verifyingFilesystem: () throws -> Void) throws {
        try mutate { current in
            guard let index = current.transfers.firstIndex(where: { $0.operationID == expected.operationID }),
                  current.transfers[index] == expected, expected.isUnstartedSymlinkMigration,
                  !current.transfers.contains(where: { $0.priorOperationID == expected.operationID }),
                  !current.managedLinks.contains(where: { $0.operationID == expected.operationID }) else {
                throw StoreError.conflict("Migration intent changed, has related operations or already started")
            }
            try verifyingFilesystem()
            current.transfers.remove(at: index)
        }
    }

    /// A failed restore that created no copy can release its reservation. The
    /// indexed external data stays managed and available for the next attempt.
    func cancelUnstartedSymlinkRestore(_ expected: DataTransferRecord, verifyingFilesystem: () throws -> Void) throws {
        try mutate { current in
            guard let index = current.transfers.firstIndex(where: { $0.operationID == expected.operationID }),
                  current.transfers[index] == expected, expected.isUnstartedSymlinkRestore,
                  !current.transfers.contains(where: { $0.priorOperationID == expected.operationID }),
                  !current.managedLinks.contains(where: { $0.operationID == expected.operationID }) else {
                throw StoreError.conflict("Restore intent changed or copying already started")
            }
            if let link = current.managedLinks.first(where: { $0.originalPath == expected.originalPath }) {
                guard link.operationID == expected.priorOperationID,
                      link.destinationPath == expected.backupPath,
                      link.destinationIdentity.matchesFilesystemObject(expected.sourceIdentity) else {
                    throw StoreError.conflict("Restore no longer owns the indexed external data")
                }
            }
            try verifyingFilesystem()
            current.transfers.remove(at: index)
        }
    }

    /// The caller has verified the copy and completed the filesystem switch. Retention is normal success.
    func commitMigration(record: ContainerMountRecord?, transfer: DataTransferRecord) throws {
        try mutate { current in
            guard transfer.direction == .migrate else { throw StoreError.invalidState("Migration direction required") }
            var retained = transfer
            retained.phase = .awaitingUserVerification
            if let record {
                guard transfer.mode == .mount,
                      DataPathTopology.relationship(record.mountPointPath, transfer.originalPath) == .same,
                      self.sameUUID(record.volumeUUID, transfer.createdVolumeUUID) else {
                    throw StoreError.conflict("Mount does not match the transfer")
                }
                try self.putMount(record, into: &current)
            } else if transfer.mode == .mount {
                throw StoreError.invalidState("Mount migration requires its mount record")
            }
            if transfer.mode == .symlink {
                guard let identity = transfer.destinationIdentity else { throw StoreError.invalidState("Managed link requires destination identity") }
                try self.putLink(ManagedDataLinkRecord(operationID: transfer.operationID, sourceID: transfer.sourceID,
                    originalPath: transfer.originalPath, destinationPath: transfer.destinationPath,
                    destinationIdentity: identity, appName: transfer.appName, bundleIdentifier: transfer.bundleIdentifier,
                    dataDirType: transfer.dataDirType, createdAt: transfer.createdAt), into: &current, replacingFor: transfer)
            }
            try self.replaceTransfer(retained, in: &current)
        }
    }

    /// Call after copy verification and BEFORE the restore switch. The agent loses its mount entry atomically.
    func beginRestore(transfer: DataTransferRecord, removingMount mount: ContainerMountRecord?) throws {
        try mutate { current in
            guard transfer.direction == .restore else { throw StoreError.invalidState("Restore direction required") }
            var switching = transfer
            switching.phase = .switching
            if let mount {
                guard transfer.mode == .mount,
                      DataPathTopology.relationship(mount.mountPointPath, transfer.originalPath) == .same,
                      self.sameUUID(mount.volumeUUID, transfer.sourceIdentity.volumeUUID) else {
                    throw StoreError.conflict("Restore mount does not match source identity")
                }
                if let existing = current.mounts.first(where: { DataPathTopology.relationship($0.mountPointPath, mount.mountPointPath) == .same }) {
                    guard existing == mount else { throw StoreError.conflict("Recorded mount changed") }
                    current.mounts.removeAll { $0 == mount }
                }
            } else if transfer.mode == .mount {
                throw StoreError.invalidState("Mount restore requires its mount record")
            }
            if transfer.mode == .symlink,
               let link = current.managedLinks.first(where: { DataPathTopology.relationship($0.originalPath, transfer.originalPath) == .same }) {
                guard transfer.priorOperationID == link.operationID, transfer.sourceIdentity.matchesFilesystemObject(link.destinationIdentity) else {
                    throw StoreError.conflict("Restore does not own the indexed link")
                }
                current.managedLinks.removeAll { $0 == link }
            }
            try self.replaceTransfer(switching, in: &current)
        }
    }

    func finalizeTransfer(operationID: UUID, baseline: Data) throws {
        try mutate { current in
            guard var transfer = current.transfers.first(where: { $0.operationID == operationID }) else { throw StoreError.missingTransfer(operationID) }
            transfer.baseline = baseline
            transfer.phase = .awaitingUserVerification
            try self.replaceTransfer(transfer, in: &current)
        }
    }
    func requestCleanup(operationID: UUID) throws {
        try mutate { current, validation in
            guard var transfer = current.transfers.first(where: { $0.operationID == operationID }) else { throw StoreError.missingTransfer(operationID) }
            guard transfer.phase == .awaitingUserVerification || transfer.phase == .cleanupRequested else {
                throw StoreError.invalidState("Only verified retained copies can request cleanup")
            }
            // Physical cleanup can proceed independently. Keep a compact
            // identity link if an older retained copy still needs this later
            // location as proof, and verify that final ledger before deletion.
            var completed = current
            completed.schemaVersion = max(completed.schemaVersion, 8)
            if let index = completed.transfers.firstIndex(where: { $0.operationID == operationID }) {
                completed.transfers[index] = self.removalProof(for: transfer)
            }
            self.pruneRemovedTransfers(in: &completed)
            try self.validate(completed, using: validation)
            transfer.phase = .cleanupRequested
            transfer.recoverableReason = nil
            try self.replaceTransfer(transfer, in: &current)
        }
    }

    func beginCleanupDeletion(operationID: UUID, parentIdentity: DataPathIdentity, volumeContainerUUID: String? = nil) throws {
        try mutate { current in
            guard var transfer = current.transfers.first(where: { $0.operationID == operationID }),
                  transfer.phase == .cleanupRequested, parentIdentity.isResolved else {
                throw StoreError.invalidState("Verified cleanup must be requested before deleting")
            }
            if let existing = transfer.cleanupParentIdentity {
                guard existing.matchesFilesystemObject(parentIdentity) else {
                    throw StoreError.conflict("Retained copy parent changed")
                }
            } else {
                transfer.cleanupParentIdentity = parentIdentity
            }
            if let volumeContainerUUID {
                guard transfer.mode == .mount, transfer.direction == .restore, !volumeContainerUUID.isEmpty,
                      transfer.cleanupVolumeContainerUUID == nil
                        || self.sameUUID(transfer.cleanupVolumeContainerUUID, volumeContainerUUID) else {
                    throw StoreError.conflict("Retained volume container changed")
                }
                transfer.cleanupVolumeContainerUUID = volumeContainerUUID
            }
            transfer.recoverableReason = nil
            try self.replaceTransfer(transfer, in: &current)
        }
    }
    func finishTransfer(operationID: UUID, deletionConfirmed: Bool) throws {
        try mutate { current in
            guard deletionConfirmed else { throw StoreError.deletionNotConfirmed }
            guard let transfer = current.transfers.first(where: { $0.operationID == operationID }) else { return }
            guard transfer.phase == .cleanupRequested, transfer.needsAutomaticCompletion else {
                throw StoreError.invalidState("Cleanup must be explicitly requested and not paused")
            }
            // Only journals predating the saved mount record need this legacy
            // inference. Cleanup must not turn a new noowners migration into
            // an owners record merely because its copy was verified.
            if transfer.mode == .mount, transfer.direction == .migrate, transfer.baseline != nil,
               transfer.recoveryMountRecord == nil,
               try !self.hasOwnershipCompatibility(transfer, using: BaselineValidation()),
               let uuid = transfer.createdVolumeUUID,
               let index = current.mounts.firstIndex(where: {
                   $0.mountPointPath == transfer.originalPath && self.sameUUID($0.volumeUUID, uuid)
               }) {
                current.mounts[index].ownershipPolicy = .owners
            }
            if let index = current.transfers.firstIndex(where: { $0.operationID == operationID }) {
                current.transfers[index] = self.removalProof(for: transfer)
            }
            self.pruneRemovedTransfers(in: &current)
        }
    }

    /// One linear completed identity chain locates the currently active data.
    /// A pending or competing successor never grants deletion authority.
    func completedLocation(after operationID: UUID) throws -> DataTransferRecord {
        try read { document in
            guard var current = document.transfers.first(where: { $0.operationID == operationID }),
                  current.isDataSwitchComplete else { throw StoreError.missingTransfer(operationID) }
            var visited: Set<UUID> = [operationID]
            while true {
                let successors = document.transfers.filter { $0.priorOperationID == current.operationID && $0.rollbackCompletedAt == nil }
                guard !successors.isEmpty else { return current }
                guard successors.count == 1, let next = successors.first,
                      visited.insert(next.operationID).inserted, next.isDataSwitchComplete,
                      next.followsLocation(of: current) else {
                    throw StoreError.conflict("Current data location is not a completed identity chain")
                }
                current = next
            }
        }
    }

    private func removalProof(for transfer: DataTransferRecord) -> DataTransferRecord {
        var proof = transfer
        proof.phase = .cleanupRequested
        proof.retainedCopyRemovedAt = proof.retainedCopyRemovedAt ?? Date()
        proof.baseline = nil
        proof.sourceBaseline = nil
        proof.preparationRemovalBaseline = nil
        proof.recoverableReason = nil
        return proof
    }

    /// A small completed link exists only while an uncleared predecessor
    /// needs it. Removing the oldest copy retires every now-unneeded link in
    /// the same atomic document write; no new history archive is created.
    private func pruneRemovedTransfers(in document: inout Document) {
        let records = Dictionary(uniqueKeysWithValues: document.transfers.map { ($0.operationID, $0) })
        document.transfers.removeAll { transfer in
            guard transfer.retainedCopyRemovedAt != nil else { return false }
            var current = transfer
            var visited: Set<UUID> = [transfer.operationID]
            while let priorID = current.priorOperationID, let prior = records[priorID] {
                guard visited.insert(priorID).inserted else { return false }
                if prior.retainedCopyRemovedAt == nil { return false }
                current = prior
            }
            return true
        }
    }

    private func read<T>(_ body: (Document) throws -> T) throws -> T {
        lock.lock()
        defer { baselineValidation.boundMemory(); lock.unlock() }
        return try autoreleasepool { try body(load(using: baselineValidation)) }
    }
    private func mutate(_ body: (inout Document) throws -> Void) throws {
        try mutate { document, _ in try body(&document) }
    }
    private func mutate(_ body: (inout Document, BaselineValidation) throws -> Void) throws {
        try recheckWriterAdmission()
        lock.lock()
        var saved = false
        defer {
            baselineValidation.boundMemory()
            lock.unlock()
            if saved { NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: self) }
        }
        // The app and the remount agent are separate processes. Atomic rename
        // alone cannot prevent one read/modify/write cycle overwriting another.
        let writer = try acquireWriterLock()
        defer { _ = flock(writer, LOCK_UN); _ = close(writer) }
        let validation = baselineValidation
        var document = try load(using: validation)
        let original = document
        try body(&document, validation)
        // Older schema-3 writers drop unknown transfer fields while preserving
        // the opaque baseline. Protect ownership-aware records before any such
        // writer can erase the exception required to interpret that baseline.
        let needsOwnershipSchema = document.transfers.contains {
            $0.legacyRootOwnership != nil || $0.legacyMountFlags != nil
        } || document.mounts.contains { $0.ownershipPolicy != nil }
            || document.cleanups.contains { $0.mountRecord.ownershipPolicy != nil }
        // A schema-4 writer does not understand projected ownership on either
        // side of an ordinary copy. Keep that contract in its opaque baseline
        // while preventing older clients from executing against it.
        let needsCompatibilitySchema = try document.transfers.contains { try self.hasOwnershipCompatibility($0, using: validation) }
        let needsCleanupSchema = document.transfers.contains { $0.cleanupParentIdentity != nil || $0.recoveryMountRecord != nil }
        let needsPreparationSchema = !document.preservedMaterials.isEmpty || document.transfers.contains {
            $0.preparationPath != nil || $0.sourceBaseline != nil || $0.stagingIdentity != nil
                || $0.stagingParentIdentity != nil || $0.volumeCreationContainerUUID != nil
        }
        let needsLocationSchema = document.transfers.contains { transfer in
            transfer.retainedCopyRemovedAt != nil || document.transfers.contains {
                $0.operationID == transfer.priorOperationID && $0.direction == .restore
            }
        }
        // A schema-7 reader drops resource-fork summaries when decoding a
        // manifest. Apply this to creation and partial-removal baselines too.
        let needsResourceForkSchema = try document.transfers.contains { try self.hasResourceForkContract($0, using: validation) }
        let needsRollbackSchema = document.transfers.contains { $0.rollbackCompletedAt != nil }
        let needsCleanupDecisionSchema = document.transfers.contains { $0.cleanupDisposition != nil }
        let needsRetrySchema = document.transfers.contains { $0.retryFailureCount != nil || $0.nextAutomaticRetryAt != nil }
            || document.cleanups.contains { $0.retryFailureCount != nil || $0.nextAutomaticRetryAt != nil }
            || document.preservedMaterials.contains {
                $0.retryFailureCount != nil || $0.nextAutomaticRetryAt != nil
                    || $0.recoveryRecord?.retryFailureCount != nil || $0.recoveryRecord?.nextAutomaticRetryAt != nil
            }
        let needsActivationSchema = document.transfers.contains {
            $0.candidateActivationAttempted != nil || $0.candidateRemovalMountPointIdentity != nil
        } || document.preservedMaterials.contains {
            $0.recoveryRecord?.candidateActivationAttempted != nil || $0.recoveryRecord?.candidateRemovalMountPointIdentity != nil
        }
        document.schemaVersion = max(document.schemaVersion, !document.manualMountPauses.isEmpty ? 13 : needsActivationSchema ? 12 : needsRetrySchema ? 11 : needsCleanupDecisionSchema ? 10 : needsRollbackSchema ? 9 : needsLocationSchema || needsResourceForkSchema ? 8 : needsPreparationSchema ? 7 : needsCleanupSchema ? 6 : needsCompatibilitySchema ? 5 : needsOwnershipSchema ? 4 : 3)
        // Removing a mount also resolves its remount-only block; transfer recovery remains independent.
        let activeVolumes = Set(document.mounts.map { $0.volumeUUID.uppercased() })
        document.remountInterventions = document.remountInterventions.filter { activeVolumes.contains($0.key) }
        document.manualMountPauses = document.manualMountPauses.filter { uuid, path in
            document.mounts.contains { $0.volumeUUID.uppercased() == uuid && $0.mountPointPath == path }
        }
        try validate(document, using: validation)
        // Remount checks may confirm an unchanged record. Do not turn those
        // checks into filesystem events and another round of UI scans.
        guard document != original else { return }
        try save(document)
        saved = true
    }
    private func acquireWriterLock() throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw StoreError.unreadable }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG,
              identity.st_uid == getuid(), identity.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw StoreError.conflict("Another process is updating migration records")
        }
        var current = stat()
        guard lstat(lockURL.path, &current) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw StoreError.conflict("The migration-record lock was replaced")
        }
        // Keep this lock file after release; unlinking it would let two writers
        // lock different inodes under the same name.
        return descriptor
    }

    private func load(validateState: Bool = true, using validation: BaselineValidation = BaselineValidation()) throws -> Document {
        // fileExists follows links and conflates missing state with unreadable
        // state. An existing broken link must never authorize a fresh document.
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            guard errno == ENOENT else { throw StoreError.unreadable }
            var parent = fileURL.deletingLastPathComponent()
            while true {
                var info = stat()
                if lstat(parent.path, &info) == 0 {
                    guard info.st_mode & S_IFMT == S_IFDIR else { throw StoreError.unreadable }
                    return Document()
                }
                guard errno == ENOENT, parent.path != "/" else { throw StoreError.unreadable }
                parent.deleteLastPathComponent()
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG else {
            throw StoreError.unreadable
        }
        do {
            let data = try handle.readToEnd() ?? Data()
            let decoder = PropertyListDecoder()
            let document: Document
            if let legacy = try? decoder.decode([ContainerMountRecord].self, from: data) {
                document = Document(mounts: legacy)
            } else {
                document = try decoder.decode(Document.self, from: data)
            }
            if validateState { try validate(document, using: validation) }
            return document
        } catch let error as StoreError { throw error }
        catch { throw StoreError.unreadable }
    }
    private func save(_ document: Document) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try writeData(encoder.encode(document), fileURL)
    }

    private func putMount(_ mount: ContainerMountRecord, into document: inout Document) throws {
        if let index = document.mounts.firstIndex(where: { DataPathTopology.relationship($0.mountPointPath, mount.mountPointPath) == .same }) {
            guard sameUUID(document.mounts[index].volumeUUID, mount.volumeUUID) else {
                throw StoreError.conflict("A different volume already owns this mount point")
            }
            var replacement = mount
            // A stale caller must not erase the persisted ownership contract.
            replacement.ownershipPolicy = document.mounts[index].ownershipPolicy ?? mount.ownershipPolicy
            document.mounts[index] = replacement
        } else { document.mounts.append(mount) }
    }
    private func putLink(_ link: ManagedDataLinkRecord, into document: inout Document, replacingFor transfer: DataTransferRecord? = nil) throws {
        if let existing = document.managedLinks.first(where: { DataPathTopology.relationship($0.originalPath, link.originalPath) == .same }) {
            if existing == link { return }
            guard let transfer, transfer.mode == .symlink, transfer.direction == .migrate,
                  transfer.priorOperationID == existing.operationID,
                  transfer.sourceIdentity.matchesFilesystemObject(existing.destinationIdentity),
                  transfer.originalPath == existing.originalPath else {
                throw StoreError.conflict("A different managed link owns this source")
            }
            document.managedLinks.removeAll { $0 == existing }
            document.managedLinks.append(link)
        } else { document.managedLinks.append(link) }
    }
    private func checkLegacyMutation(_ path: String, _ document: Document) throws {
        guard !document.transfers.contains(where: { DataPathTopology.relationship($0.originalPath, path) == .same }) else {
            throw StoreError.conflict("Use the transfer transaction for this source")
        }
    }
    private func replaceTransfer(_ transfer: DataTransferRecord, in document: inout Document) throws {
        guard let index = document.transfers.firstIndex(where: { $0.operationID == transfer.operationID }) else { throw StoreError.missingTransfer(transfer.operationID) }
        let old = document.transfers[index]
        guard old.mode == transfer.mode, old.direction == transfer.direction, old.sourceID == transfer.sourceID,
              old.originalPath == transfer.originalPath, validSourceIdentityUpdate(old, transfer),
              old.destinationPath == transfer.destinationPath,
              old.backupPath == nil || old.backupPath == transfer.backupPath,
              old.stagingPath == nil || old.stagingPath == transfer.stagingPath,
              old.priorOperationID == transfer.priorOperationID, old.createdAt == transfer.createdAt,
              old.policyVersion == transfer.policyVersion, old.appName == transfer.appName,
              old.bundleIdentifier == transfer.bundleIdentifier, old.dataDirType == transfer.dataDirType,
              old.createdVolumeUUID == nil || sameUUID(old.createdVolumeUUID, transfer.createdVolumeUUID),
              old.destinationIdentity == nil || old.destinationIdentity == transfer.destinationIdentity,
              old.destinationVolumeUUID == nil || sameUUID(old.destinationVolumeUUID, transfer.destinationVolumeUUID),
              old.backupIdentity == nil || old.backupIdentity == transfer.backupIdentity,
              old.retainedCopyRemovedAt == transfer.retainedCopyRemovedAt,
              old.cleanupDisposition == transfer.cleanupDisposition,
              old.rollbackCompletedAt == transfer.rollbackCompletedAt,
              old.candidateActivationAttempted == transfer.candidateActivationAttempted
                || transfer.candidateActivationAttempted == true,
              old.candidateRemovalMountPointIdentity == nil
                || old.candidateRemovalMountPointIdentity == transfer.candidateRemovalMountPointIdentity,
              old.baseline == nil || old.baseline == transfer.baseline,
              old.sourceBaseline == nil || old.sourceBaseline == transfer.sourceBaseline,
              old.preparationPath == nil || old.preparationPath == transfer.preparationPath,
              old.preparationParentIdentity == nil || old.preparationParentIdentity == transfer.preparationParentIdentity,
              old.stagingParentIdentity == nil || old.stagingParentIdentity == transfer.stagingParentIdentity,
              old.stagingIdentity == nil || old.stagingIdentity == transfer.stagingIdentity,
              old.volumeCreationContainerUUID == nil || sameUUID(old.volumeCreationContainerUUID, transfer.volumeCreationContainerUUID),
              old.volumeCreationName == nil || old.volumeCreationName == transfer.volumeCreationName,
              old.originalSourceMountFlags == nil || old.originalSourceMountFlags == transfer.originalSourceMountFlags,
              old.preparationRemovalBaseline == nil || old.preparationRemovalBaseline == transfer.preparationRemovalBaseline,
              old.preparationRemovalParentIdentity == nil || old.preparationRemovalParentIdentity == transfer.preparationRemovalParentIdentity,
              old.recoveryMountRecord == nil || old.recoveryMountRecord == transfer.recoveryMountRecord,
              old.cleanupParentIdentity == transfer.cleanupParentIdentity
                || (old.phase == .cleanupRequested && transfer.phase == .cleanupRequested && old.cleanupParentIdentity == nil),
              old.cleanupVolumeContainerUUID == transfer.cleanupVolumeContainerUUID
                || (old.phase == .cleanupRequested && transfer.phase == .cleanupRequested && old.cleanupVolumeContainerUUID == nil),
              old.recoveryMountPointIdentity == transfer.recoveryMountPointIdentity
                || (old.isUnstartedMountRestore && transfer.isUnstartedMountRestore && old.recoveryMountPointIdentity == nil),
              old.legacyRootOwnership == transfer.legacyRootOwnership
                || (old.isUnstartedMountRestore && transfer.isUnstartedMountRestore
                    && old.sourceIdentity.isVolumeOnly && transfer.sourceIdentity.isVolumeOnly && old.legacyRootOwnership == nil),
              old.legacyMountFlags == transfer.legacyMountFlags
                || (old.isUnstartedMountRestore && transfer.isUnstartedMountRestore
                    && old.sourceIdentity.isVolumeOnly && transfer.sourceIdentity.isVolumeOnly && old.legacyMountFlags == nil) else {
            throw StoreError.conflict("Transfer identity or verified baseline changed")
        }
        guard permits(old.phase, transfer.phase) else { throw StoreError.invalidState("Invalid transfer phase transition") }
        document.transfers[index] = transfer
    }
    private func validSourceIdentity(_ transfer: DataTransferRecord) -> Bool {
        if transfer.sourceIdentity.isResolved { return true }
        return transfer.mode == .mount && transfer.direction == .restore
            && [.preparing, .needsRecovery].contains(transfer.phase) && transfer.sourceIdentity.isVolumeOnly
    }
    private func validSourceIdentityUpdate(_ old: DataTransferRecord, _ new: DataTransferRecord) -> Bool {
        if old.sourceIdentity == new.sourceIdentity { return true }
        return old.mode == .mount && old.direction == .restore
            && [.preparing, .needsRecovery].contains(old.phase) && old.phase == new.phase
            && old.sourceIdentity.isVolumeOnly && new.sourceIdentity.isResolved
            && sameUUID(old.sourceIdentity.volumeUUID, new.sourceIdentity.volumeUUID)
    }
    private func permits(_ old: DataTransferRecord.Phase, _ new: DataTransferRecord.Phase) -> Bool {
        if old == new || new == .needsRecovery { return true }
        switch (old, new) {
        case (.preparing, .copying), (.copying, .verified), (.verified, .switching),
             (.switching, .awaitingUserVerification), (.awaitingUserVerification, .cleanupRequested),
             (.needsRecovery, .verified), (.needsRecovery, .switching), (.needsRecovery, .awaitingUserVerification): return true
        default: return false
        }
    }
    private func sameUUID(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return !lhs.isEmpty && lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
    private func validPath(_ path: String) -> Bool { path.hasPrefix("/") && URL(fileURLWithPath: path).standardizedFileURL.path != "/" && !path.contains("\0") }

    /// Ordinary records need only the exception marker, not a second in-memory copy of every entry.
    private struct LegacyOwnershipMarker: Decodable {
        let restoredRootOwnership: TreeCopySnapshot.Ownership?
    }

    /// Keys are the full immutable manifest bytes freshly read from disk, never
    /// a path, inode, timestamp or previous filesystem verification. Reusing
    /// their small parsing summaries avoids decoding tens of thousands of
    /// entries at every journal transition. No decoded file tree is retained.
    private final class BaselineValidation {
        var legacyOwnership: [Data: LegacyOwnershipMarker] = [:]
        var ownershipCompatibility: [Data: Bool] = [:]
        var resourceForks: [Data: Bool] = [:]
        var snapshots: [Data: SnapshotValidation] = [:]

        func boundMemory() {
            let keys = Set(legacyOwnership.keys).union(ownershipCompatibility.keys)
                .union(resourceForks.keys).union(snapshots.keys)
            guard keys.count > 8 || keys.reduce(0, { $0 + $1.count }) > 64 * 1024 * 1024 else { return }
            legacyOwnership.removeAll()
            ownershipCompatibility.removeAll()
            resourceForks.removeAll()
            snapshots.removeAll()
        }
    }

    private struct SnapshotValidation {
        struct Root {
            let uid: UInt32
            let identity: TreeCopySnapshot.Identity
        }
        let decodes: Bool
        let legacyRoot: Root?
    }

    private func snapshotValidation(_ encoded: Data, using validation: BaselineValidation) -> SnapshotValidation {
        if let cached = validation.snapshots[encoded] { return cached }
        let result: SnapshotValidation = autoreleasepool {
            guard let snapshot = try? PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded) else {
                return SnapshotValidation(decodes: false, legacyRoot: nil)
            }
            let root: SnapshotValidation.Root?
            if let first = snapshot.entries.first, first.path.isEmpty, first.kind == .directory,
               snapshot.entries.lazy.filter({ $0.path.isEmpty }).count == 1 {
                root = .init(uid: first.uid, identity: first.identity)
            } else { root = nil }
            return SnapshotValidation(decodes: true, legacyRoot: root)
        }
        validation.snapshots[encoded] = result
        return result
    }

    private struct OwnershipCompatibilityMarker: Decodable {
        let isPresent: Bool
        enum Keys: String, CodingKey { case ownershipCompatibility }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            isPresent = values.contains(.ownershipCompatibility)
            if isPresent {
                do { _ = try values.decode(TreeCopySnapshot.OwnershipCompatibility.self, forKey: .ownershipCompatibility) }
                catch { throw StoreError.invalidState("Invalid ownership compatibility baseline") }
            }
        }
    }

    /// Older stores accepted opaque baselines. Keep that read compatibility,
    /// but never silently discard a present, malformed new ownership contract.
    private func hasOwnershipCompatibility(_ transfer: DataTransferRecord, using validation: BaselineValidation) throws -> Bool {
        guard let baseline = transfer.baseline else { return false }
        if let cached = validation.ownershipCompatibility[baseline] { return cached }
        let result: Bool = try autoreleasepool {
            do { return try PropertyListDecoder().decode(OwnershipCompatibilityMarker.self, from: baseline).isPresent }
            catch let error as StoreError { throw error }
            catch { return false }
        }
        validation.ownershipCompatibility[baseline] = result
        return result
    }

    /// Read only the format marker, not a second full file manifest or the
    /// historical raw fork. Legacy raw forks are promoted on the next write
    /// because a later decode/re-encode normalizes them to the new summary.
    private struct ResourceForkSchemaMarker: Decodable {
        struct Entry: Decodable {
            let usesResourceFork: Bool
            enum Keys: String, CodingKey { case resourceFork, extendedAttributes }
            enum AttributeKeys: String, CodingKey { case resourceFork = "com.apple.ResourceFork" }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: Keys.self)
                let fork = try values.decodeIfPresent(TreeCopySnapshot.ResourceFork.self, forKey: .resourceFork)
                if let fork, fork.size < 0 || fork.digest.count != 32 {
                    throw DecodingError.dataCorruptedError(forKey: .resourceFork, in: values,
                        debugDescription: "Invalid resource fork summary")
                }
                let attributes = try? values.nestedContainer(keyedBy: AttributeKeys.self, forKey: .extendedAttributes)
                usesResourceFork = fork != nil || attributes?.contains(.resourceFork) == true
            }
        }
        let usesResourceFork: Bool
        enum Keys: String, CodingKey { case entries }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            var entries = try values.nestedUnkeyedContainer(forKey: .entries)
            var found = false
            while !entries.isAtEnd {
                let entry = try entries.decode(Entry.self)
                // Keep decoding after the first fork: a later malformed
                // explicit summary must still stop the operation.
                found = found || entry.usesResourceFork
            }
            usesResourceFork = found
        }
    }

    private func hasResourceForkContract(_ transfer: DataTransferRecord, using validation: BaselineValidation) throws -> Bool {
        var found = false
        for encoded in [transfer.baseline, transfer.sourceBaseline, transfer.preparationRemovalBaseline].compactMap({ $0 }) {
            if let cached = validation.resourceForks[encoded] {
                found = found || cached
                continue
            }
            let result: Bool = try autoreleasepool {
                do {
                    return try PropertyListDecoder().decode(ResourceForkSchemaMarker.self, from: encoded).usesResourceFork
                } catch {
                    // Keep historical opaque-baseline compatibility. An explicit
                    // new field is never silently treated as an old opaque blob.
                    if let object = try? PropertyListSerialization.propertyList(from: encoded, format: nil),
                       let dictionary = object as? [String: Any],
                       let entries = dictionary["entries"] as? [[String: Any]],
                       entries.contains(where: { $0["resourceFork"] != nil }) {
                        throw StoreError.invalidState("Invalid resource fork baseline")
                    }
                    return false
                }
            }
            validation.resourceForks[encoded] = result
            found = found || result
        }
        return found
    }

    /// The destination-only ownership exception must never leak into source or cleanup metadata.
    private func validateLegacyOwnership(_ transfer: DataTransferRecord, using validation: BaselineValidation) throws {
        let marker = transfer.baseline.map { encoded in
            if let cached = validation.legacyOwnership[encoded] { return cached }
            let result = autoreleasepool {
                (try? PropertyListDecoder().decode(LegacyOwnershipMarker.self, from: encoded))
                    ?? LegacyOwnershipMarker(restoredRootOwnership: nil)
            }
            validation.legacyOwnership[encoded] = result
            return result
        }
        // An intent has no manifest yet; once copying succeeds, both records must agree.
        if transfer.baseline != nil, marker?.restoredRootOwnership != transfer.legacyRootOwnership {
            throw StoreError.invalidState("Legacy restored-root ownership does not match the verified baseline")
        }
        guard transfer.legacyRootOwnership != nil || transfer.legacyMountFlags != nil else { return }
        try validateLegacyOwnershipIntent(transfer)
        if let encoded = transfer.baseline {
            guard let root = snapshotValidation(encoded, using: validation).legacyRoot,
                  let owner = transfer.legacyRootOwnership,
                  root.uid == 0 || root.uid == owner.uid,
                  root.identity.inode == transfer.sourceIdentity.inode,
                  UInt64(UInt32(bitPattern: root.identity.device)) == transfer.sourceIdentity.device else {
                throw StoreError.invalidState("Legacy source-root metadata is missing or inconsistent")
            }
        }
    }

    private func validateLegacyOwnershipIntent(_ transfer: DataTransferRecord) throws {
        guard transfer.mode == .mount, transfer.direction == .restore,
              !(transfer.sourceIdentity.volumeUUID ?? "").isEmpty,
              transfer.destinationPath == transfer.originalPath,
              transfer.backupPath != nil, transfer.stagingPath != nil,
              let owner = transfer.legacyRootOwnership, owner.uid == geteuid(), owner.gid == getegid(),
              transfer.legacyMountFlags.map({ $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 }) ?? true else {
            throw StoreError.invalidState("Invalid legacy restore ownership intent")
        }
    }

    private func validate(_ document: Document, using validation: BaselineValidation = BaselineValidation()) throws {
        func validateActivation(_ transfer: DataTransferRecord) throws {
            if let identity = transfer.candidateRemovalMountPointIdentity {
                guard document.schemaVersion >= 12, identity.isResolved,
                      transfer.mode == .mount, transfer.direction == .migrate else {
                    throw StoreError.invalidState("Invalid candidate cleanup mount point")
                }
            }
            guard let attempted = transfer.candidateActivationAttempted else { return }
            guard document.schemaVersion >= 12, transfer.mode == .mount, transfer.direction == .migrate,
                  !transfer.isDataSwitchComplete || attempted,
                  !attempted || transfer.baseline != nil || transfer.retainedCopyRemovedAt != nil else {
                throw StoreError.invalidState("Invalid candidate activation evidence")
            }
        }
        func validateRetry(_ count: Int?, _ deadline: Date?) throws {
            guard count != nil || deadline != nil else { return }
            guard document.schemaVersion >= 11, let count, count >= 0,
                  (count == 0 && deadline == nil) || (count > 0 && deadline != nil),
                  deadline.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
                throw StoreError.invalidState("Invalid cleanup retry schedule")
            }
        }
        for transfer in document.transfers {
            try validateRetry(transfer.retryFailureCount, transfer.nextAutomaticRetryAt)
            try validateActivation(transfer)
        }
        for cleanup in document.cleanups { try validateRetry(cleanup.retryFailureCount, cleanup.nextAutomaticRetryAt) }
        for material in document.preservedMaterials {
            try validateRetry(material.retryFailureCount, material.nextAutomaticRetryAt)
            if let recovery = material.recoveryRecord {
                try validateRetry(recovery.retryFailureCount, recovery.nextAutomaticRetryAt)
                try validateActivation(recovery)
            }
        }
        guard Set(document.preservedMaterials.map(\.id)).count == document.preservedMaterials.count,
              document.preservedMaterials.allSatisfy({ validPath($0.originalPath) && $0.paths.allSatisfy(validPath) && !$0.reason.isEmpty }) else {
            throw StoreError.invalidState("Invalid preserved preparation material")
        }
        for (uuid, reason) in document.remountInterventions {
            guard uuid == uuid.uppercased(), document.mounts.contains(where: { sameUUID($0.volumeUUID, uuid) }),
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoreError.invalidState("Invalid remount intervention")
            }
        }
        guard document.manualMountPauses.isEmpty || document.schemaVersion >= 13,
              document.manualMountPauses.allSatisfy({ uuid, path in
                  document.mounts.contains { $0.volumeUUID.uppercased() == uuid && $0.mountPointPath == path }
              }) else { throw StoreError.invalidState("Invalid manual mount pause") }
        for mount in document.mounts {
            guard mount.schemaVersion == ContainerMountRecord.currentSchemaVersion, validPath(mount.mountPointPath),
                  validPath(mount.externalRootPath), !mount.volumeUUID.isEmpty else { throw StoreError.invalidState("Invalid mount record") }
        }
        for index in document.mounts.indices {
            for other in document.mounts.indices where other > index {
                let a = document.mounts[index], b = document.mounts[other]
                guard !DataPathTopology.overlaps(DataPathTopology.relationship(a.mountPointPath, b.mountPointPath)),
                      !sameUUID(a.volumeUUID, b.volumeUUID) else { throw StoreError.conflict("Conflicting mount records") }
            }
        }
        guard Set(document.cleanups.map(\.id)).count == document.cleanups.count,
              Set(document.transfers.map(\.operationID)).count == document.transfers.count else { throw StoreError.conflict("Duplicate operation identity") }
        for cleanup in document.cleanups {
            guard validPath(cleanup.localPath), cleanup.restoreStagingPath.map(validPath) ?? true else { throw StoreError.invalidState("Invalid legacy cleanup path") }
        }
        for link in document.managedLinks {
            guard validPath(link.originalPath), validPath(link.destinationPath), link.destinationIdentity.isResolved else {
                throw StoreError.invalidState("Invalid managed link identity")
            }
            for mount in document.mounts {
                guard !link.topologyEntries.contains(where: { DataPathTopology.overlaps(DataPathTopology.relationship($0.path, mount.mountPointPath)) }) else {
                    throw StoreError.conflict("Managed link overlaps a mount")
                }
            }
        }
        for index in document.managedLinks.indices {
            for other in document.managedLinks.indices where other > index {
                let a = document.managedLinks[index], b = document.managedLinks[other]
                guard a.operationID != b.operationID else { throw StoreError.conflict("Duplicate link operation") }
                for first in a.topologyEntries {
                    guard !b.topologyEntries.contains(where: { DataPathTopology.overlaps(DataPathTopology.relationship(first.path, $0.path)) }) else {
                        throw StoreError.conflict("Managed links overlap")
                    }
                }
            }
        }
        for transfer in document.transfers {
            if let disposition = transfer.cleanupDisposition {
                guard document.schemaVersion >= 10, transfer.retainedCopyRemovedAt == nil,
                      disposition != .keep || transfer.isDataSwitchComplete else {
                    throw StoreError.invalidState("Invalid retained-copy decision")
                }
            }
            try validateLegacyOwnership(transfer, using: validation)
            _ = try hasOwnershipCompatibility(transfer, using: validation)
            _ = try hasResourceForkContract(transfer, using: validation)
            if transfer.sourceBaseline != nil || transfer.preparationPath != nil || transfer.volumeCreationContainerUUID != nil {
                guard document.schemaVersion >= 7,
                      transfer.preparationPath.map(validPath) ?? true,
                      transfer.preparationParentIdentity.map(\.isResolved) ?? true,
                      transfer.stagingParentIdentity.map(\.isResolved) ?? true,
                      transfer.stagingIdentity.map(\.isResolved) ?? true,
                      transfer.sourceBaseline.map({ snapshotValidation($0, using: validation).decodes }) ?? true else {
                    throw StoreError.invalidState("Invalid copy creation evidence")
                }
            }
            if transfer.preparationRemovalBaseline != nil {
                guard transfer.preparationRemovalParentIdentity?.isResolved == true,
                      transfer.sourceBaseline != nil, transfer.destinationIdentity != nil,
                      !transfer.isDataSwitchComplete else { throw StoreError.invalidState("Invalid preparation deletion checkpoint") }
            }
            guard transfer.policyVersion > 0, validSourceIdentity(transfer),
                  transfer.topologyEntries.allSatisfy({ validPath($0.path) }),
                  transfer.createdVolumeUUID.map({ !$0.isEmpty }) ?? true,
                  transfer.destinationVolumeUUID.map({ !$0.isEmpty }) ?? true,
                  transfer.destinationIdentity.map({ $0.isResolved }) ?? true,
                  transfer.backupIdentity.map({ $0.isResolved }) ?? true,
                  transfer.priorOperationID != transfer.operationID else { throw StoreError.invalidState("Invalid transfer identity") }
            if [.verified, .switching, .awaitingUserVerification, .cleanupRequested].contains(transfer.phase) {
                guard transfer.destinationIdentity != nil,
                      transfer.baseline.map({ !$0.isEmpty }) == true || transfer.retainedCopyRemovedAt != nil else {
                    throw StoreError.invalidState("Verified phase requires caller-supplied baseline")
                }
            }
            if transfer.retainedCopyRemovedAt != nil {
                guard document.schemaVersion >= 8, transfer.phase == .cleanupRequested,
                      transfer.sourceIdentity.isResolved, transfer.destinationIdentity != nil,
                      transfer.baseline == nil, transfer.sourceBaseline == nil,
                      transfer.preparationRemovalBaseline == nil else {
                    throw StoreError.invalidState("Invalid physical-copy removal fact")
                }
            }
            if transfer.phase == .needsRecovery {
                guard let reason = transfer.recoverableReason, !reason.isEmpty else { throw StoreError.invalidState("Recovery needs an explanation") }
            }
            if transfer.rollbackCompletedAt != nil {
                guard document.schemaVersion >= 9, transfer.mode == .mount, transfer.phase == .needsRecovery,
                      transfer.cleanupParentIdentity == nil, transfer.retainedCopyRemovedAt == nil else {
                    throw StoreError.invalidState("Invalid rollback completion checkpoint")
                }
            }
            if let parent = transfer.cleanupParentIdentity {
                guard document.schemaVersion >= 6, parent.isResolved, transfer.phase == .cleanupRequested,
                      transfer.backupIdentity != nil, transfer.backupPath != nil,
                      transfer.baseline != nil || transfer.retainedCopyRemovedAt != nil else {
                    throw StoreError.invalidState("Invalid retained-copy cleanup checkpoint")
                }
            }
            if let container = transfer.cleanupVolumeContainerUUID {
                guard transfer.cleanupParentIdentity != nil, transfer.mode == .mount, transfer.direction == .restore,
                      !container.isEmpty else { throw StoreError.invalidState("Invalid volume deletion checkpoint") }
            }
            if let mount = transfer.recoveryMountRecord {
                guard document.schemaVersion >= 6, transfer.mode == .mount,
                      mount.schemaVersion == ContainerMountRecord.currentSchemaVersion,
                      validPath(mount.externalRootPath), mount.mountPointPath == transfer.originalPath,
                      mount.appName == transfer.appName, mount.bundleIdentifier == transfer.bundleIdentifier,
                      mount.dataDirType == transfer.dataDirType,
                      sameUUID(mount.volumeUUID, transfer.direction == .migrate ? transfer.createdVolumeUUID : transfer.sourceIdentity.volumeUUID) else {
                    throw StoreError.invalidState("Invalid mount switch recovery record")
                }
            }
            for mount in document.mounts {
                for entry in transfer.topologyEntries where DataPathTopology.overlaps(DataPathTopology.relationship(entry.path, mount.mountPointPath)) {
                    let directlyOwnsVolume = transfer.mode == .mount
                        && (sameUUID(transfer.createdVolumeUUID, mount.volumeUUID)
                            || sameUUID(transfer.sourceIdentity.volumeUUID, mount.volumeUUID))
                    let relatedVolume = document.transfers.contains { successor in
                            successor.mode == .mount && successor.direction == .migrate
                                && sameUUID(successor.createdVolumeUUID, mount.volumeUUID)
                                && lineageAllows(transfer, entry.path, successor, mount.mountPointPath, document: document)
                        }
                    let owned = (directlyOwnsVolume || relatedVolume)
                        && DataPathTopology.relationship(transfer.originalPath, mount.mountPointPath) == .same
                        && DataPathTopology.relationship(entry.path, mount.mountPointPath) == .same
                        && [transfer.originalPath, transfer.activePath, transfer.destinationPath].contains(entry.path)
                    guard owned else { throw StoreError.conflict("Transfer overlaps another mount") }
                }
            }
            for link in document.managedLinks {
                for path in link.topologyEntries.map(\.path) {
                    for entry in transfer.topologyEntries where DataPathTopology.overlaps(DataPathTopology.relationship(entry.path, path)) {
                        let directlyOwnsLink = transfer.mode == .symlink
                            && (transfer.operationID == link.operationID
                                || transfer.priorOperationID == link.operationID && transfer.sourceIdentity.matchesFilesystemObject(link.destinationIdentity))
                        let relatedLink = document.transfers.contains { successor in
                                successor.operationID == link.operationID
                                    && lineageAllows(transfer, entry.path, successor, path, document: document)
                            }
                        let matchingRoot = [link.originalPath, link.destinationPath].contains { DataPathTopology.relationship($0, entry.path) == .same }
                        guard directlyOwnsLink || relatedLink, matchingRoot,
                              transfer.originalPath == link.originalPath,
                              DataPathTopology.relationship(entry.path, path) == .same else {
                            throw StoreError.conflict("Transfer overlaps an indexed link")
                        }
                    }
                }
            }
            for cleanup in document.cleanups {
                for path in [cleanup.localPath, cleanup.restoreStagingPath].compactMap({ $0 }) {
                    guard !transfer.topologyEntries.contains(where: { DataPathTopology.overlaps(DataPathTopology.relationship($0.path, path)) }) else {
                        throw StoreError.conflict("Transfer overlaps a legacy retained copy")
                    }
                }
            }
        }
        for index in document.transfers.indices {
            for other in document.transfers.indices where other > index {
                let a = document.transfers[index], b = document.transfers[other]
                for first in a.topologyEntries {
                    for second in b.topologyEntries where DataPathTopology.overlaps(DataPathTopology.relationship(first.path, second.path)) {
                        guard lineageAllows(a, first.path, b, second.path, document: document) || lineageAllows(b, second.path, a, first.path, document: document) else {
                            throw StoreError.conflict("Transfer paths overlap another operation")
                        }
                    }
                }
            }
        }
    }

    private func lineageAllows(_ migration: DataTransferRecord, _ migrationPath: String,
                               _ successor: DataTransferRecord, _ successorPath: String, document: Document) -> Bool {
        guard migration.originalPath == successor.originalPath,
              DataPathTopology.relationship(migrationPath, successorPath) == .same else { return false }
        var current = successor
        var visited: Set<UUID> = []
        while let priorID = current.priorOperationID, visited.insert(current.operationID).inserted {
            guard let prior = document.transfers.first(where: { $0.operationID == priorID }),
                  current.followsLocation(of: prior) else { return false }
            if prior.operationID == migration.operationID {
                let roots = [migration.originalPath, migration.activePath, migration.destinationPath]
                return roots.contains(migrationPath) && roots.contains { DataPathTopology.relationship($0, successorPath) == .same }
                    && migrationPath != migration.backupPath && migrationPath != migration.stagingPath
            }
            current = prior
        }
        return false
    }
}
