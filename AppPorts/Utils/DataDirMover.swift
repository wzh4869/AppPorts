import Darwin
import Foundation

/// Low-level data-tree operations retain originals; complete user flows clean
/// their verified copies after the successful switch has been committed.
/// UI flags never authorize execution; every entry point evaluates real paths and durable topology.
actor DataDirMover {
    struct CompletionResult: Sendable {
        /// The data switch succeeded. A warning refers only to retained-copy cleanup.
        let cleanupWarning: String?
    }

    enum CompletionError: LocalizedError {
        case previousRestoreNeedsCleanup(String)

        var errorDescription: String? {
            switch self {
            case .previousRestoreNeedsCleanup(let details):
                return String(format: "上次还原的旧副本尚未清理，新的迁移尚未开始。AppPorts 会继续完成清理，条件恢复后可直接重试。%@".localized, "\n" + details)
            }
        }
    }

    private let fileManager = FileManager.default
    private let homeDir: URL
    private let store: ContainerMountStore
    private let safety: DataOperationSafety
    private let mountMigrator: ContainerVolumeMigrator?
    private let failSymlinkCreation: Bool
    private let synchronizeDirectory: @Sendable (URL, Bool) throws -> Void
    private var runningMigrations: Set<UUID> = []
    private var runningRestores: Set<UUID> = []
    private var runningCleanups: Set<UUID> = []
    private var completingPaths: Set<String> = []
    private let managedLinkMarkerFileName = ".appports-link-metadata.plist"
    private let managedLinkMetadataSidecarSuffix = ".appports-link-metadata.plist"
    private let managedLinkIdentifier = "com.shimoko.AppPorts"
    private let managedLinkSchemaVersion = 1

    private var launchProtectionDirectory: URL {
        store.fileURLForDeletionAuthorization.deletingLastPathComponent()
            .appendingPathComponent("launch-locks", isDirectory: true)
    }

    private func launchIdentifier(for item: DataDirItem) throws -> String? {
        let path = item.path.standardizedFileURL.path
        return try item.associatedBundleIdentifier
            ?? store.managedLink(forOriginalPath: path)?.bundleIdentifier
            ?? store.transfers().last(where: { $0.originalPath == path })?.bundleIdentifier
    }

    private struct ManagedLinkMetadata: Codable, Sendable {
        let schemaVersion: Int
        let managedBy: String
        let sourcePath: String
        let destinationPath: String
        let dataDirType: String
    }

    init(homeDir: URL = URL(fileURLWithPath: NSHomeDirectory()),
         failSymlinkCreation: Bool = false, failSourceBackupCleanup: Bool = false,
         store: ContainerMountStore = .shared, runner: any ShellCommandRunning = ProcessCommandRunner(),
         mountMigrator: ContainerVolumeMigrator? = nil,
         synchronizeDirectory: @escaping @Sendable (URL, Bool) throws -> Void = {
             try DurableFileIO.syncDirectory(at: $0, resolvingAlias: $1)
         }) {
        self.homeDir = homeDir.standardizedFileURL
        self.store = store
        self.safety = DataOperationSafety(homeDirectory: homeDir, store: store, runner: runner)
        self.mountMigrator = mountMigrator
        self.failSymlinkCreation = failSymlinkCreation
        self.synchronizeDirectory = synchronizeDirectory
        // Kept source-compatible with older callers. Success now always retains the original.
        _ = failSourceBackupCleanup
    }

    /// Complete the ordinary user flow while keeping cleanup failures separate
    /// from a successful data switch. The caller holds the shared operation lock.
    func migrateAndComplete(item: DataDirItem, to externalBaseURL: URL,
                            progressHandler: FileCopier.ProgressHandler?) async throws -> CompletionResult {
        let identifier = try launchIdentifier(for: item)
        if !ApplicationLaunchProtection.contains(identifier, directory: launchProtectionDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: identifier, directory: launchProtectionDirectory) {
                try await self.migrateAndComplete(item: item, to: externalBaseURL, progressHandler: progressHandler)
            }
        }
        let path = item.path.standardizedFileURL.path
        guard completingPaths.insert(path).inserted else { throw DataOperationSafety.Failure.occupied(path) }
        defer { completingPaths.remove(path) }
        try await completePreviousRestoreIfNeeded(item: item, externalBaseURL: externalBaseURL, progressHandler: progressHandler)
        let operationID = try await migrateRetainingOriginal(item: item, to: externalBaseURL, progressHandler: progressHandler)
        return await completeSuccessfulTransfer(operationID: operationID, direction: .migrate, progressHandler: progressHandler)
    }

    func restoreAndComplete(item: DataDirItem,
                            progressHandler: FileCopier.ProgressHandler?) async throws -> CompletionResult {
        let identifier = try launchIdentifier(for: item)
        if !ApplicationLaunchProtection.contains(identifier, directory: launchProtectionDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: identifier, directory: launchProtectionDirectory) {
                try await self.restoreAndComplete(item: item, progressHandler: progressHandler)
            }
        }
        try await completeInterruptedMigrationBeforeRestore(at: item.path, progressHandler: progressHandler)
        let path = item.path.standardizedFileURL.path
        guard completingPaths.insert(path).inserted else { throw DataOperationSafety.Failure.occupied(path) }
        defer { completingPaths.remove(path) }
        let operationID = try await restoreRetainingOriginal(item: item, progressHandler: progressHandler)
        return await completeSuccessfulTransfer(operationID: operationID, direction: .restore,
            progressHandler: progressHandler, requireUnchangedActive: false)
    }

    /// Low-level recovery callers may deliberately retain the verified original.
    func migrate(item: DataDirItem, to externalBaseURL: URL, progressHandler: FileCopier.ProgressHandler?) async throws {
        let identifier = try launchIdentifier(for: item)
        if !ApplicationLaunchProtection.contains(identifier, directory: launchProtectionDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: identifier, directory: launchProtectionDirectory) {
                try await self.migrate(item: item, to: externalBaseURL, progressHandler: progressHandler)
            }
        }
        _ = try await migrateRetainingOriginal(item: item, to: externalBaseURL, progressHandler: progressHandler)
    }

    private func migrateRetainingOriginal(item: DataDirItem, to externalBaseURL: URL,
                                          progressHandler: FileCopier.ProgressHandler?, reusingOperationID: UUID? = nil) async throws -> UUID {
        let identifier = try launchIdentifier(for: item)
        DataTransferSession.progress?.setDirectory(item.path)
        DataTransferSession.progress?.observeDirectoryWorkflow()
        await progressHandler?(.working(.preparing))
        let source = item.path.standardizedFileURL
        let destination = externalBaseURL.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        try requirePolicy(source)
        guard !isSymbolicLink(at: source) else { throw DataDirError.destinationExists(source) }
        guard !DiskUtility.isMountPoint(source) else { throw DataOperationSafety.Failure.conflict(source.path) }
        guard try !entryExists(destination) else { throw DataDirError.destinationExists(destination) }
        try requireMarker(at: source, for: source, type: item.type, allowOwned: false)
        let restored = try completedRestoreLineage(at: source)
        try await safety.requireNewMigration(at: source, destination: destination,
            bundleIdentifier: identifier, ownedTransferIDs: Set(restored.map(\.operationID)))
        // Reject known permission failures before reserving a recovery record.
        // Directory creation still happens only after the durable intent below.
        let destinationVolumeUUID = try preflightWritePermission(at: externalBaseURL)
        let id = reusingOperationID ?? UUID()
        let candidate = externalBaseURL.appendingPathComponent(".appports-copy-\(id.uuidString)").standardizedFileURL
        let backup = source.deletingLastPathComponent().appendingPathComponent(".appports-migration-backup-\(source.lastPathComponent)-\(id)")
        var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .migrate, sourceID: item.id,
            appName: item.associatedAppName ?? item.name, bundleIdentifier: identifier,
            dataDirType: item.type.rawValue, originalPath: source.path, activePath: source.path,
            destinationPath: destination.path, backupPath: backup.path,
            sourceIdentity: try DataPathIdentity.capture(source), destinationVolumeUUID: destinationVolumeUUID,
            priorOperationID: restored.last?.operationID)
        transfer.preparationPath = candidate.path
        try store.beginTransfer(transfer)
        runningMigrations.insert(id)
        defer { runningMigrations.remove(id) }
        do {
            try checkWritePermission(at: externalBaseURL)
            if let destinationVolumeUUID {
                try requireDestinationVolume(at: externalBaseURL, expected: destinationVolumeUUID)
            }
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copy(from: source, to: candidate, final: destination, operationID: id,
                verifyDestinationAfterCopy: false, progress: progressHandler)
            transfer = try store.transfer(operationID: id) ?? transfer
            try requireMarker(at: source, for: source, type: item.type, allowOwned: false)
            await progressHandler?(.init(copiedBytes: baseline.logicalBytes, totalBytes: baseline.logicalBytes, currentFile: "正在切换本地入口...".localized, showsByteProgress: false, stage: .switching))
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: identifier)
            try requireIdentity(source, transfer.sourceIdentity)
            try requireMarker(at: source, for: source, type: item.type, allowOwned: false)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try TreeCopySession.verifyCopy(at: candidate, against: baseline, purpose: .beforeSwitch)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            try moveTree(candidate, to: destination)
            try syncDirectory(at: destination.deletingLastPathComponent())
            try installMarker(source: source, destination: destination, type: item.type, baseline: baseline)
            try syncTree(at: destination)
            // Publishing is a same-volume rename. Marker installation verifies
            // the root metadata it changes; payload readback is already complete.
            transfer.phase = .switching
            try store.updateTransfer(transfer)
            DataTransferSession.progress?.observeEntrySwitch()
            try moveTree(source, to: backup)
            try syncDirectory(at: source.deletingLastPathComponent())
            transfer.backupIdentity = try DataPathIdentity.capture(backup)
            try requireIdentity(backup, transfer.sourceIdentity)
            try store.updateTransfer(transfer)
            await progressHandler?(.init(copiedBytes: baseline.logicalBytes, totalBytes: baseline.logicalBytes, currentFile: "正在创建符号链接...".localized, showsByteProgress: false, stage: .switching))
            try requireMarker(at: backup, for: source, type: item.type, allowOwned: false)
            try TreeCopySession.verifyUnchanged(at: backup, against: baseline)
            do { try createSymbolicLink(at: source, withDestinationURL: destination) }
            catch {
                // The backup is still complete; never overwrite a competing entry during rollback.
                if try !entryExists(source) { try moveTree(backup, to: source) }
                throw DataDirError.symlinkFailed(error)
            }
            transfer.activePath = destination.path
            try syncDirectory(at: source.deletingLastPathComponent())
            try store.commitMigration(record: nil, transfer: transfer)
            invalidateSizeCache(for: source)
            invalidateSizeCache(for: destination)
            return id
        } catch {
            // A copier preflight can fail before it creates anything. Retrying
            // such an operation needs no recovery once absence is proven.
            if removeUnstartedIntentIfSafe(transfer) { throw error }
            try recordFailure(&transfer, error: error)
        }
    }

    func restore(item: DataDirItem, progressHandler: FileCopier.ProgressHandler?) async throws {
        let identifier = try launchIdentifier(for: item)
        if !ApplicationLaunchProtection.contains(identifier, directory: launchProtectionDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: identifier, directory: launchProtectionDirectory) {
                try await self.restore(item: item, progressHandler: progressHandler)
            }
        }
        try await completeInterruptedMigrationBeforeRestore(at: item.path, progressHandler: progressHandler)
        _ = try await restoreRetainingOriginal(item: item, progressHandler: progressHandler)
    }

    private func completeInterruptedMigrationBeforeRestore(at local: URL, progressHandler: FileCopier.ProgressHandler?) async throws {
        let transfers = try store.transfers()
        let pending = transfers.filter { $0.mode == .symlink && $0.direction == .migrate && $0.originalPath == local.standardizedFileURL.path
            && $0.isVerifiedSwitchRecoverable }
        for transfer in pending {
            guard !transfers.contains(where: { $0.priorOperationID == transfer.operationID }) else { continue }
            _ = try await resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: progressHandler)
        }
    }

    private func restoreRetainingOriginal(item: DataDirItem,
                                          progressHandler: FileCopier.ProgressHandler?, reusingOperationID: UUID? = nil) async throws -> UUID {
        let identifier = try launchIdentifier(for: item)
        DataTransferSession.progress?.setDirectory(item.path)
        DataTransferSession.progress?.observeDirectoryWorkflow()
        await progressHandler?(.working(.preparing))
        let local = item.path.standardizedFileURL
        try finishUnstartedRestoreIfNeeded(at: local)
        let indexed = try store.managedLink(forOriginalPath: local.path)
        let existingTransfers = try store.transfers()
        if !isSymbolicLink(at: local), indexed == nil,
           let completed = existingTransfers.last(where: { $0.direction == .restore && $0.originalPath == local.path && [.awaitingUserVerification, .cleanupRequested].contains($0.phase) }),
           let identity = completed.destinationIdentity, let current = try? DataPathIdentity.capture(local), identity.matchesFilesystemObject(current) { return completed.operationID }
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
        try await safety.requireNoKnownWriters(at: external, bundleIdentifier: identifier)
        let id = reusingOperationID ?? UUID()
        let staging = local.deletingLastPathComponent().appendingPathComponent(".appports-restore-\(id)")
        let copyURL = staging.appendingPathComponent("data")
        var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .restore, sourceID: item.id,
            appName: item.associatedAppName ?? item.name, bundleIdentifier: identifier,
            dataDirType: item.type.rawValue, originalPath: local.path, activePath: external.path, destinationPath: local.path,
            backupPath: external.path, stagingPath: staging.path, sourceIdentity: sourceIdentity,
            backupIdentity: sourceIdentity, priorOperationID: prior)
        transfer.preparationPath = copyURL.path
        transfer.stagingParentIdentity = try DataPathIdentity.capture(staging.deletingLastPathComponent())
        try store.beginTransfer(transfer)
        runningRestores.insert(id)
        defer { runningRestores.remove(id) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            try syncDirectory(at: staging.deletingLastPathComponent())
            transfer.stagingIdentity = try DataPathIdentity.capture(staging)
            try store.updateTransfer(transfer)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copy(from: external, to: copyURL, final: local, operationID: id,
                verifyDestinationAfterCopy: false, progress: progressHandler)
            transfer = try store.transfer(operationID: id) ?? transfer
            try await safety.requireNoKnownWriters(at: external, bundleIdentifier: transfer.bundleIdentifier)
            try requireIdentity(external, sourceIdentity)
            try requireMarker(at: external, for: local, type: item.type, allowOwned: true)
            try TreeCopySession.verifyUnchanged(at: external, against: baseline)
            try TreeCopySession.verifyCopy(at: copyURL, against: baseline, purpose: .beforeSwitch)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            try requireLocalRestoreParent(local)
            try store.beginRestore(transfer: transfer, removingMount: nil)
            transfer.phase = .switching
            try requireIdentity(copyURL, transfer.destinationIdentity!)
            DataTransferSession.progress?.observeEntrySwitch()
            try switchEntry(local: local, expectedLink: linkIdentity, replacement: copyURL, staging: staging)
            transfer.activePath = local.path
            try syncTree(at: local)
            try store.updateTransfer(transfer)
            try store.finalizeTransfer(operationID: id, baseline: transfer.baseline!)
            invalidateSizeCache(for: local)
            invalidateSizeCache(for: external)
            return id
        } catch {
            if removeUnstartedRestoreIntentIfSafe(transfer) { throw error }
            try recordFailure(&transfer, error: error)
        }
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
        try installMarker(source: local, destination: external, type: type, baseline: baseline, ownershipRole: .source)
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
    /// Discard an unmanaged local link without reading or changing its target.
    /// Existing managed transfers must use their ordinary recovery flow.
    func resetExistingLink(item: DataDirItem, expectedDestination: URL) async throws {
        let identifier = try launchIdentifier(for: item)
        if !ApplicationLaunchProtection.contains(identifier, directory: launchProtectionDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: identifier, directory: launchProtectionDirectory) {
                try await self.resetExistingLink(item: item, expectedDestination: expectedDestination)
            }
        }
        let local = item.path.standardizedFileURL
        guard completingPaths.insert(local.path).inserted else { throw DataOperationSafety.Failure.occupied(local.path) }
        defer { completingPaths.remove(local.path) }
        try requirePolicy(local)
        try safety.requireLocalRestoreParent(at: local)
        try safety.requireNoOverlap(at: local)
        try safety.requireApplicationStopped(at: local, bundleIdentifier: identifier)
        guard isSymbolicLink(at: local) else { throw DataDirError.notASymlink(local) }
        let identity = try DataPathIdentity.capture(local)
        let rawTarget = try fileManager.destinationOfSymbolicLink(atPath: local.path)
        let target = URL(fileURLWithPath: rawTarget, relativeTo: local.deletingLastPathComponent()).standardizedFileURL
        guard target.path == expectedDestination.standardizedFileURL.path else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        try Task.checkCancellation()
        let staging = local.deletingLastPathComponent().appendingPathComponent(".appports-unlink-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        let replacement = staging.appendingPathComponent("empty-directory")
        do {
            try fileManager.createDirectory(at: replacement, withIntermediateDirectories: false)
            try requireLocalRestoreParent(local)
            try switchEntry(local: local, expectedLink: identity, replacement: replacement, staging: staging)
        } catch {
            // Remove only empty directories. Never recursively remove a retained entry.
            _ = rmdir(replacement.path)
            _ = rmdir(staging.path)
            if try entryExists(staging) {
                throw DataOperationSafety.Failure.inspection(error.localizedDescription + "\n" + staging.path)
            }
            throw error
        }
    }

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
        try removeEntry(at: localPath)
    }

    func normalizeManagedLinkAndComplete(localPath: URL, currentExternalPath: URL, normalizedExternalPath: URL,
                                         progressHandler: FileCopier.ProgressHandler? = nil) async throws -> CompletionResult {
        let path = localPath.standardizedFileURL.path
        guard completingPaths.insert(path).inserted else { throw DataOperationSafety.Failure.occupied(path) }
        defer { completingPaths.remove(path) }
        guard let operationID = try await normalizeRetainingOriginal(localPath: localPath,
            currentExternalPath: currentExternalPath, normalizedExternalPath: normalizedExternalPath,
            progressHandler: progressHandler) else { return CompletionResult(cleanupWarning: nil) }
        return await completeSuccessfulTransfer(operationID: operationID, direction: .migrate, progressHandler: progressHandler)
    }

    func normalizeManagedLink(localPath: URL, currentExternalPath: URL, normalizedExternalPath: URL) async throws {
        _ = try await normalizeRetainingOriginal(localPath: localPath, currentExternalPath: currentExternalPath,
                                                 normalizedExternalPath: normalizedExternalPath, progressHandler: nil)
    }

    private func normalizeRetainingOriginal(localPath: URL, currentExternalPath: URL, normalizedExternalPath: URL,
                                            progressHandler: FileCopier.ProgressHandler?, reusingOperationID: UUID? = nil) async throws -> UUID? {
        let local = localPath.standardizedFileURL
        let source = currentExternalPath.standardizedFileURL
        let destination = normalizedExternalPath.standardizedFileURL
        DataTransferSession.progress?.setDirectory(local)
        DataTransferSession.progress?.observeDirectoryWorkflow()
        try requirePolicy(local)
        guard existingDirectory(at: source), !isSymbolicLink(at: source) else { throw DataDirError.externalNotFound(source) }
        guard isSymbolicLink(at: local), DataPathTopology.relationship(local.path, source.path) == .same else { throw DataDirError.invalidSymlink(local) }
        if DataPathTopology.relationship(source.path, destination.path) == .same { return nil }
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
        try requireIdentity(source, sourceIdentity)
        let id = reusingOperationID ?? UUID()
        let staging = local.deletingLastPathComponent().appendingPathComponent(".appports-normalize-\(id)")
        let candidate = destination.deletingLastPathComponent().appendingPathComponent(".appports-copy-\(id)")
        let linkIdentity = try DataPathIdentity.capture(local)
        var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .migrate, sourceID: local.path,
            appName: old?.appName ?? local.lastPathComponent, bundleIdentifier: old?.bundleIdentifier ?? inferredBundleIdentifier(local),
            dataDirType: type.rawValue, originalPath: local.path, activePath: source.path, destinationPath: destination.path,
            backupPath: source.path, stagingPath: staging.path, sourceIdentity: sourceIdentity, backupIdentity: sourceIdentity,
            priorOperationID: old?.operationID)
        transfer.preparationPath = candidate.path
        transfer.stagingParentIdentity = try DataPathIdentity.capture(staging.deletingLastPathComponent())
        transfer.destinationVolumeUUID = try preflightWritePermission(at: destination.deletingLastPathComponent())
        try store.beginTransfer(transfer)
        runningMigrations.insert(id)
        defer { runningMigrations.remove(id) }
        do {
            try checkWritePermission(at: destination.deletingLastPathComponent())
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            try syncDirectory(at: staging.deletingLastPathComponent())
            transfer.stagingIdentity = try DataPathIdentity.capture(staging)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copy(from: source, to: candidate, final: destination, operationID: id, progress: progressHandler)
            transfer = try store.transfer(operationID: id) ?? transfer
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            try moveTree(candidate, to: destination)
            try syncDirectory(at: destination.deletingLastPathComponent())
            try installMarker(source: local, destination: destination, type: type, baseline: baseline)
            try syncTree(at: destination)
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: transfer.bundleIdentifier)
            try requireIdentity(source, sourceIdentity)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            let newLink = staging.appendingPathComponent("new-link")
            try createSymbolicLink(at: newLink, withDestinationURL: destination)
            transfer.phase = .switching
            try store.updateTransfer(transfer)
            DataTransferSession.progress?.observeEntrySwitch()
            try switchEntry(local: local, expectedLink: linkIdentity, replacement: newLink, staging: staging)
            transfer.activePath = destination.path
            try requireIdentity(source, sourceIdentity)
            try requireIdentity(destination, transfer.destinationIdentity!)
            try syncDirectory(at: local.deletingLastPathComponent())
            try store.commitMigration(record: nil, transfer: transfer)
            invalidateSizeCache(for: source)
            invalidateSizeCache(for: destination)
            return id
        } catch { try recordFailure(&transfer, error: error) }
    }

    /// Release a failed initial migration without deleting or moving any files.
    /// The caller holds the same outer operation lock used by migration itself.
    func cancelUnstartedMigration(operationID: UUID) async throws {
        if try store.transfer(operationID: operationID)?.isPreparationRecoverable == true {
            try await cancelPreparation(operationID: operationID)
            return
        }
        guard !runningMigrations.contains(operationID) else {
            throw DataOperationSafety.Failure.occupied(operationID.uuidString)
        }
        guard let expected = try store.transfer(operationID: operationID) else {
            throw ContainerMountStore.StoreError.missingTransfer(operationID)
        }
        try store.cancelUnstartedMigration(expected) {
            try requireUnstartedMigrationFilesystem(expected)
        }
    }

    func cancelUnstartedRestore(operationID: UUID) async throws {
        if try store.transfer(operationID: operationID)?.isPreparationRecoverable == true {
            try await cancelPreparation(operationID: operationID)
            return
        }
        guard !runningRestores.contains(operationID) else { throw DataOperationSafety.Failure.occupied(operationID.uuidString) }
        guard let expected = try store.transfer(operationID: operationID) else {
            throw ContainerMountStore.StoreError.missingTransfer(operationID)
        }
        try cancelUnstartedRestore(expected)
    }

    func cancelPreparation(operationID: UUID, preserveUnclaimedMaterials: Bool = false) async throws {
        guard let expected = try store.transfer(operationID: operationID) else { return }
        guard !runningMigrations.contains(operationID), !runningRestores.contains(operationID),
              completingPaths.insert(expected.originalPath).inserted else {
            throw DataOperationSafety.Failure.occupied(expected.originalPath)
        }
        defer { completingPaths.remove(expected.originalPath) }
        try await cancelPreparation(expected, preserveUnclaimedMaterials: preserveUnclaimedMaterials)
    }

    private func restartPreparation(_ expected: DataTransferRecord,
                                    progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
        guard completingPaths.insert(expected.originalPath).inserted else {
            throw DataOperationSafety.Failure.occupied(expected.originalPath)
        }
        defer { completingPaths.remove(expected.originalPath) }
        try await cancelPreparation(expected, preserveUnclaimedMaterials: false)
        let local = URL(fileURLWithPath: expected.originalPath)
        let item = DataDirItem(name: local.lastPathComponent, path: local,
            type: DataDirType(rawValue: expected.dataDirType) ?? .custom, priority: .recommended,
            description: "", associatedAppName: expected.appName, associatedBundleIdentifier: expected.bundleIdentifier)
        let id: UUID
        if expected.direction == .restore {
            id = try await restoreRetainingOriginal(item: item, progressHandler: progressHandler, reusingOperationID: expected.operationID)
        } else if expected.activePath == expected.originalPath {
            id = try await migrateRetainingOriginal(item: item,
                to: URL(fileURLWithPath: expected.destinationPath).deletingLastPathComponent(),
                progressHandler: progressHandler, reusingOperationID: expected.operationID)
        } else {
            guard let newID = try await normalizeRetainingOriginal(localPath: local,
                currentExternalPath: URL(fileURLWithPath: expected.activePath),
                normalizedExternalPath: URL(fileURLWithPath: expected.destinationPath), progressHandler: progressHandler,
                reusingOperationID: expected.operationID) else { return nil }
            id = newID
        }
        return await completeSuccessfulTransfer(operationID: id, direction: expected.direction,
            progressHandler: progressHandler, requireUnchangedActive: false).cleanupWarning
    }

    /// Cancellation proves the authoritative source and the unchanged record;
    /// it does not mistake a missing verified baseline for an empty target.
    private func preparationSource(_ transfer: DataTransferRecord, verifyContents: Bool, checkLedger: Bool = true) throws -> URL {
        guard transfer.mode == .symlink, transfer.isPreparationRecoverable else {
            throw DataOperationSafety.Failure.conflict(transfer.originalPath)
        }
        if checkLedger {
            guard try store.transfer(operationID: transfer.operationID) == transfer,
                  !(try store.transfers()).contains(where: { $0.priorOperationID == transfer.operationID }) else {
                throw DataOperationSafety.Failure.conflict(transfer.originalPath)
            }
        }
        let local = URL(fileURLWithPath: transfer.originalPath)
        let source = URL(fileURLWithPath: transfer.activePath)
        guard !isSymbolicLink(at: source), !DiskUtility.isMountPoint(source) || source != local else {
            throw DataOperationSafety.Failure.conflict(source.path)
        }
        try requireIdentity(source, transfer.sourceIdentity)
        if transfer.direction == .migrate, source == local {
            guard let backup = transfer.backupPath, try !entryExists(URL(fileURLWithPath: backup)) else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        } else {
            if isSymbolicLink(at: local) {
                guard linkPoints(local, to: source) else { throw DataOperationSafety.Failure.conflict(local.path) }
            } else {
                guard try !entryExists(local) else { throw DataOperationSafety.Failure.conflict(local.path) }
                if checkLedger {
                    guard let indexed = try store.managedLink(forOriginalPath: local.path),
                          indexed.operationID == transfer.priorOperationID,
                          indexed.destinationPath == source.path,
                          indexed.destinationIdentity.matchesFilesystemObject(transfer.sourceIdentity) else {
                        throw DataOperationSafety.Failure.conflict(local.path)
                    }
                }
            }
        }
        if verifyContents, let encoded = transfer.sourceBaseline {
            try verifyRetainedTree(source, identity: transfer.sourceIdentity,
                                  baseline: PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded))
        }
        return source
    }

    private func cancelPreparation(_ expected: DataTransferRecord, preserveUnclaimedMaterials: Bool) async throws {
        var transfer = expected
        let source = try preparationSource(transfer, verifyContents: !preserveUnclaimedMaterials)
        if preserveUnclaimedMaterials {
            try store.endUnswitchedTransfer(transfer,
                preserving: "已结束未切换的尝试；以下材料仍保留，未确认归属的内容不会自动删除。".localized) {
                _ = try preparationSource(transfer, verifyContents: false, checkLedger: false)
            }
            return
        }
        let root: URL
        if let path = transfer.preparationPath { root = URL(fileURLWithPath: path) }
        else if transfer.direction == .restore, let staging = transfer.stagingPath {
            root = URL(fileURLWithPath: staging).appendingPathComponent("data")
        } else { root = URL(fileURLWithPath: transfer.destinationPath) }
        let parent = root.deletingLastPathComponent()
        if transfer.direction == .restore, transfer.preparationRemovalBaseline != nil,
           let grandparentIdentity = transfer.stagingParentIdentity, try !entryExists(parent) {
            try requireIdentity(parent.deletingLastPathComponent(), grandparentIdentity)
            try syncDirectory(at: parent.deletingLastPathComponent())
            try store.endUnswitchedTransfer(transfer) {
                _ = try preparationSource(transfer, verifyContents: true, checkLedger: false)
            }
            return
        }
        // A legacy no-target intent retains its established strict absence check.
        if transfer.sourceBaseline == nil, transfer.destinationIdentity == nil {
            if transfer.isUnstartedSymlinkMigration, transfer.preparationPath == nil {
                try store.cancelUnstartedMigration(transfer) { try requireUnstartedMigrationFilesystem(transfer) }
                return
            }
            if transfer.isUnstartedSymlinkRestore {
                try cancelUnstartedRestore(transfer)
                return
            }
        }
        if let expectedParent = transfer.preparationParentIdentity {
            try requireIdentity(parent, expectedParent)
        } else if transfer.direction == .migrate, let uuid = transfer.destinationVolumeUUID {
            try requireDestinationVolume(at: parent, expected: uuid)
        }
        let actual = try TreeCopySession.retainedRemovalURL(at: root, removalID: transfer.operationID)
        if let actual {
            guard let identity = transfer.destinationIdentity, let encoded = transfer.sourceBaseline,
                  transfer.preparationParentIdentity != nil,
                  !isSymbolicLink(at: actual), !DiskUtility.isMountPoint(actual) else {
                throw DataOperationSafety.Failure.inspection(actual.path)
            }
            try requireIdentity(actual, identity)
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: transfer.bundleIdentifier)
            try await safety.requireNoKnownWriters(at: actual, bundleIdentifier: nil)
            _ = try preparationSource(transfer, verifyContents: true)
            try requireIdentity(actual, identity)
            try requireIdentity(parent, transfer.preparationParentIdentity!)
            let wasRemoving = transfer.preparationRemovalBaseline != nil
            let removal: TreeCopySnapshot
            if let saved = transfer.preparationRemovalBaseline {
                removal = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: saved)
            } else {
                // Product markers are not payload. A partial symlink candidate
                // has not installed one, so an unexpected marker is a conflict.
                guard try !entryExists(markerURL(for: actual)) else { throw DataOperationSafety.Failure.conflict(actual.path) }
                removal = try TreeCopySession.partialCopySnapshot(at: actual, source: source,
                    against: PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded),
                    sourceVolumeUUID: transfer.sourceIdentity.volumeUUID)
                transfer.preparationRemovalBaseline = try PropertyListEncoder().encode(removal)
                transfer.preparationRemovalParentIdentity = try DataPathIdentity.capture(parent)
                try store.updateTransfer(transfer)
            }
            try syncTree(at: source)
            try store.recheckWriterAdmission()
            try TreeCopySession.removeVerifiedCopy(at: root, against: removal, allowPartialRemoval: wasRemoving,
                expectedVolumeUUID: identity.volumeUUID, removalID: transfer.operationID)
            try syncDirectory(at: parent)
        } else if transfer.destinationIdentity != nil {
            guard let expectedParent = transfer.preparationRemovalParentIdentity else {
                throw DataOperationSafety.Failure.inspection(root.path)
            }
            try requireIdentity(parent, expectedParent)
            try syncDirectory(at: parent)
        }
        if transfer.direction == .migrate, root.path != transfer.destinationPath {
            guard try !entryExists(URL(fileURLWithPath: transfer.destinationPath)) else {
                throw DataOperationSafety.Failure.conflict(transfer.destinationPath)
            }
        }
        if let path = transfer.stagingPath {
            let staging = URL(fileURLWithPath: path)
            if try entryExists(staging) {
                guard let identity = transfer.stagingIdentity, let parentIdentity = transfer.stagingParentIdentity,
                      !isSymbolicLink(at: staging), !DiskUtility.isMountPoint(staging) else {
                    throw DataOperationSafety.Failure.inspection(path)
                }
                try requireIdentity(staging, identity)
                try requireIdentity(staging.deletingLastPathComponent(), parentIdentity)
                try store.recheckWriterAdmission()
                guard try fileManager.contentsOfDirectory(atPath: path).isEmpty, rmdir(path) == 0 else {
                    throw DataOperationSafety.Failure.conflict(path)
                }
                try syncDirectory(at: staging.deletingLastPathComponent())
            }
        }
        try store.endUnswitchedTransfer(transfer) {
            _ = try preparationSource(transfer, verifyContents: true, checkLedger: false)
        }
    }

    private func publishVerifiedPreparation(_ transfer: DataTransferRecord, baseline: TreeCopySnapshot) throws {
        guard transfer.direction == .migrate,
              let path = transfer.preparationPath, let identity = transfer.destinationIdentity else { return }
        let candidate = URL(fileURLWithPath: path)
        let final = URL(fileURLWithPath: transfer.destinationPath)
        let local = URL(fileURLWithPath: transfer.originalPath)
        if try entryExists(candidate) {
            let sourceStillActive = transfer.stagingPath == nil ? !isSymbolicLink(at: local)
                : transfer.backupPath.map { linkPoints(local, to: URL(fileURLWithPath: $0)) } == true
            guard try !entryExists(final), sourceStillActive,
                  let parent = transfer.preparationParentIdentity else { throw DataOperationSafety.Failure.conflict(final.path) }
            try requireIdentity(candidate.deletingLastPathComponent(), parent)
            try requireIdentity(candidate, identity)
            try TreeCopySession.verifyCopy(at: candidate, against: baseline)
            try syncTree(at: candidate)
            try moveTree(candidate, to: final)
            try syncDirectory(at: final.deletingLastPathComponent())
        }
        try requireIdentity(final, identity)
        if !linkPoints(local, to: final), try !entryExists(markerURL(for: final)) {
            try installMarker(source: local, destination: final,
                type: DataDirType(rawValue: transfer.dataDirType) ?? .custom, baseline: baseline)
            try syncTree(at: final)
        }
    }

    /// Continue a copy that was already verified before a switch or ledger write
    /// failed. Reuse its operation ID; never create a second copy or reservation.
    func resumeVerifiedTransfer(operationID: UUID, progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
        guard var transfer = try store.transfer(operationID: operationID) else { return nil }
        if !ApplicationLaunchProtection.contains(transfer.bundleIdentifier, directory: launchProtectionDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: transfer.bundleIdentifier, directory: launchProtectionDirectory) {
                try await self.resumeVerifiedTransfer(operationID: operationID, progressHandler: progressHandler)
            }
        }
        guard try !DiskEjectionPauseStore(store: store).snapshot().blocks(transfer) else { throw DiskEjectionError.paused }
        DataTransferSession.progress?.setDirectory(URL(fileURLWithPath: transfer.originalPath))
        DataTransferSession.progress?.observeDirectoryWorkflow()
        guard transfer.needsAutomaticCompletion else { return nil }
        if transfer.isPreparationRecoverable {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "重试".localized, showsByteProgress: false, stage: .recovering))
            guard try store.transfer(operationID: operationID) == transfer else {
                throw DataOperationSafety.Failure.conflict(transfer.originalPath)
            }
            if let verified = try await promoteCompletePreparation(transfer) { transfer = verified }
            else { return try await restartPreparation(transfer, progressHandler: progressHandler) }
        }
        guard transfer.mode == .symlink,
              !runningMigrations.contains(operationID), !runningRestores.contains(operationID),
              completingPaths.insert(transfer.originalPath).inserted else {
            throw DataOperationSafety.Failure.occupied(transfer.originalPath)
        }
        defer { completingPaths.remove(transfer.originalPath) }
        if transfer.isVerifiedSwitchRecoverable || transfer.isDataSwitchComplete {
            DataTransferSession.progress?.observeResumedCopy(cleanup: transfer.isDataSwitchComplete)
        }
        if transfer.isDataSwitchComplete {
            return await completeSuccessfulTransfer(operationID: operationID, direction: transfer.direction,
                progressHandler: progressHandler, requireUnchangedActive: false).cleanupWarning
        }
        guard transfer.isVerifiedSwitchRecoverable, let encoded = transfer.baseline else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        if try store.transfers().contains(where: { $0.priorOperationID == operationID }) {
            return try await finishRestoredPredecessor(transfer, baseline: baseline, progressHandler: progressHandler)
        }
        let local = URL(fileURLWithPath: transfer.originalPath)
        let backup = URL(fileURLWithPath: transfer.backupPath!)
        var lastSaved = transfer
        do {
            try publishVerifiedPreparation(transfer, baseline: baseline)
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "重试".localized, showsByteProgress: false, stage: .recovering))
            let before = try verifiedSwitchState(transfer, baseline: baseline)
            if !before.alreadySwitched {
                try await safety.requireNoKnownWriters(at: before.source, bundleIdentifier: transfer.bundleIdentifier)
                try await safety.requireNoKnownWriters(at: before.destination, bundleIdentifier: transfer.bundleIdentifier)
            }
            guard try store.transfer(operationID: operationID) == transfer,
                  try verifiedSwitchState(transfer, baseline: baseline) == before else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            transfer.phase = .switching
            transfer.recoverableReason = nil
            if transfer.direction == .restore { try store.beginRestore(transfer: transfer, removingMount: nil) }
            else { try store.updateTransfer(transfer) }
            lastSaved = transfer
            guard try verifiedSwitchState(transfer, baseline: baseline) == before else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }

            DataTransferSession.progress?.observeEntrySwitch()
            if transfer.direction == .migrate, transfer.stagingPath == nil {
                if before.source == local {
                    try moveTree(local, to: backup)
                }
                try requireIdentity(backup, transfer.sourceIdentity)
                transfer.backupIdentity = try transfer.backupIdentity ?? DataPathIdentity.capture(backup)
                try store.updateTransfer(transfer)
                lastSaved = transfer
                _ = try verifiedSwitchState(transfer, baseline: baseline)
                if !isSymbolicLink(at: local) {
                    guard try !entryExists(local) else { throw DataDirError.destinationExists(local) }
                    try createSymbolicLink(at: local, withDestinationURL: before.destination)
                }
            } else {
                let staging = URL(fileURLWithPath: transfer.stagingPath!)
                if !before.alreadySwitched {
                    let replacement: URL
                    if transfer.direction == .restore {
                        replacement = staging.appendingPathComponent("data")
                    } else {
                        replacement = staging.appendingPathComponent("new-link")
                        if try !entryExists(replacement) {
                            try createSymbolicLink(at: replacement, withDestinationURL: before.destination)
                        }
                    }
                    try switchEntry(local: local, expectedLink: before.localLinkIdentity, replacement: replacement, staging: staging)
                }
                try finishRecoveredStaging(staging, source: backup, original: local)
            }
            if transfer.direction == .restore {
                transfer.activePath = local.path
            } else { transfer.activePath = transfer.destinationPath }
            let switched = try verifiedSwitchState(transfer, baseline: baseline)
            guard switched.alreadySwitched else { throw DataOperationSafety.Failure.inspection(local.path) }
            try syncTree(at: switched.destination)
            try syncDirectory(at: local.deletingLastPathComponent())
            if transfer.direction == .restore {
                try store.updateTransfer(transfer)
                lastSaved = transfer
                try store.finalizeTransfer(operationID: operationID, baseline: encoded)
            } else { try store.commitMigration(record: nil, transfer: transfer) }
            invalidateSizeCache(for: local)
            invalidateSizeCache(for: backup)
        } catch {
            guard try store.transfer(operationID: operationID) == lastSaved else { throw error }
            try recordFailure(&transfer, error: error)
        }
        return await completeSuccessfulTransfer(operationID: operationID, direction: transfer.direction,
            progressHandler: progressHandler, requireUnchangedActive: false).cleanupWarning
    }

    private func promoteCompletePreparation(_ expected: DataTransferRecord) async throws -> DataTransferRecord? {
        guard let encoded = expected.sourceBaseline, let identity = expected.destinationIdentity,
              expected.preparationRemovalBaseline == nil, let path = expected.preparationPath,
              let parent = expected.preparationParentIdentity else { return nil }
        let source = try preparationSource(expected, verifyContents: true)
        let candidate = URL(fileURLWithPath: path)
        guard try entryExists(candidate) else { return nil }
        try requireIdentity(candidate, identity)
        try requireIdentity(candidate.deletingLastPathComponent(), parent)
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        do { try TreeCopySession.verifyCopy(at: candidate, against: baseline) }
        catch { return nil }
        try await safety.requireNoKnownWriters(at: source, bundleIdentifier: expected.bundleIdentifier)
        _ = try preparationSource(expected, verifyContents: true)
        try TreeCopySession.verifyCopy(at: candidate, against: baseline)
        try syncTree(at: candidate)
        var verified = expected
        verified.baseline = encoded
        verified.phase = .verified
        verified.recoverableReason = nil
        try store.updateTransfer(verified)
        return verified
    }

    /// Older builds could restore a switched migration whose final record save
    /// had failed. The committed restore proves the current entry; completing
    /// its ancestor must never reinstall the old external link.
    private func finishRestoredPredecessor(_ expected: DataTransferRecord, baseline: TreeCopySnapshot,
                                           progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
        let history = try store.transfers()
        guard let group = DataTransferGroup.groups(from: history).first(where: { $0.resumeTransfer?.operationID == expected.operationID }),
              group.currentTransfer.direction == .restore, group.currentTransfer.isDataSwitchComplete,
              expected.direction == .migrate, let backupPath = expected.backupPath,
              let backupIdentity = expected.backupIdentity,
              let activeIdentity = group.currentTransfer.destinationIdentity else {
            throw DataOperationSafety.Failure.inspection(expected.originalPath)
        }
        let local = URL(fileURLWithPath: expected.originalPath)
        let backup = URL(fileURLWithPath: backupPath)
        func verify() throws {
            guard !isSymbolicLink(at: local), !DiskUtility.isMountPoint(local),
                  !isSymbolicLink(at: backup), !DiskUtility.isMountPoint(backup),
                  try store.managedLink(forOriginalPath: local.path) == nil else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            try requireIdentity(local, activeIdentity)
            try requireIdentity(backup, backupIdentity)
            try verifyRetainedTree(backup, identity: backupIdentity, baseline: baseline)
        }
        try verify()
        try await safety.requireNoKnownWriters(at: local, bundleIdentifier: expected.bundleIdentifier)
        try await safety.requireNoKnownWriters(at: backup, bundleIdentifier: expected.bundleIdentifier)
        guard try store.transfers() == history else { throw DataOperationSafety.Failure.conflict(local.path) }
        try verify()
        var completed = expected
        completed.phase = .awaitingUserVerification
        completed.recoverableReason = nil
        try store.updateTransfer(completed)
        return await completeSuccessfulTransfer(operationID: group.currentTransfer.operationID, direction: .restore,
            progressHandler: progressHandler, requireUnchangedActive: false).cleanupWarning
    }

    private struct VerifiedSwitchState: Equatable {
        let source: URL
        let destination: URL
        let alreadySwitched: Bool
        let localLinkIdentity: DataPathIdentity?
    }

    /// This performs no mutation and is repeated after every suspending check.
    private func verifiedSwitchState(_ transfer: DataTransferRecord, baseline: TreeCopySnapshot) throws -> VerifiedSwitchState {
        guard transfer.mode == .symlink, transfer.isVerifiedSwitchRecoverable,
              let destinationIdentity = transfer.destinationIdentity, let backupPath = transfer.backupPath else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let local = URL(fileURLWithPath: transfer.originalPath)
        let backup = URL(fileURLWithPath: backupPath)
        let destination = URL(fileURLWithPath: transfer.destinationPath)
        let type = DataDirType(rawValue: transfer.dataDirType) ?? .custom
        if transfer.direction == .restore { try requireLocalRestoreParent(local) }
        else { try safety.requireNoManagedFileSystemAncestor(at: local) }
        let history = try store.transfers()
        guard !history.contains(where: { $0.priorOperationID == transfer.operationID }) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        let owned = transferAncestors(of: transfer.operationID, transfers: history)
        guard history.filter({ owned.contains($0.operationID) && $0.operationID != transfer.operationID })
            .allSatisfy(\.isDataSwitchComplete) else { throw DataOperationSafety.Failure.conflict(local.path) }
        let indexed = try store.managedLink(forOriginalPath: local.path)
        if let indexed {
            guard indexed.operationID == transfer.priorOperationID,
                  indexed.destinationIdentity.matchesFilesystemObject(transfer.sourceIdentity),
                  indexed.destinationPath == backup.path else { throw DataOperationSafety.Failure.conflict(local.path) }
        }
        for path in Set([local.path, backup.path, destination.path] + [transfer.stagingPath].compactMap { $0 }) {
            try safety.requireNoOverlap(at: URL(fileURLWithPath: path), ownedTransferIDs: owned,
                ownedLinkPath: indexed?.originalPath, ownedRetainedPath: path)
        }
        let source: URL
        let copy: URL
        let switched: Bool
        let localLink = isSymbolicLink(at: local) ? try DataPathIdentity.capture(local) : nil
        if transfer.direction == .migrate, transfer.stagingPath == nil {
            let expectedBackup = local.deletingLastPathComponent()
                .appendingPathComponent(".appports-migration-backup-\(local.lastPathComponent)-\(transfer.operationID)")
            guard backup == expectedBackup, destination != local,
                  destination.lastPathComponent == local.lastPathComponent else { throw DataOperationSafety.Failure.conflict(local.path) }
            if try entryExists(backup) {
                source = backup
                guard try !entryExists(local) || localLink != nil && linkPoints(local, to: destination) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
            } else {
                source = local
                guard localLink == nil, !DiskUtility.isMountPoint(local) else { throw DataOperationSafety.Failure.conflict(local.path) }
            }
            switched = localLink != nil
            copy = destination
        } else {
            let prefix = transfer.direction == .restore ? ".appports-restore-" : ".appports-normalize-"
            let staging = local.deletingLastPathComponent().appendingPathComponent(prefix + transfer.operationID.uuidString)
            guard transfer.stagingPath == staging.path, backup != local,
                  transfer.backupIdentity?.matchesFilesystemObject(transfer.sourceIdentity) == true else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            source = backup
            if transfer.direction == .restore {
                guard destination == local else { throw DataOperationSafety.Failure.conflict(local.path) }
                switched = localLink == nil && (try? DataPathIdentity.capture(local))
                    .map(destinationIdentity.matchesFilesystemObject) == true
                copy = switched ? local : staging.appendingPathComponent("data")
            } else {
                guard destination != backup, destination != local else { throw DataOperationSafety.Failure.conflict(local.path) }
                switched = localLink != nil && linkPoints(local, to: destination)
                copy = destination
            }
            if !switched {
                guard try !entryExists(local) || localLink != nil && linkPoints(local, to: backup) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
            }
            if try entryExists(staging) {
                guard existingDirectory(at: staging), !isSymbolicLink(at: staging), !DiskUtility.isMountPoint(staging) else {
                    throw DataOperationSafety.Failure.conflict(staging.path)
                }
                let names = Set(try fileManager.contentsOfDirectory(atPath: staging.path))
                let replacementName = transfer.direction == .restore ? "data" : "new-link"
                guard names.isSubset(of: [replacementName, "previous-entry"]),
                      !switched || !names.contains(replacementName) else { throw DataOperationSafety.Failure.conflict(staging.path) }
                let previous = staging.appendingPathComponent("previous-entry")
                if names.contains("previous-entry") {
                    guard linkPoints(previous, to: backup, originallyAt: local), localLink == nil || switched else {
                        throw DataOperationSafety.Failure.conflict(previous.path)
                    }
                }
                if transfer.direction == .migrate, names.contains("new-link"), !linkPoints(staging.appendingPathComponent("new-link"), to: destination) {
                    throw DataOperationSafety.Failure.conflict(staging.path)
                }
            } else if !switched { throw DataOperationSafety.Failure.inspection(staging.path) }
        }
        guard !isSymbolicLink(at: copy),
              transfer.direction != .restore || !DiskUtility.isMountPoint(copy) else {
            throw DataOperationSafety.Failure.conflict(copy.path)
        }
        try requireIdentity(copy, destinationIdentity)
        if transfer.direction != .restore || !switched {
            guard !isSymbolicLink(at: source) else { throw DataOperationSafety.Failure.conflict(source.path) }
            try requireIdentity(source, transfer.sourceIdentity)
            if !switched {
                try requireMarker(at: source, for: local, type: type, allowOwned: transfer.stagingPath != nil)
                try verifyRetainedTree(source, identity: transfer.sourceIdentity, baseline: baseline)
            }
        }
        if transfer.direction == .migrate { try requireMarker(at: copy, for: local, type: type, allowOwned: true) }
        if !switched { try TreeCopySession.verifyCopy(at: copy, against: baseline) }
        return VerifiedSwitchState(source: source, destination: copy, alreadySwitched: switched, localLinkIdentity: localLink)
    }

    private func linkPoints(_ link: URL, to destination: URL, originallyAt original: URL? = nil) -> Bool {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target)
            : (original ?? link).deletingLastPathComponent().appendingPathComponent(target)
        return DataPathTopology.relationship(resolved.path, destination.path) == .same
    }

    private func finishRecoveredStaging(_ staging: URL, source: URL, original: URL) throws {
        guard try entryExists(staging) else { return }
        let names = try fileManager.contentsOfDirectory(atPath: staging.path)
        guard Set(names).isSubset(of: ["previous-entry"]) else { throw DataOperationSafety.Failure.conflict(staging.path) }
        if names.contains("previous-entry") {
            let previous = staging.appendingPathComponent("previous-entry")
            try store.recheckWriterAdmission()
            guard linkPoints(previous, to: source, originallyAt: original), unlink(previous.path) == 0 else { throw DataOperationSafety.Failure.conflict(previous.path) }
        }
        try store.recheckWriterAdmission()
        guard rmdir(staging.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func finishUnstartedRestoreIfNeeded(at local: URL) throws {
        let candidates = try store.transfers().filter { $0.originalPath == local.path && $0.isUnstartedSymlinkRestore }
        for expected in candidates {
            guard !runningRestores.contains(expected.operationID) else { throw DataOperationSafety.Failure.occupied(local.path) }
            try cancelUnstartedRestore(expected)
        }
    }

    private func removeUnstartedRestoreIntentIfSafe(_ transfer: DataTransferRecord) -> Bool {
        guard transfer.isUnstartedSymlinkRestore else { return false }
        do {
            guard let saved = try store.transfer(operationID: transfer.operationID), saved.isUnstartedSymlinkRestore else { return false }
            try cancelUnstartedRestore(saved)
            return true
        } catch { return false }
    }

    private func cancelUnstartedRestore(_ expected: DataTransferRecord) throws {
        let indexed = try store.managedLink(forOriginalPath: expected.originalPath)
        try store.cancelUnstartedSymlinkRestore(expected) {
            guard let backupPath = expected.backupPath, let stagingPath = expected.stagingPath else {
                throw DataOperationSafety.Failure.inspection(expected.originalPath)
            }
            let source = URL(fileURLWithPath: backupPath)
            let local = URL(fileURLWithPath: expected.originalPath)
            let staging = URL(fileURLWithPath: stagingPath)
            let parent = staging.deletingLastPathComponent()
            // The indexed source may legitimately be an external volume root.
            // Cancellation only removes our empty local staging directory.
            func requireUnswitchedSourceAndEntry() throws {
                guard !isSymbolicLink(at: source) else {
                    throw DataOperationSafety.Failure.conflict(source.path)
                }
                try requireIdentity(source, expected.sourceIdentity)
                if isSymbolicLink(at: local) {
                    guard DataPathTopology.relationship(local.path, source.path) == .same else {
                        throw DataOperationSafety.Failure.conflict(local.path)
                    }
                } else {
                    guard try !entryExists(local), let indexed,
                          indexed.operationID == expected.priorOperationID,
                          indexed.destinationPath == source.path,
                          indexed.destinationIdentity.matchesFilesystemObject(expected.sourceIdentity) else {
                        throw DataOperationSafety.Failure.conflict(local.path)
                    }
                }
            }
            try requireUnswitchedSourceAndEntry()
            guard let parentIdentity = expected.stagingParentIdentity else {
                // Legacy intents without a staging claim may end only while
                // the entry is absent; its name never authorizes removal.
                guard expected.stagingIdentity == nil, try !entryExists(staging) else {
                    throw DataOperationSafety.Failure.inspection(staging.path)
                }
                return
            }
            try requireIdentity(parent, parentIdentity)
            if try entryExists(staging) {
                guard let identity = expected.stagingIdentity else {
                    throw DataOperationSafety.Failure.inspection(staging.path)
                }
                guard existingDirectory(at: staging), !isSymbolicLink(at: staging), !DiskUtility.isMountPoint(staging) else {
                    throw DataOperationSafety.Failure.conflict(staging.path)
                }
                try requireIdentity(staging, identity)
                guard try fileManager.contentsOfDirectory(atPath: staging.path).isEmpty else {
                    throw DataOperationSafety.Failure.conflict(staging.path)
                }
                // rmdir is atomic and refuses any file arriving after inspection.
                try store.recheckWriterAdmission()
                try requireIdentity(parent, parentIdentity)
                try requireIdentity(staging, identity)
                guard rmdir(staging.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            // A cold retry after rmdir must finish this same parent barrier
            // before the store forgets the only cancellation intent.
            try requireIdentity(parent, parentIdentity)
            try syncDirectory(at: parent)
            try requireIdentity(parent, parentIdentity)
            guard try !entryExists(staging) else { throw DataOperationSafety.Failure.conflict(staging.path) }
            try requireUnswitchedSourceAndEntry()
        }
    }

    /// Explicit cleanup may follow normal application edits to the active data.
    /// Keep every predecessor until its own retained copy has been removed.
    func cleanupRetainedLineage(operationID: UUID) async throws {
        let lineage = try retainedLineage(endingAt: operationID)
        var firstFailure: Error?
        for transfer in lineage {
            try Task.checkCancellation()
            do {
                if transfer.mode == .symlink { try await cleanupRetainedTransfer(operationID: transfer.operationID) }
                else { try await retainedMountService().cleanupRetainedTransfer(operationID: transfer.operationID) }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private func completeSuccessfulTransfer(operationID: UUID, direction: DataTransferRecord.Direction,
                                             progressHandler: FileCopier.ProgressHandler?, requireUnchangedActive: Bool = false) async -> CompletionResult {
        do {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "正在清理旧副本...".localized, showsByteProgress: false, stage: .cleaning))
            let lineage = try retainedLineage(endingAt: operationID)
            try await verifyAutomaticCleanup(lineage, requireUnchangedActive: requireUnchangedActive)
            try await cleanupRetainedLineage(operationID: operationID)
            return CompletionResult(cleanupWarning: nil)
        } catch {
            // This runs after commit/finalize. Never turn successful migration
            // into recovery just because an old copy could not be removed.
            let message = direction == .restore
                ? "数据已还原到本地，但旧副本尚未全部清理。%@".localized
                : "迁移已完成，但旧副本尚未全部清理。%@".localized
            return CompletionResult(cleanupWarning: String(format: message, "\n" + error.localizedDescription))
        }
    }

    private func completePreviousRestoreIfNeeded(item: DataDirItem, externalBaseURL: URL,
                                                progressHandler: FileCopier.ProgressHandler?) async throws {
        let local = item.path.standardizedFileURL
        guard !isSymbolicLink(at: local) else { return }
        let lineage = try completedRestoreLineage(at: local)
        guard let terminal = lineage.last else { return }

        // Reclaim the same recorded destination when it is available. A failed
        // old-copy cleanup is not a prerequisite for moving the current local
        // data elsewhere; the next intent keeps this exact identity lineage.
        let destination = externalBaseURL.appendingPathComponent(local.lastPathComponent).standardizedFileURL
        if try entryExists(destination) {
            guard let retained = lineage.first(where: { $0.retainedCopyRemovedAt == nil && $0.backupPath == destination.path }) else {
                throw DataDirError.destinationExists(destination)
            }
            guard let identity = retained.backupIdentity,
                  try DataPathIdentity.capture(destination).matchesFilesystemObject(identity) else {
                throw CompletionError.previousRestoreNeedsCleanup(DataOperationSafety.Failure.conflict(destination.path).localizedDescription)
            }
        }
        do {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "正在清理旧副本...".localized, showsByteProgress: false, stage: .cleaning))
            try requirePolicy(local)
            guard !DiskUtility.isMountPoint(local) else { throw DataOperationSafety.Failure.conflict(local.path) }
            _ = try preflightWritePermission(at: externalBaseURL)
            try await verifyAutomaticCleanup(lineage, requireUnchangedActive: false)
            try await cleanupRetainedLineage(operationID: terminal.operationID)
        } catch {
            try Task.checkCancellation()
            // A still-occupied or reserved destination is rejected by the new
            // migration's ordinary checks. No failed cleanup is called deleted.
            if try entryExists(destination) {
                throw CompletionError.previousRestoreNeedsCleanup(error.localizedDescription)
            }
        }
    }

    /// A completed restore may remain solely to identify its old external copy.
    /// Its current local object, not path equality or an old content snapshot,
    /// authorizes a later migration after legitimate local application writes.
    private func completedRestoreLineage(at local: URL) throws -> [DataTransferRecord] {
        let transfers = try store.transfers()
        let related = transfers.filter { $0.originalPath == local.path && $0.rollbackCompletedAt == nil }
        let terminalRestores = related.filter { transfer in
            transfer.direction == .restore
                && [.awaitingUserVerification, .cleanupRequested].contains(transfer.phase)
                && !transfers.contains(where: { $0.priorOperationID == transfer.operationID && $0.rollbackCompletedAt == nil })
        }
        guard !terminalRestores.isEmpty else { return [] }
        guard terminalRestores.count == 1, let terminal = terminalRestores.first else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        let lineage = try retainedLineage(endingAt: terminal.operationID)
        guard Set(lineage.map(\.operationID)) == Set(related.map(\.operationID)) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        guard terminal.activePath == local.path, terminal.destinationPath == local.path,
              !isSymbolicLink(at: local), !DiskUtility.isMountPoint(local),
              try store.managedLink(forOriginalPath: local.path) == nil,
              let identity = terminal.destinationIdentity else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        try requireIdentity(local, identity)
        return lineage
    }

    /// Oldest first, following durable identities instead of timestamps or path
    /// names. A missing predecessor was already cleaned and ends the chain.
    private func retainedLineage(endingAt operationID: UUID) throws -> [DataTransferRecord] {
        let transfers = try store.transfers()
        guard var current = transfers.first(where: { $0.operationID == operationID }) else { return [] }
        let originalPath = current.originalPath
        var visited: Set<UUID> = []
        var lineage: [DataTransferRecord] = []
        while true {
            guard visited.insert(current.operationID).inserted,
                  current.originalPath == originalPath,
                  [.awaitingUserVerification, .cleanupRequested].contains(current.phase),
                  current.baseline != nil || current.retainedCopyRemovedAt != nil, current.destinationIdentity != nil,
                  current.backupPath != nil, current.backupIdentity != nil else {
                throw DataOperationSafety.Failure.inspection(originalPath)
            }
            lineage.append(current)
            guard let priorID = current.priorOperationID,
                  let prior = transfers.first(where: { $0.operationID == priorID }) else { break }
            guard current.followsLocation(of: prior) else {
                throw DataOperationSafety.Failure.conflict(originalPath)
            }
            current = prior
        }
        return Array(lineage.reversed())
    }

    /// Newly switched data is checked against the just-copied content. An older
    /// completed restore can have ordinary edits while retaining its identity.
    private func verifyAutomaticCleanup(_ lineage: [DataTransferRecord], requireUnchangedActive: Bool = true) async throws {
        guard lineage.contains(where: { $0.needsAutomaticCompletion && $0.retainedCopyRemovedAt == nil }),
              let terminal = lineage.last else { return }
        guard !(try store.transfers()).contains(where: { $0.priorOperationID == terminal.operationID }),
              let activeIdentity = terminal.destinationIdentity else {
            throw DataOperationSafety.Failure.conflict(terminal.originalPath)
        }
        let active = URL(fileURLWithPath: terminal.activePath)
        let local = URL(fileURLWithPath: terminal.originalPath)
        if terminal.direction == .restore {
            guard terminal.activePath == terminal.originalPath, terminal.destinationPath == terminal.originalPath,
                  !isSymbolicLink(at: local), try store.managedLink(forOriginalPath: terminal.originalPath) == nil else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        } else {
            guard let link = try store.managedLink(forOriginalPath: terminal.originalPath),
                  link.operationID == terminal.operationID, link.destinationPath == terminal.destinationPath,
                  terminal.activePath == terminal.destinationPath,
                  link.destinationIdentity.matchesFilesystemObject(activeIdentity),
                  isSymbolicLink(at: local),
                  DataPathTopology.relationship(local.path, active.path) == .same else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        }
        try requireIdentity(active, activeIdentity)
        try await safety.requireNoKnownWriters(at: active, bundleIdentifier: terminal.bundleIdentifier)
        try requireIdentity(active, activeIdentity)
        if requireUnchangedActive {
            guard let encoded = terminal.baseline else { throw DataOperationSafety.Failure.inspection(active.path) }
            let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
            try TreeCopySession.verifyCopy(at: active, against: baseline, purpose: .activeData)
        }
        // Each retained copy is checked immediately before its own deletion.
        // An older offline copy must not keep a newly verified local copy alive.
        try requireIdentity(active, activeIdentity)
    }

    private struct CleanupContext {
        let activeURL: URL
        let identity: DataPathIdentity
        let lineage: Set<UUID>
        let activeLinkPath: String?
    }

    private func retainedMountService() -> ContainerVolumeMigrator {
        mountMigrator ?? ContainerVolumeMigrator(store: store, homeDirectory: homeDir, safetyRunner: safety.runner)
    }

    private func cleanupContext(for transfer: DataTransferRecord) async throws -> CleanupContext {
        let current = try store.completedLocation(after: transfer.operationID)
        if current.mode == .mount, current.direction == .migrate {
            _ = try await retainedMountService().requireActiveData(for: current)
        }
        return try cleanupLocation(for: transfer)
    }

    /// Synchronous recheck for the deletion checkpoint; asynchronous volume
    /// inspection belongs to cleanupContext before the final content scan.
    private func cleanupLocation(for transfer: DataTransferRecord) throws -> CleanupContext {
        let transfers = try store.transfers()
        let descendants = transferDescendants(of: transfer.operationID, transfers: transfers)
        let lineage = descendants.reduce(into: Set<UUID>()) { $0.formUnion(transferAncestors(of: $1, transfers: transfers)) }
        let current = try store.completedLocation(after: transfer.operationID)
        let active = URL(fileURLWithPath: current.activePath)
        guard let identity = current.destinationIdentity else {
            throw DataOperationSafety.Failure.inspection(active.path)
        }
        let local = URL(fileURLWithPath: transfer.originalPath)
        var activeLinkPath: String?
        if current.mode == .mount, current.direction == .migrate {
            guard !isSymbolicLink(at: active), DiskUtility.isMountPoint(active),
                  let uuid = current.createdVolumeUUID,
                  DiskUtility.mountedVolumeUUID(at: active)?.caseInsensitiveCompare(uuid) == .orderedSame,
                  try DataPathIdentity.capture(active, volumeUUID: uuid).matchesFilesystemObject(identity) else {
                throw DataOperationSafety.Failure.conflict(active.path)
            }
        } else if current.direction == .migrate {
            guard let activeLink = try store.managedLink(forOriginalPath: current.originalPath),
                  activeLink.operationID == current.operationID, activeLink.destinationPath == active.path,
                  activeLink.destinationIdentity.matchesFilesystemObject(identity) else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            activeLinkPath = activeLink.originalPath
            if isSymbolicLink(at: local) {
                guard DataPathTopology.relationship(local.path, active.path) == .same else { throw DataOperationSafety.Failure.conflict(local.path) }
            } else if try entryExists(local) { throw DataOperationSafety.Failure.conflict(local.path) }
            try requireIdentity(active, identity)
        } else {
            guard !isSymbolicLink(at: local), !DiskUtility.isMountPoint(local), active.path == local.path else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            try requireIdentity(active, identity)
        }
        return CleanupContext(activeURL: active, identity: identity, lineage: lineage, activeLinkPath: activeLinkPath)
    }

    /// The only operation that removes an original. Cleanup is an idempotent
    /// continuation of a successful switch, including after process termination.
    func cleanupRetainedTransfer(operationID: UUID) async throws {
        guard let transfer = try store.transfer(operationID: operationID),
              transfer.needsAutomaticCompletion, !CleanupRetryContext.shouldDefer(transfer) else { return }
        if !ApplicationLaunchProtection.contains(transfer.bundleIdentifier, directory: launchProtectionDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: transfer.bundleIdentifier, directory: launchProtectionDirectory) {
                try await self.cleanupRetainedTransfer(operationID: operationID)
            }
        }
        do {
            try await performRetainedTransferCleanup(operationID: operationID)
            CleanupRetryContext.record(.transfer(operationID), failed: false, store: store)
        } catch {
            if !(error is CancellationError) {
                CleanupRetryContext.record(.transfer(operationID), failed: true, store: store)
            }
            throw error
        }
    }

    private func performRetainedTransferCleanup(operationID: UUID) async throws {
        guard runningCleanups.insert(operationID).inserted else { throw DataOperationSafety.Failure.occupied(operationID.uuidString) }
        defer { runningCleanups.remove(operationID) }
        guard var transfer = try store.transfer(operationID: operationID) else { return }
        DataTransferSession.progress?.setDirectory(URL(fileURLWithPath: transfer.originalPath))
        guard transfer.needsAutomaticCompletion else { return }
        if transfer.retainedCopyRemovedAt != nil {
            try store.finishTransfer(operationID: operationID, deletionConfirmed: true)
            return
        }
        guard transfer.mode == .symlink, transfer.isDataSwitchComplete,
              let encoded = transfer.baseline, let retainedPath = transfer.backupPath,
              let retainedIdentity = transfer.backupIdentity else { throw DataOperationSafety.Failure.inspection(operationID.uuidString) }
        DataTransferSession.progress?.observeResumedCopy(cleanup: true)
        let retained = URL(fileURLWithPath: retainedPath)
        let parent = retained.deletingLastPathComponent().resolvingSymlinksInPath()
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        let deletionPreviouslyStarted = transfer.cleanupParentIdentity != nil
        var requestedCleanup = false
        do {
            let context = try await cleanupContext(for: transfer)
            guard !DiskUtility.isMountPoint(retained) else { throw DataOperationSafety.Failure.conflict(retained.path) }
            if let expectedParent = transfer.cleanupParentIdentity { try requireIdentity(parent, expectedParent) }
            if let actual = try TreeCopySession.retainedRemovalURL(at: retained, removalID: operationID) {
                try requireIdentity(actual, retainedIdentity)
            }
            try safety.requireNoOverlap(at: retained, ownedTransferIDs: context.lineage,
                ownedLinkPath: context.activeLinkPath, ownedRetainedPath: retained.path)
            if let actual = try TreeCopySession.retainedRemovalURL(at: retained, removalID: operationID) {
                try await safety.requireNoKnownWriters(at: actual, bundleIdentifier: transfer.bundleIdentifier)
            }
            try await safety.requireNoKnownWriters(at: context.activeURL, bundleIdentifier: transfer.bundleIdentifier)
            // Process inspection suspends this actor. Revalidate the current
            // entry and lineage after those awaits, before any removal begins.
            let fresh = try await cleanupContext(for: transfer)
            guard fresh.activeURL == context.activeURL, fresh.identity == context.identity,
                  fresh.lineage == context.lineage, try store.transfer(operationID: operationID) == transfer else {
                throw DataOperationSafety.Failure.conflict(context.activeURL.path)
            }
            try syncTree(at: context.activeURL)
            try syncDirectory(at: URL(fileURLWithPath: transfer.originalPath).deletingLastPathComponent())
            if let actual = try TreeCopySession.retainedRemovalURL(at: retained, removalID: operationID) {
                let parentIdentity = try DataPathIdentity.capture(parent)
                try requireIdentity(actual, retainedIdentity)
                let type = DataDirType(rawValue: transfer.dataDirType) ?? .custom
                try requireIdentity(context.activeURL, context.identity)
                try store.recheckWriterAdmission()
                try TreeCopySession.removeVerifiedCopy(at: retained, against: baseline, allowPartialRemoval: deletionPreviouslyStarted,
                    expectedVolumeUUID: retainedIdentity.volumeUUID, removalID: operationID, requireSourceIdentity: true,
                    prepareForRemoval: {
                        try self.requireIdentity(actual, retainedIdentity)
                        if try self.entryExists(self.markerURL(for: retained)) {
                            try self.requireMarker(at: retained, for: URL(fileURLWithPath: transfer.originalPath), type: type, allowOwned: true)
                            try self.removeManagedLinkMetadata(in: retained)
                            if actual.path == retained.path { try TreeCopySession.applyRootMetadata(at: retained, from: baseline) }
                        }
                    }, willRemove: {
                        guard try self.store.transfer(operationID: operationID) == transfer else {
                            throw DataOperationSafety.Failure.conflict(retained.path)
                        }
                        try self.requireIdentity(parent, parentIdentity)
                        try self.requireIdentity(actual, retainedIdentity)
                        try self.store.requestCleanup(operationID: operationID)
                        transfer.phase = .cleanupRequested
                        transfer.recoverableReason = nil
                        requestedCleanup = true
                        try self.store.beginCleanupDeletion(operationID: operationID, parentIdentity: parentIdentity)
                        transfer.cleanupParentIdentity = transfer.cleanupParentIdentity ?? parentIdentity
                        // No suspension between the verified scan and deletion.
                        let fresh = try self.cleanupLocation(for: transfer)
                        guard fresh.activeURL == context.activeURL, fresh.identity == context.identity,
                              fresh.lineage == context.lineage else {
                            throw DataOperationSafety.Failure.conflict(context.activeURL.path)
                        }
                        try self.requireIdentity(parent, parentIdentity)
                        try self.requireIdentity(actual, retainedIdentity)
                    })
            } else {
                guard let expectedParent = transfer.cleanupParentIdentity else { throw DataOperationSafety.Failure.inspection(retained.path) }
                try requireIdentity(parent, expectedParent)
            }
            guard try TreeCopySession.retainedRemovalURL(at: retained, removalID: operationID) == nil else {
                throw DataOperationSafety.Failure.inspection(retained.path)
            }
            try syncDirectory(at: parent)
            try store.finishTransfer(operationID: operationID, deletionConfirmed: true)
            invalidateSizeCache(for: retained)
        } catch {
            // The switch is still complete. The immutable manifest and cleanup
            // checkpoint make another attempt safe without blocking local data.
            if requestedCleanup {
                transfer.recoverableReason = error.localizedDescription
                do { try store.updateTransfer(transfer) }
                catch { AppLogger.shared.logError("无法更新副本清理恢复记录，原事务仍保留", error: error) }
            }
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

    private func copy(from source: URL, to destination: URL, final: URL, operationID: UUID? = nil,
                      verifyDestinationAfterCopy: Bool = true,
                      progress: FileCopier.ProgressHandler?) async throws -> TreeCopySnapshot {
        let store = self.store
        do { return try await TreeCopySession().copy(from: source, to: destination,
            excludingRootEntries: [managedLinkMarkerFileName], finalDestination: final,
            verifySourceAfterCopy: false,
            verifyDestinationAfterCopy: verifyDestinationAfterCopy,
            preparedHandler: { baseline in
                if let operationID {
                    try store.prepareCopy(operationID: operationID, path: destination,
                        parentIdentity: DataPathIdentity.capture(destination.deletingLastPathComponent()), baseline: baseline)
                }
            }, destinationCreatedHandler: { identity in
                if let operationID { try store.claimCopyDestination(operationID: operationID, identity: identity) }
            }, progressHandler: progress) }
        catch { throw DataDirError.copyFailed(error) }
    }

    private func installMarker(source: URL, destination: URL, type: DataDirType, baseline: TreeCopySnapshot,
                               ownershipRole: TreeCopySession.OwnershipRole = .destination) throws {
        try requireMarker(at: destination, for: source, type: type, allowOwned: true)
        do {
            try writeManagedLinkMetadata(sourcePath: source, destinationPath: destination, type: type)
            // 只改动根目录属性；applyRootMetadata 已逐项核对根目录，
            // 标记文件不改变子文件内容，无需因此再读取整棵目录。
            try TreeCopySession.applyRootMetadata(at: destination, from: baseline, ownershipRole: ownershipRole)
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
        if let latest = try store.transfer(operationID: transfer.operationID) { transfer = latest }
        if transfer.isDataSwitchComplete { throw error }
        transfer.phase = .needsRecovery
        transfer.recoverableReason = error.localizedDescription
        // If this write fails, the previous durable phase still reserves all known copies.
        try store.updateTransfer(transfer)
        throw error
    }

    private func removeUnstartedIntentIfSafe(_ transfer: DataTransferRecord) -> Bool {
        guard transfer.isUnstartedSymlinkMigration else { return false }
        do {
            guard let latest = try store.transfer(operationID: transfer.operationID), latest.isUnstartedSymlinkMigration else { return false }
            try store.cancelUnstartedMigration(latest) {
                try requireUnstartedMigrationFilesystem(latest)
            }
            return true
        } catch { return false }
    }

    private func requireUnstartedMigrationFilesystem(_ transfer: DataTransferRecord) throws {
        guard transfer.isUnstartedSymlinkMigration, let backupPath = transfer.backupPath else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let source = URL(fileURLWithPath: transfer.originalPath)
        let destination = URL(fileURLWithPath: transfer.destinationPath)
        let backup = URL(fileURLWithPath: backupPath)
        if let preparation = transfer.preparationPath,
           try entryExists(URL(fileURLWithPath: preparation)) {
            throw DataOperationSafety.Failure.inspection(preparation)
        }
        let original = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard original >= 0 else { throw DataOperationSafety.Failure.inspection(source.path) }
        defer { close(original) }
        var originalInfo = stat()
        guard fstat(original, &originalInfo) == 0 else { throw DataOperationSafety.Failure.inspection(source.path) }
        let currentSourceIdentity = try DataPathIdentity.capture(source)
        guard [S_IFDIR, S_IFREG].contains(originalInfo.st_mode & S_IFMT),
              transfer.sourceIdentity.matchesFilesystemObject(currentSourceIdentity),
              currentSourceIdentity.device == UInt64(UInt32(bitPattern: originalInfo.st_dev)),
              currentSourceIdentity.inode == UInt64(originalInfo.st_ino) else {
            throw DataOperationSafety.Failure.conflict(source.path)
        }

        // An absent child alone proves nothing about an offline or inaccessible
        // external volume. Open its existing parent before interpreting ENOENT.
        let parent = destination.deletingLastPathComponent()
        let targetParent = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard targetParent >= 0 else { throw DataOperationSafety.Failure.inspection(parent.path) }
        defer { close(targetParent) }
        var parentInfo = stat()
        guard fstat(targetParent, &parentInfo) == 0 else { throw DataOperationSafety.Failure.inspection(parent.path) }
        if let expectedVolume = transfer.destinationVolumeUUID {
            try requireDestinationVolume(at: parent, expected: expectedVolume)
        } else {
            // Historical intents did not record their target volume. Only an
            // independently identified live volume can distinguish that case
            // from an unmounted disk's empty directory on the source filesystem.
            guard let sourceVolume = currentSourceIdentity.volumeUUID,
                  let destinationVolume = try volumeUUID(at: parent),
                  !sourceVolume.isEmpty, !destinationVolume.isEmpty,
                  sourceVolume.caseInsensitiveCompare(destinationVolume) != .orderedSame else {
                throw DataOperationSafety.Failure.inspection(parent.path)
            }
        }
        var targetInfo = stat()
        if fstatat(targetParent, destination.lastPathComponent, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            throw DataOperationSafety.Failure.conflict(destination.path)
        }
        guard errno == ENOENT else { throw DataOperationSafety.Failure.inspection(destination.path) }
        guard try !entryExists(backup) else { throw DataOperationSafety.Failure.conflict(backup.path) }
        // A sidecar can outlive its data entry after external changes. Preserve
        // the record if any marker remains rather than treating it as untouched.
        let sidecar = parent.appendingPathComponent(".\(destination.lastPathComponent)\(managedLinkMetadataSidecarSuffix)")
        guard try !entryExists(sidecar) else { throw DataOperationSafety.Failure.conflict(sidecar.path) }
        guard try !entryExists(markerURL(for: source)) else {
            throw DataOperationSafety.Failure.conflict(source.path)
        }
        var currentParent = stat()
        guard stat(parent.path, &currentParent) == 0,
              currentParent.st_dev == parentInfo.st_dev, currentParent.st_ino == parentInfo.st_ino else {
            throw DataOperationSafety.Failure.inspection(parent.path)
        }
        try requireIdentity(source, transfer.sourceIdentity)
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

    private func removeEntry(at url: URL) throws {
        try store.recheckWriterAdmission()
        try fileManager.removeItem(at: url)
        try syncDirectory(at: url.deletingLastPathComponent())
    }

    private func syncDirectory(at directory: URL) throws {
        try synchronizeDirectory(directory, directory.standardizedFileURL.path == homeDir.path)
    }

    private func syncTree(at root: URL) throws {
        try DurableFileIO.syncTree(at: root,
            allowParentAlias: root.deletingLastPathComponent().standardizedFileURL.path == homeDir.path)
    }

    private func renameWithoutReplacing(_ source: URL, _ destination: URL) throws {
        try store.recheckWriterAdmission()
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func moveTree(_ source: URL, to destination: URL) throws {
        try store.recheckWriterAdmission()
        try DataTreeRelocator.move(source, to: destination)
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
            else { try moveTree(replacement, to: local) }
            try syncDirectory(at: local.deletingLastPathComponent())
            try syncDirectory(at: staging)
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
            try removeEntry(at: oldEntry)
        }
        if try fileManager.contentsOfDirectory(atPath: staging.path).isEmpty { try removeEntry(at: staging) }
        try syncDirectory(at: local.deletingLastPathComponent())
    }

    private func verifyRetainedTree(_ root: URL, identity: DataPathIdentity, baseline: TreeCopySnapshot) throws {
        if let volumeUUID = identity.volumeUUID {
            try TreeCopySession.verifyUnchanged(at: root, against: baseline, expectedVolumeUUID: volumeUUID, purpose: .retainedCopy)
        } else {
            try TreeCopySession.verifyUnchanged(at: root, against: baseline, purpose: .retainedCopy)
        }
    }

    private func requireLocalRestoreParent(_ local: URL) throws {
        try safety.requireLocalRestoreParent(at: local)
    }

    private func checkWritePermission(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
        guard fileManager.isWritableFile(atPath: url.path) else { throw DataDirError.permissionDenied(url) }
    }

    /// Inspect the nearest existing directory without creating missing parents.
    private func preflightWritePermission(at url: URL) throws -> String? {
        var ancestor = url.standardizedFileURL
        while try !entryExists(ancestor), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        guard existingDirectory(at: ancestor), fileManager.isWritableFile(atPath: ancestor.path),
              fileManager.isExecutableFile(atPath: ancestor.path) else { throw DataDirError.permissionDenied(ancestor) }
        return try volumeUUID(at: ancestor)
    }

    private func volumeUUID(at url: URL) throws -> String? {
        var actual = url.resolvingSymlinksInPath()
        actual.removeAllCachedResourceValues()
        return try actual.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    private func requireDestinationVolume(at url: URL, expected: String) throws {
        guard let actual = try volumeUUID(at: url), !actual.isEmpty,
              expected.caseInsensitiveCompare(actual) == .orderedSame else {
            throw DataOperationSafety.Failure.inspection(url.path)
        }
    }

    private func createSymbolicLink(at localPath: URL, withDestinationURL externalPath: URL) throws {
        try store.recheckWriterAdmission()
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
            try DurableFileIO.write(data, to: markerURL)
        }
    }

    private func removeManagedLinkMetadata(in directoryURL: URL) throws {
        let markerURL = markerURL(for: directoryURL)
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        try withWritableMetadataParent(for: markerURL) {
            try removeEntry(at: markerURL)
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
