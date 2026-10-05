import Darwin
import Foundation

/// Data-tree operations retain verified originals until explicit cleanup.
/// UI flags never authorize execution; every entry point evaluates real paths and durable topology.
actor DataDirMover {
    private let fileManager = FileManager.default
    private let homeDir: URL
    private let store: ContainerMountStore
    private let safety: DataOperationSafety
    private let failSymlinkCreation: Bool
    private let managedLinkMarkerFileName = ".appports-link-metadata.plist"
    private let managedLinkMetadataSidecarSuffix = ".appports-link-metadata.plist"
    private let managedLinkIdentifier = "com.shimoko.AppPorts"
    private let managedLinkSchemaVersion = 1

    private struct ManagedLinkMetadata: Codable, Sendable {
        let schemaVersion: Int
        let managedBy: String
        let sourcePath: String
        let destinationPath: String
        let dataDirType: String
    }

    init(homeDir: URL = URL(fileURLWithPath: NSHomeDirectory()),
         failSymlinkCreation: Bool = false, failSourceBackupCleanup: Bool = false,
         store: ContainerMountStore = .shared, runner: any ShellCommandRunning = ProcessCommandRunner()) {
        self.homeDir = homeDir.standardizedFileURL
        self.store = store
        self.safety = DataOperationSafety(homeDirectory: homeDir, store: store, runner: runner)
        self.failSymlinkCreation = failSymlinkCreation
        // Kept source-compatible with older callers. Success now always retains the original.
        _ = failSourceBackupCleanup
    }

    func migrate(item: DataDirItem, to externalBaseURL: URL, progressHandler: FileCopier.ProgressHandler?) async throws {
        let source = item.path.standardizedFileURL
        let destination = externalBaseURL.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        try requirePolicy(source)
        guard !isSymbolicLink(at: source) else { throw DataDirError.destinationExists(source) }
        guard !DiskUtility.isMountPoint(source) else { throw DataOperationSafety.Failure.conflict(source.path) }
        guard try !entryExists(destination) else { throw DataDirError.destinationExists(destination) }
        try requireMarker(at: source, for: source, type: item.type, allowOwned: false)
        try await safety.requireNewMigration(at: source, destination: destination, bundleIdentifier: item.associatedBundleIdentifier)
        let id = UUID()
        let backup = source.deletingLastPathComponent().appendingPathComponent(".appports-migration-backup-\(source.lastPathComponent)-\(id)")
        var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .migrate, sourceID: item.id,
            appName: item.associatedAppName ?? item.name, bundleIdentifier: item.associatedBundleIdentifier,
            dataDirType: item.type.rawValue, originalPath: source.path, activePath: source.path,
            destinationPath: destination.path, backupPath: backup.path,
            sourceIdentity: try DataPathIdentity.capture(source))
        try store.beginTransfer(transfer)
        do {
            try checkWritePermission(at: externalBaseURL)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copy(from: source, to: destination, final: destination, progress: progressHandler)
            try requireMarker(at: source, for: source, type: item.type, allowOwned: false)
            try installMarker(source: source, destination: destination, type: item.type, baseline: baseline)
            transfer.destinationIdentity = try DataPathIdentity.capture(destination)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            await progressHandler?(.init(copiedBytes: baseline.logicalBytes, totalBytes: baseline.logicalBytes, currentFile: "正在切换本地入口...".localized))
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: item.associatedBundleIdentifier)
            try requireIdentity(source, transfer.sourceIdentity)
            try requireMarker(at: source, for: source, type: item.type, allowOwned: false)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
            transfer.phase = .switching
            try store.updateTransfer(transfer)
            try DataTreeRelocator.move(source, to: backup)
            transfer.backupIdentity = try DataPathIdentity.capture(backup)
            try requireIdentity(backup, transfer.sourceIdentity)
            try store.updateTransfer(transfer)
            await progressHandler?(.init(copiedBytes: baseline.logicalBytes, totalBytes: baseline.logicalBytes, currentFile: "正在创建符号链接...".localized))
            try requireMarker(at: backup, for: source, type: item.type, allowOwned: false)
            try TreeCopySession.verifyUnchanged(at: backup, against: baseline)
            do { try createSymbolicLink(at: source, withDestinationURL: destination) }
            catch {
                // The backup is still complete; never overwrite a competing entry during rollback.
                if try !entryExists(source) { try DataTreeRelocator.move(backup, to: source) }
                throw DataDirError.symlinkFailed(error)
            }
            transfer.activePath = destination.path
            try requireMarker(at: backup, for: source, type: item.type, allowOwned: false)
            try TreeCopySession.verifyUnchanged(at: backup, against: baseline)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
            try store.commitMigration(record: nil, transfer: transfer)
            invalidateSizeCache(for: source)
            invalidateSizeCache(for: destination)
        } catch { try recordFailure(&transfer, error: error) }
    }

    func restore(item: DataDirItem, progressHandler: FileCopier.ProgressHandler?) async throws {
        let local = item.path.standardizedFileURL
        let indexed = try store.managedLink(forOriginalPath: local.path)
        let existingTransfers = try store.transfers()
        if !isSymbolicLink(at: local), indexed == nil,
           let completed = existingTransfers.last(where: { $0.direction == .restore && $0.originalPath == local.path && [.awaitingUserVerification, .cleanupRequested].contains($0.phase) }),
           let identity = completed.destinationIdentity, let current = try? DataPathIdentity.capture(local), identity.matchesFilesystemObject(current) { return }
        let linkIdentity: DataPathIdentity?
        let external: URL
        if isSymbolicLink(at: local) {
            linkIdentity = try DataPathIdentity.capture(local)
            external = local.resolvingSymlinksInPath()
        } else if let indexed, try !entryExists(local) {
            linkIdentity = nil
            external = URL(fileURLWithPath: indexed.destinationPath)
        } else { throw DataDirError.notASymlink(local) }
        guard fileManager.fileExists(atPath: external.path), !isSymbolicLink(at: external) else { throw DataDirError.externalNotFound(external) }
        let sourceIdentity = try DataPathIdentity.capture(external)
        if let indexed {
            guard DataPathTopology.relationship(indexed.destinationPath, external.path) == .same,
                  indexed.destinationIdentity.matchesFilesystemObject(sourceIdentity) else { throw DataOperationSafety.Failure.conflict(external.path) }
        }
        try requireMarker(at: external, for: local, type: item.type, allowOwned: true)
        let prior = indexed?.operationID ?? existingTransfers.last(where: {
            $0.direction == .migrate && $0.originalPath == local.path && $0.destinationIdentity?.matchesFilesystemObject(sourceIdentity) == true
        })?.operationID
        let ownedIDs = prior.map { transferAncestors(of: $0, transfers: existingTransfers) } ?? []
        try safety.requireNoOverlap(at: local, ownedTransferIDs: ownedIDs, ownedLinkPath: indexed?.originalPath)
        try safety.requireNoOverlap(at: external, ownedTransferIDs: ownedIDs, ownedLinkPath: indexed?.originalPath)
        try requireLocalRestoreParent(local)
        try await safety.requireNoKnownWriters(at: external, bundleIdentifier: item.associatedBundleIdentifier ?? indexed?.bundleIdentifier)
        let id = UUID()
        let staging = local.deletingLastPathComponent().appendingPathComponent(".appports-restore-\(id)")
        let copyURL = staging.appendingPathComponent("data")
        var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .restore, sourceID: item.id,
            appName: item.associatedAppName ?? item.name, bundleIdentifier: item.associatedBundleIdentifier ?? indexed?.bundleIdentifier,
            dataDirType: item.type.rawValue, originalPath: local.path, activePath: external.path, destinationPath: local.path,
            backupPath: external.path, stagingPath: staging.path, sourceIdentity: sourceIdentity,
            backupIdentity: sourceIdentity, priorOperationID: prior)
        try store.beginTransfer(transfer)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copy(from: external, to: copyURL, final: local, progress: progressHandler)
            transfer.destinationIdentity = try DataPathIdentity.capture(copyURL)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            try await safety.requireNoKnownWriters(at: external, bundleIdentifier: transfer.bundleIdentifier)
            try requireIdentity(external, sourceIdentity)
            try requireMarker(at: external, for: local, type: item.type, allowOwned: true)
            try TreeCopySession.verifyUnchanged(at: external, against: baseline)
            try TreeCopySession.verifyCopy(at: copyURL, against: baseline)
            try requireLocalRestoreParent(local)
            try store.beginRestore(transfer: transfer, removingMount: nil)
            transfer.phase = .switching
            try requireIdentity(copyURL, transfer.destinationIdentity!)
            try switchEntry(local: local, expectedLink: linkIdentity, replacement: copyURL, staging: staging)
            try TreeCopySession.applyRootMetadata(at: local, from: baseline)
            transfer.activePath = local.path
            try TreeCopySession.verifyUnchanged(at: external, against: baseline)
            try TreeCopySession.verifyCopy(at: local, against: baseline)
            try store.updateTransfer(transfer)
            try store.finalizeTransfer(operationID: id, baseline: transfer.baseline!)
            invalidateSizeCache(for: local)
            invalidateSizeCache(for: external)
        } catch { try recordFailure(&transfer, error: error) }
    }

    /// Attach existing data without replacing a different entry. The source index is durable intent.
    func createLink(localPath: URL, externalPath: URL, bundleIdentifier: String? = nil, appName: String? = nil) async throws {
        let local = localPath.standardizedFileURL
        let external = externalPath.standardizedFileURL
        try requirePolicy(local)
        guard existingDirectory(at: external), !isSymbolicLink(at: external) else { throw DataDirError.externalNotFound(external) }
        let old = try store.managedLink(forOriginalPath: local.path)
        let externalIdentity = try DataPathIdentity.capture(external)
        if let old {
            guard old.destinationIdentity.matchesFilesystemObject(externalIdentity),
                  DataPathTopology.relationship(old.destinationPath, external.path) == .same else { throw DataOperationSafety.Failure.conflict(local.path) }
            if isSymbolicLink(at: local), DataPathTopology.relationship(local.path, external.path) == .same { return }
        }
        let adoptedEntry: DataPathIdentity?
        if isSymbolicLink(at: local), DataPathTopology.relationship(local.path, external.path) == .same {
            adoptedEntry = try DataPathIdentity.capture(local)
        } else {
            guard try !entryExists(local) else { throw DataDirError.destinationExists(local) }
            adoptedEntry = nil
        }
        let type = try managedType(for: local, external: external, indexedType: old?.dataDirType)
        try requireMarker(at: external, for: local, type: type, allowOwned: true)
        let history = try store.transfers()
        let owned = old.map { transferAncestors(of: $0.operationID, transfers: history) } ?? []
        try safety.requireNoOverlap(at: local, ownedTransferIDs: owned, ownedLinkPath: old?.originalPath)
        try safety.requireNoOverlap(at: external, ownedTransferIDs: owned, ownedLinkPath: old?.originalPath)
        try safety.requireNoManagedFileSystemAncestor(at: local)
        if adoptedEntry == nil && DataPathTopology.overlaps(DataPathTopology.relationship(local.path, external.path)) {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        try safety.requireNoManagedDescendants(at: external)
        try await safety.requireNoKnownWriters(at: external, bundleIdentifier: bundleIdentifier ?? old?.bundleIdentifier)
        let baseline = try TreeCopySession.snapshot(at: external, excludingRootEntries: [managedLinkMarkerFileName])
        let index = old ?? ManagedDataLinkRecord(operationID: UUID(), originalPath: local.path, destinationPath: external.path,
            destinationIdentity: externalIdentity, appName: appName ?? local.lastPathComponent, bundleIdentifier: bundleIdentifier ?? inferredBundleIdentifier(local), dataDirType: type.rawValue)
        try store.upsertManagedLink(index)
        try fileManager.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try installMarker(source: local, destination: external, type: type, baseline: baseline)
        try TreeCopySession.verifyUnchanged(at: external, against: baseline)
        if let adoptedEntry {
            try requireIdentity(local, adoptedEntry)
            guard DataPathTopology.relationship(local.path, external.path) == .same else { throw DataOperationSafety.Failure.conflict(local.path) }
            return
        }
        do { try createSymbolicLink(at: local, withDestinationURL: external) }
        catch { throw DataDirError.symlinkFailed(error) }
    }

    /// Disconnecting an entry keeps its index so the now-missing original remains recoverable.
    func deleteLink(localPath: URL) async throws {
        guard isSymbolicLink(at: localPath) else { throw DataDirError.notASymlink(localPath) }
        let identity = try DataPathIdentity.capture(localPath)
        let indexed = try store.managedLink(forOriginalPath: localPath.path)
        let history = try store.transfers()
        let owned = indexed.map { transferAncestors(of: $0.operationID, transfers: history) } ?? []
        try safety.requireNoOverlap(at: localPath, ownedTransferIDs: owned, ownedLinkPath: indexed?.originalPath)
        try safety.requireNoManagedFileSystemAncestor(at: localPath)
        let target = localPath.resolvingSymlinksInPath()
        try await safety.requireNoKnownWriters(at: target)
        try requireIdentity(localPath, identity)
        try fileManager.removeItem(at: localPath)
    }

    func normalizeManagedLink(localPath: URL, currentExternalPath: URL, normalizedExternalPath: URL) async throws {
        let local = localPath.standardizedFileURL
        let source = currentExternalPath.standardizedFileURL
        let destination = normalizedExternalPath.standardizedFileURL
        try requirePolicy(local)
        guard existingDirectory(at: source), !isSymbolicLink(at: source) else { throw DataDirError.externalNotFound(source) }
        guard isSymbolicLink(at: local), DataPathTopology.relationship(local.path, source.path) == .same else { throw DataDirError.invalidSymlink(local) }
        if DataPathTopology.relationship(source.path, destination.path) == .same { return }
        guard try !entryExists(destination) else { throw DataDirError.destinationExists(destination) }
        let old = try store.managedLink(forOriginalPath: local.path)
        let type = try managedType(for: local, external: source, indexedType: old?.dataDirType)
        try requireMarker(at: source, for: local, type: type, allowOwned: true)
        let sourceIdentity = try DataPathIdentity.capture(source)
        if let old { try requireIdentity(source, old.destinationIdentity) }
        let history = try store.transfers()
        let owned = old.map { transferAncestors(of: $0.operationID, transfers: history) } ?? []
        try safety.requireNoOverlap(at: local, ownedTransferIDs: owned, ownedLinkPath: old?.originalPath)
        try safety.requireNoOverlap(at: source, ownedTransferIDs: owned, ownedLinkPath: old?.originalPath)
        try safety.requireNoOverlap(at: destination)
        try safety.requireNoManagedFileSystemAncestor(at: local)
        try safety.requireNoManagedDescendants(at: source)
        try await safety.requireNoKnownWriters(at: source, bundleIdentifier: old?.bundleIdentifier)
        let id = UUID()
        let staging = local.deletingLastPathComponent().appendingPathComponent(".appports-normalize-\(id)")
        let linkIdentity = try DataPathIdentity.capture(local)
        var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .migrate, sourceID: local.path,
            appName: old?.appName ?? local.lastPathComponent, bundleIdentifier: old?.bundleIdentifier ?? inferredBundleIdentifier(local),
            dataDirType: type.rawValue, originalPath: local.path, activePath: source.path, destinationPath: destination.path,
            backupPath: source.path, stagingPath: staging.path, sourceIdentity: sourceIdentity, backupIdentity: sourceIdentity,
            priorOperationID: old?.operationID)
        try store.beginTransfer(transfer)
        do {
            try checkWritePermission(at: destination.deletingLastPathComponent())
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copy(from: source, to: destination, final: destination, progress: nil)
            try installMarker(source: local, destination: destination, type: type, baseline: baseline)
            transfer.destinationIdentity = try DataPathIdentity.capture(destination)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: transfer.bundleIdentifier)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            let newLink = staging.appendingPathComponent("new-link")
            try createSymbolicLink(at: newLink, withDestinationURL: destination)
            transfer.phase = .switching
            try store.updateTransfer(transfer)
            try switchEntry(local: local, expectedLink: linkIdentity, replacement: newLink, staging: staging)
            transfer.activePath = destination.path
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
            try store.commitMigration(record: nil, transfer: transfer)
        } catch { try recordFailure(&transfer, error: error) }
    }

    /// The only operation that removes an original, after an explicit user request.
    func cleanupRetainedTransfer(operationID: UUID) async throws {
        let transfers = try store.transfers()
        guard var transfer = transfers.first(where: { $0.operationID == operationID }) else { return }
        guard transfer.mode == .symlink,
              [.awaitingUserVerification, .cleanupRequested].contains(transfer.phase),
              let encoded = transfer.baseline, let retainedPath = transfer.backupPath,
              let retainedIdentity = transfer.backupIdentity else { throw DataOperationSafety.Failure.inspection(operationID.uuidString) }
        let retained = URL(fileURLWithPath: retainedPath)
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        var physicalCleanupStarted = false
        do {
            let links = try store.managedLinks()
            let descendants = transferDescendants(of: transfer.operationID, transfers: transfers)
            let lineage = descendants.reduce(into: Set<UUID>()) { $0.formUnion(transferAncestors(of: $1, transfers: transfers)) }
            let activeLink = links.first { $0.originalPath == transfer.originalPath && descendants.contains($0.operationID) }
            let activeRestore = transfers.last { descendants.contains($0.operationID) && $0.direction == .restore && [.awaitingUserVerification, .cleanupRequested].contains($0.phase) }
            let activeURL = URL(fileURLWithPath: activeLink?.destinationPath ?? activeRestore?.destinationPath ?? transfer.activePath)
            guard let activeIdentity = activeLink?.destinationIdentity ?? activeRestore?.destinationIdentity ?? transfer.destinationIdentity else {
                throw DataOperationSafety.Failure.inspection(activeURL.path)
            }
            try requireIdentity(activeURL, activeIdentity)
            guard !DiskUtility.isMountPoint(retained) else { throw DataOperationSafety.Failure.conflict(retained.path) }
            try requireIdentity(retained, retainedIdentity)
            try verifyRetainedTree(retained, identity: retainedIdentity, baseline: baseline)
            try safety.requireNoOverlap(at: retained, ownedTransferIDs: lineage, ownedLinkPath: activeLink?.originalPath, ownedRetainedPath: retained.path)
            try await safety.requireNoKnownWriters(at: retained, bundleIdentifier: transfer.bundleIdentifier)
            try await safety.requireNoKnownWriters(at: activeURL, bundleIdentifier: transfer.bundleIdentifier)
            try store.requestCleanup(operationID: operationID)
            transfer.phase = .cleanupRequested
            try requireIdentity(retained, retainedIdentity)
            try verifyRetainedTree(retained, identity: retainedIdentity, baseline: baseline)
            let type = DataDirType(rawValue: transfer.dataDirType) ?? .custom
            let marker = markerURL(for: retained)
            if try entryExists(marker) {
                try requireMarker(at: retained, for: URL(fileURLWithPath: transfer.originalPath), type: type, allowOwned: true)
                physicalCleanupStarted = true
                try removeManagedLinkMetadata(in: retained)
                try TreeCopySession.applyRootMetadata(at: retained, from: baseline)
            }
            try verifyRetainedTree(retained, identity: retainedIdentity, baseline: baseline)
            physicalCleanupStarted = true
            try TreeCopySession.removeVerifiedCopy(at: retained, against: baseline)
            guard try !entryExists(retained) else { throw DataOperationSafety.Failure.inspection(retained.path) }
            try store.finishTransfer(operationID: operationID, deletionConfirmed: true)
            invalidateSizeCache(for: retained)
        } catch {
            // Missing/offline data, occupied files, lineage ordering and intent-write
            // failures change no data. Keep their durable phase eligible for explicit retry.
            if physicalCleanupStarted { try recordFailure(&transfer, error: error) }
            throw error
        }
    }

    private func transferAncestors(of id: UUID, transfers: [DataTransferRecord]) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var current = id
        while let prior = transfers.first(where: { $0.operationID == current })?.priorOperationID,
              result.insert(prior).inserted { current = prior }
        return result
    }

    private func transferDescendants(of id: UUID, transfers: [DataTransferRecord]) -> Set<UUID> {
        var ids: Set<UUID> = [id]
        var previous = -1
        while ids.count != previous {
            previous = ids.count
            for candidate in transfers where candidate.priorOperationID.map(ids.contains) == true { ids.insert(candidate.operationID) }
        }
        return ids
    }

    private func requirePolicy(_ path: URL) throws {
        do { try safety.requirePolicy(at: path) }
        catch DataOperationSafety.Failure.protectedPath { throw DataDirError.protectedPath(path) }
    }

    private func copy(from source: URL, to destination: URL, final: URL, progress: FileCopier.ProgressHandler?) async throws -> TreeCopySnapshot {
        do { return try await TreeCopySession().copy(from: source, to: destination,
            excludingRootEntries: [managedLinkMarkerFileName], finalDestination: final, progressHandler: progress) }
        catch { throw DataDirError.copyFailed(error) }
    }

    private func installMarker(source: URL, destination: URL, type: DataDirType, baseline: TreeCopySnapshot) throws {
        try requireMarker(at: destination, for: source, type: type, allowOwned: true)
        do {
            try writeManagedLinkMetadata(sourcePath: source, destinationPath: destination, type: type)
            try TreeCopySession.applyRootMetadata(at: destination, from: baseline)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
        } catch { throw DataDirError.metadataWriteFailed(error) }
    }

    private func requireMarker(at root: URL, for source: URL, type: DataDirType, allowOwned: Bool) throws {
        let marker = markerURL(for: root)
        guard try entryExists(marker) else { return }
        guard allowOwned, !isSymbolicLink(at: marker),
              let data = try? Data(contentsOf: marker),
              let metadata = try? PropertyListDecoder().decode(ManagedLinkMetadata.self, from: data),
              metadata.schemaVersion == managedLinkSchemaVersion, metadata.managedBy == managedLinkIdentifier,
              metadata.dataDirType == type.rawValue,
              DataPathTopology.relationship(metadata.sourcePath, source.path) == .same,
              DataPathTopology.relationship(metadata.destinationPath, root.path) == .same else {
            throw DataDirError.metadataWriteFailed(DataOperationSafety.Failure.conflict(marker.path))
        }
    }

    private func recordFailure(_ transfer: inout DataTransferRecord, error: Error) throws -> Never {
        transfer.phase = .needsRecovery
        transfer.recoverableReason = error.localizedDescription
        // If this write fails, the previous durable phase still reserves all known copies.
        try store.updateTransfer(transfer)
        throw error
    }

    private func requireIdentity(_ url: URL, _ identity: DataPathIdentity) throws {
        guard try identity.matchesFilesystemObject(DataPathIdentity.capture(url)) else { throw DataOperationSafety.Failure.conflict(url.path) }
    }

    private func entryExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func renameWithoutReplacing(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The old entry stays inside the recorded staging directory until the replacement is installed.
    private func switchEntry(local: URL, expectedLink: DataPathIdentity?, replacement: URL, staging: URL) throws {
        let oldEntry = staging.appendingPathComponent("previous-entry")
        if let expectedLink {
            try requireIdentity(local, expectedLink)
            try renameWithoutReplacing(local, oldEntry)
            try requireIdentity(oldEntry, expectedLink)
        } else if try entryExists(local) { throw DataDirError.destinationExists(local) }
        do {
            if isSymbolicLink(at: replacement) { try renameWithoutReplacing(replacement, local) }
            else { try DataTreeRelocator.move(replacement, to: local) }
        }
        catch {
            if let expectedLink, try !entryExists(local) {
                try requireIdentity(oldEntry, expectedLink)
                try renameWithoutReplacing(oldEntry, local)
            }
            throw error
        }
        if let expectedLink {
            try requireIdentity(oldEntry, expectedLink)
            guard isSymbolicLink(at: oldEntry) else { throw DataOperationSafety.Failure.conflict(oldEntry.path) }
            try fileManager.removeItem(at: oldEntry)
        }
        if try fileManager.contentsOfDirectory(atPath: staging.path).isEmpty { try fileManager.removeItem(at: staging) }
    }

    private func verifyRetainedTree(_ root: URL, identity: DataPathIdentity, baseline: TreeCopySnapshot) throws {
        if let volumeUUID = identity.volumeUUID {
            try TreeCopySession.verifyUnchanged(at: root, against: baseline, expectedVolumeUUID: volumeUUID)
        } else {
            try TreeCopySession.verifyUnchanged(at: root, against: baseline)
        }
    }

    private func requireLocalRestoreParent(_ local: URL) throws {
        try safety.requireLocalRestoreParent(at: local)
    }

    private func checkWritePermission(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
        guard fileManager.isWritableFile(atPath: url.path) else { throw DataDirError.permissionDenied(url) }
    }

    private func createSymbolicLink(at localPath: URL, withDestinationURL externalPath: URL) throws {
        if failSymlinkCreation { throw CocoaError(.fileWriteUnknown) }
        try fileManager.createSymbolicLink(at: localPath, withDestinationURL: externalPath)
    }
    private func isSymbolicLink(at url: URL) -> Bool { (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil }
    private func existingDirectory(at url: URL) -> Bool {
        var directory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
    private func inferredBundleIdentifier(_ local: URL) -> String? {
        let base = homeDir.appendingPathComponent("Library/Containers").path
        guard local.path.hasPrefix(base + "/") else { return nil }
        return String(local.path.dropFirst(base.count + 1)).split(separator: "/").first.map(String.init)
    }

    private func writeManagedLinkMetadata(sourcePath: URL, destinationPath: URL, type: DataDirType) throws {
        let metadata = ManagedLinkMetadata(
            schemaVersion: managedLinkSchemaVersion,
            managedBy: managedLinkIdentifier,
            sourcePath: sourcePath.standardizedFileURL.path,
            destinationPath: destinationPath.standardizedFileURL.path,
            dataDirType: type.rawValue
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        let markerURL = markerURL(for: destinationPath)
        let data = try encoder.encode(metadata)
        try withWritableMetadataParent(for: markerURL) {
            try data.write(to: markerURL, options: .atomic)
        }
    }

    private func removeManagedLinkMetadata(in directoryURL: URL) throws {
        let markerURL = markerURL(for: directoryURL)
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        try withWritableMetadataParent(for: markerURL) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    /// Metadata work uses an open no-follow parent and restores the complete original mode.
    private func withWritableMetadataParent(for markerURL: URL, operation: () throws -> Void) throws {
        let parent = markerURL.deletingLastPathComponent()
        let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw POSIXError(.EPERM) }
        let identity = try DataPathIdentity.capture(parent)
        guard identity.device == UInt64(UInt32(bitPattern: info.st_dev)), identity.inode == UInt64(info.st_ino) else {
            throw DataOperationSafety.Failure.conflict(parent.path)
        }
        let permissions = info.st_mode & 0o7777
        let needsWrite = permissions & 0o200 == 0
        func restorePermissions() throws {
            guard !needsWrite || fchmod(descriptor, permissions) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var current = stat()
            guard fstat(descriptor, &current) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard current.st_mode & 0o7777 == permissions else { throw POSIXError(.EPERM) }
        }
        if needsWrite, fchmod(descriptor, permissions | 0o200) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try requireIdentity(parent, identity)
            try operation()
            try requireIdentity(parent, identity)
        } catch {
            try restorePermissions()
            throw error
        }
        try restorePermissions()
    }

    private func markerURL(for directoryURL: URL) -> URL {
        let standardizedURL = directoryURL.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])

        if values?.isDirectory == true {
            return standardizedURL.appendingPathComponent(managedLinkMarkerFileName)
        }

        return standardizedURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(standardizedURL.lastPathComponent)\(managedLinkMetadataSidecarSuffix)")
    }

    /// Type is part of a validated historical record, not a classification of its path.
    private func managedType(for local: URL, external: URL, indexedType: String?) throws -> DataDirType {
        if let indexedType, let type = DataDirType(rawValue: indexedType) { return type }
        let marker = markerURL(for: external)
        if try entryExists(marker) {
            guard !isSymbolicLink(at: marker),
                  let data = try? Data(contentsOf: marker),
                  let metadata = try? PropertyListDecoder().decode(ManagedLinkMetadata.self, from: data),
                  let type = DataDirType(rawValue: metadata.dataDirType) else {
                throw DataDirError.metadataWriteFailed(DataOperationSafety.Failure.conflict(marker.path))
            }
            try requireMarker(at: external, for: local, type: type, allowOwned: true)
            return type
        }
        return inferType(for: local) ?? .custom
    }

    private func inferType(for localPath: URL) -> DataDirType? {
        let path = localPath.standardizedFileURL.path
        let libraryRoot = homeDir.appendingPathComponent("Library")

        let mappings: [(URL, DataDirType)] = [
            (libraryRoot.appendingPathComponent("Application Support"), .applicationSupport),
            (libraryRoot.appendingPathComponent("Preferences"), .preferences),
            (libraryRoot.appendingPathComponent("Containers"), .containers),
            (libraryRoot.appendingPathComponent("Group Containers"), .groupContainers),
            (libraryRoot.appendingPathComponent("Application Scripts"), .applicationScripts),
            (libraryRoot.appendingPathComponent("Caches"), .caches),
            (libraryRoot.appendingPathComponent("WebKit"), .webKit),
            (libraryRoot.appendingPathComponent("HTTPStorages"), .httpStorages),
            (libraryRoot.appendingPathComponent("Logs"), .logs),
            (libraryRoot.appendingPathComponent("Saved Application State"), .savedState)
        ]

        for (baseURL, type) in mappings where path.hasPrefix(baseURL.standardizedFileURL.path + "/") {
            return type
        }

        if path.hasPrefix(homeDir.standardizedFileURL.path + "/.") {
            return .dotFolder
        }

        return .custom
    }
}

