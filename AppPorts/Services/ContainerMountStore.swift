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
    private let fileManager = FileManager.default
    private let lock: NSLock
    private let writeData: @Sendable (Data, URL) throws -> Void

    private struct Document: Codable {
        var schemaVersion = 3
        var mounts: [ContainerMountRecord] = []
        var cleanups: [ContainerCleanupRecord] = []
        var transfers: [DataTransferRecord] = []
        var managedLinks: [ManagedDataLinkRecord] = []
        var remountInterventions: [String: String] = [:]

        enum CodingKeys: String, CodingKey { case schemaVersion, mounts, cleanups, transfers, managedLinks, remountInterventions }
        init(mounts: [ContainerMountRecord] = []) { self.mounts = mounts }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 2 || schemaVersion == 3 else { throw StoreError.unsupportedSchema(schemaVersion) }
            mounts = try values.decode([ContainerMountRecord].self, forKey: .mounts)
            cleanups = try values.decode([ContainerCleanupRecord].self, forKey: .cleanups)
            transfers = schemaVersion == 2 ? [] : try values.decode([DataTransferRecord].self, forKey: .transfers)
            managedLinks = schemaVersion == 2 ? [] : try values.decodeIfPresent([ManagedDataLinkRecord].self, forKey: .managedLinks) ?? []
            remountInterventions = schemaVersion == 2 ? [:] : try values.decodeIfPresent([String: String].self, forKey: .remountInterventions) ?? [:]
        }
    }

    enum StoreError: LocalizedError, Sendable {
        case unreadable
        case unsupportedSchema(Int)
        case invalidState(String)
        case conflict(String)
        case missingTransfer(UUID)
        case deletionNotConfirmed
        case retainedPredecessor(String)
        var errorDescription: String? {
            if case .retainedPredecessor(let path) = self {
                return String(format: "此目录与已有迁移或保留副本重叠，请先处理原迁移：%@".localized, path)
            }
            // Existing localized message is intentionally shared; associated facts go to diagnostics.
            return "迁移记录无法读取，已停止修改并保留原记录。请检查文件权限或从备份恢复记录后重试。".localized
        }
    }

    init(fileURL: URL? = nil,
         writeData: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        let resolved = fileURL ?? Self.defaultFileURL
        self.fileURL = resolved
        self.lock = Self.lock(for: resolved)
        self.writeData = writeData
    }

    struct Inspection: Sendable {
        let mounts: [ContainerMountRecord]
        let cleanups: [ContainerCleanupRecord]
        let transfers: [DataTransferRecord]
        let managedLinks: [ManagedDataLinkRecord]
        let remountInterventions: [String: String]
        let validationError: StoreError?
    }

    /// Parsed facts for diagnostics only; conflicting records are preserved in original order.
    /// Callers must surface validationError and must not execute from this snapshot.
    func recordsForInspection() throws -> Inspection {
        lock.lock()
        defer { lock.unlock() }
        let document = try load(validateState: false)
        var failure: StoreError?
        do { try validate(document) }
        catch let error as StoreError { failure = error }
        return Inspection(mounts: document.mounts, cleanups: document.cleanups, transfers: document.transfers,
                          managedLinks: document.managedLinks, remountInterventions: document.remountInterventions, validationError: failure)
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
    func transfers() throws -> [DataTransferRecord] {
        try read { $0.transfers.sorted { $0.createdAt == $1.createdAt ? $0.operationID.uuidString < $1.operationID.uuidString : $0.createdAt < $1.createdAt } }
    }
    func managedLinks() throws -> [ManagedDataLinkRecord] { try read { $0.managedLinks.sorted { $0.originalPath < $1.originalPath } } }
    func managedLink(forOriginalPath path: String) throws -> ManagedDataLinkRecord? {
        try managedLinks().first { DataPathTopology.relationship($0.originalPath, path) == .same }
    }
    func upsertManagedLink(_ link: ManagedDataLinkRecord) throws {
        try mutate { try self.putLink(link, into: &$0) }
    }
    func removeManagedLink(forOriginalPath path: String) throws {
        try mutate { current in
            try self.checkLegacyMutation(path, current)
            current.managedLinks.removeAll { DataPathTopology.relationship($0.originalPath, path) == .same }
        }
    }
    /// Startup only returns durable facts, including cleanupRequested; it never deletes or resumes work.
    func unfinishedTransfers() throws -> [DataTransferRecord] { try transfers() }
    func transfer(operationID: UUID) throws -> DataTransferRecord? { try read { $0.transfers.first { $0.operationID == operationID } } }
    func record(forMountPoint url: URL) -> ContainerMountRecord? {
        records().first { DataPathTopology.relationship($0.mountPointPath, url.path) == .same }
    }
    func recordStrict(forMountPoint url: URL) throws -> ContainerMountRecord? {
        try recordsStrict().first { DataPathTopology.relationship($0.mountPointPath, url.path) == .same }
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

    /// A created volume UUID can be filled once immediately after creation, never replaced.
    func updateTransfer(_ transfer: DataTransferRecord) throws {
        try mutate { current in try self.replaceTransfer(transfer, in: &current) }
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
        try mutate { current in
            guard var transfer = current.transfers.first(where: { $0.operationID == operationID }) else { throw StoreError.missingTransfer(operationID) }
            guard transfer.phase == .awaitingUserVerification || transfer.phase == .cleanupRequested else {
                throw StoreError.invalidState("Only verified retained copies can request cleanup")
            }
            // The terminal restore is also the proof of where earlier originals'
            // active data now lives. Clean retained lineage from oldest to newest.
            if let predecessorID = transfer.priorOperationID,
               let predecessor = current.transfers.first(where: { $0.operationID == predecessorID }) {
                throw StoreError.retainedPredecessor(predecessor.backupPath ?? predecessor.originalPath)
            }
            // Refuse before deletion if a retained ancestor still needs this record
            // to prove its relationship to a newer restore or normalized link.
            var completed = current
            completed.transfers.removeAll { $0.operationID == operationID }
            try self.validate(completed)
            transfer.phase = .cleanupRequested
            try self.replaceTransfer(transfer, in: &current)
        }
    }
    func finishTransfer(operationID: UUID, deletionConfirmed: Bool) throws {
        try mutate { current in
            guard deletionConfirmed else { throw StoreError.deletionNotConfirmed }
            guard let transfer = current.transfers.first(where: { $0.operationID == operationID }) else { return }
            guard transfer.phase == .cleanupRequested else { throw StoreError.invalidState("Cleanup must be explicitly requested") }
            current.transfers.removeAll { $0.operationID == operationID }
        }
    }

    private func read<T>(_ body: (Document) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(load())
    }
    private func mutate(_ body: (inout Document) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        // The app and the remount agent are separate processes. Atomic rename
        // alone cannot prevent one read/modify/write cycle overwriting another.
        let writer = try acquireWriterLock()
        defer { _ = flock(writer, LOCK_UN); _ = close(writer) }
        var document = try load()
        try body(&document)
        document.schemaVersion = 3
        // Removing a mount also resolves its remount-only block; transfer recovery remains independent.
        let activeVolumes = Set(document.mounts.map { $0.volumeUUID.uppercased() })
        document.remountInterventions = document.remountInterventions.filter { activeVolumes.contains($0.key) }
        try validate(document)
        try save(document)
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

    private func load(validateState: Bool = true) throws -> Document {
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
            if validateState { try validate(document) }
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
            document.mounts[index] = mount
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
              old.backupIdentity == nil || old.backupIdentity == transfer.backupIdentity,
              old.baseline == nil || old.baseline == transfer.baseline else {
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
    private func identityMatches(_ resolved: DataPathIdentity, _ candidate: DataPathIdentity) -> Bool {
        resolved.matchesFilesystemObject(candidate) || (candidate.isVolumeOnly && sameUUID(resolved.volumeUUID, candidate.volumeUUID))
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

    private func validate(_ document: Document) throws {
        for (uuid, reason) in document.remountInterventions {
            guard uuid == uuid.uppercased(), document.mounts.contains(where: { sameUUID($0.volumeUUID, uuid) }),
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoreError.invalidState("Invalid remount intervention")
            }
        }
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
            guard transfer.policyVersion > 0, validSourceIdentity(transfer),
                  transfer.topologyEntries.allSatisfy({ validPath($0.path) }),
                  transfer.createdVolumeUUID.map({ !$0.isEmpty }) ?? true,
                  transfer.destinationIdentity.map({ $0.isResolved }) ?? true,
                  transfer.backupIdentity.map({ $0.isResolved }) ?? true,
                  transfer.priorOperationID != transfer.operationID else { throw StoreError.invalidState("Invalid transfer identity") }
            if [.verified, .switching, .awaitingUserVerification, .cleanupRequested].contains(transfer.phase) {
                guard let baseline = transfer.baseline, !baseline.isEmpty, transfer.destinationIdentity != nil else { throw StoreError.invalidState("Verified phase requires caller-supplied baseline") }
            }
            if transfer.phase == .needsRecovery {
                guard let reason = transfer.recoverableReason, !reason.isEmpty else { throw StoreError.invalidState("Recovery needs an explanation") }
            }
            for mount in document.mounts {
                for entry in transfer.topologyEntries where DataPathTopology.overlaps(DataPathTopology.relationship(entry.path, mount.mountPointPath)) {
                    let owned = transfer.mode == .mount
                        && DataPathTopology.relationship(transfer.originalPath, mount.mountPointPath) == .same
                        && (sameUUID(transfer.createdVolumeUUID, mount.volumeUUID) || sameUUID(transfer.sourceIdentity.volumeUUID, mount.volumeUUID))
                        && DataPathTopology.relationship(entry.path, mount.mountPointPath) == .same
                        && [transfer.originalPath, transfer.activePath, transfer.destinationPath].contains(entry.path)
                    guard owned else { throw StoreError.conflict("Transfer overlaps another mount") }
                }
            }
            for link in document.managedLinks {
                for path in link.topologyEntries.map(\.path) {
                    for entry in transfer.topologyEntries where DataPathTopology.overlaps(DataPathTopology.relationship(entry.path, path)) {
                        let matchingOperation = transfer.operationID == link.operationID
                            || transfer.priorOperationID == link.operationID && transfer.sourceIdentity.matchesFilesystemObject(link.destinationIdentity)
                            || document.transfers.contains { successor in
                                successor.operationID == link.operationID
                                    && lineageAllows(transfer, entry.path, successor, path, document: document)
                            }
                        let matchingRoot = [link.originalPath, link.destinationPath].contains { DataPathTopology.relationship($0, entry.path) == .same }
                        guard transfer.mode == .symlink, matchingOperation, matchingRoot,
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
        guard migration.direction == .migrate,
              migration.mode == successor.mode, migration.originalPath == successor.originalPath,
              DataPathTopology.relationship(migrationPath, successorPath) == .same else { return false }
        var current = successor
        var visited: Set<UUID> = []
        while let priorID = current.priorOperationID, visited.insert(current.operationID).inserted {
            guard let prior = document.transfers.first(where: { $0.operationID == priorID }),
                  prior.direction == .migrate, prior.mode == current.mode,
                  prior.originalPath == current.originalPath,
                  current.direction == .restore || current.mode == .symlink,
                  [.awaitingUserVerification, .cleanupRequested, .needsRecovery].contains(prior.phase),
                  let identity = prior.destinationIdentity, identityMatches(identity, current.sourceIdentity) else { return false }
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