// MARK: - 错误类型

/// 数据目录迁移操作中的错误类型
enum DataDirError: LocalizedError {
    case permissionDenied(URL)
    case destinationExists(URL)
    case deletionFailed(Error)
    case symlinkFailed(Error)
    case copyFailed(Error)
    case metadataWriteFailed(Error)
    case notASymlink(URL)
    case invalidSymlink(URL)
    case externalNotFound(URL)
    case protectedPath(URL)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let url):
            return String(format: "没有写入权限：%@".localized, url.path)
        case .destinationExists(let url):
            return String(format: "目标路径已存在真实目录，无法覆盖：%@".localized, url.lastPathComponent)
        case .deletionFailed(let error):
            return String(format: "删除原目录失败：%@".localized, error.localizedDescription)
        case .symlinkFailed(let error):
            return String(format: "创建符号链接失败：%@".localized, error.localizedDescription)
        case .copyFailed(let error):
            return String(format: "复制失败：%@".localized, error.localizedDescription)
        case .metadataWriteFailed(let error):
            return String(format: "写入 AppPorts 链接标记失败：%@".localized, error.localizedDescription)
        case .notASymlink(let url):
            return String(format: "该目录不是符号链接，无法还原：%@".localized, url.lastPathComponent)
        case .invalidSymlink(let url):
            return String(format: "无法读取符号链接目标：%@".localized, url.lastPathComponent)
        case .externalNotFound(let url):
            return String(format: "外部存储目录不存在：%@".localized, url.path)
        case .protectedPath(let url):
            return String(format: "该目录受 macOS 系统保护，无法迁移：%@。请改为迁移容器内的子目录。".localized, url.lastPathComponent)
        }
    }
}
