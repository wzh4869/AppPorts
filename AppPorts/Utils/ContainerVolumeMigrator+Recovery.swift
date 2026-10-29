import Darwin
import Foundation
import CoreData

extension ContainerVolumeMigrator {
    struct RecoveryPaused: LocalizedError {
        var errorDescription: String? {
            "此操作已暂停，现有文件已保留。请在“处理异常”中点击“重试”后继续。".localized
        }
    }

    enum AutomaticRecoveryError: LocalizedError, CustomNSError {
        case restored(operation: Error, retainedDetails: String?)
        case incomplete(operation: Error, recovery: Error)
        case timedOut

        static var errorDomain: String { "AppPorts.AutomaticRecovery" }
        var errorCode: Int {
            switch self {
            case .restored: return 1
            case .incomplete: return 2
            case .timedOut: return 3
            }
        }
        var errorUserInfo: [String: Any] {
            var result: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? ""]
            switch self {
            case .restored(let operation, _):
                result[NSUnderlyingErrorKey] = operation as NSError
            case .incomplete(let operation, let recovery):
                result[NSUnderlyingErrorKey] = operation as NSError
                result[NSDetailedErrorsKey] = [recovery as NSError]
            case .timedOut: break
            }
            return result
        }

        var errorDescription: String? {
            switch self {
            case .restored(let operation, let details):
                return ["本次操作未完成，已撤回本次变更，原数据已保留，可以直接重试。".localized,
                        operation.localizedDescription, details].compactMap { $0 }.joined(separator: "\n\n")
            case .incomplete(let operation, let recovery):
                return ["本次操作未完成，数据已保留。AppPorts 会在条件恢复后继续处理，也可以重试。".localized,
                        operation.localizedDescription, recovery.localizedDescription].joined(separator: "\n\n")
            case .timedOut:
                return "自动恢复暂未完成，已保留恢复记录；再次操作时会继续检查实际数据位置。".localized
            }
        }
    }

    enum AutomaticRecoveryResult: Sendable {
        case completed
        case rolledBack(retainedDetails: String?)
    }

    func pendingMountTransfer(at path: String, direction: DataTransferRecord.Direction) throws -> DataTransferRecord? {
        let pending = try store.transfers().filter {
            $0.mode == .mount && $0.direction == direction && $0.originalPath == path
                && !$0.isDataSwitchComplete && $0.rollbackCompletedAt == nil
        }
        guard pending.count <= 1 else { throw DataOperationSafety.Failure.conflict(path) }
        return pending.first
    }

    /// Called while the outer operation still owns its process-wide lock. A
    /// cancellation stops copying, but must not cancel the work that restores
    /// an application entry. Disk commands have individual recovery deadlines.
    func recoverWithIndependentBudget(_ transfer: DataTransferRecord,
                                      finishPreparedRestore: Bool = true,
                                      timeoutNanoseconds: UInt64 = 0) async throws -> AutomaticRecoveryResult {
        let launchDirectory = store.fileURLForDeletionAuthorization.deletingLastPathComponent().appendingPathComponent("launch-locks", isDirectory: true)
        if !ApplicationLaunchProtection.contains(transfer.bundleIdentifier, directory: launchDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: transfer.bundleIdentifier, directory: launchDirectory) {
                try await self.recoverWithIndependentBudget(transfer, finishPreparedRestore: finishPreparedRestore, timeoutNanoseconds: timeoutNanoseconds)
            }
        }
        guard transfer.needsAutomaticCompletion else { throw RecoveryPaused() }
        let transfer = try store.adoptLegacyRestoreOwnership(transfer)
        let progress = DataTransferSession.progress
        let session = DataTransferSession.current
        let automatic = CleanupRetryContext.automatic
        let retryClock = CleanupRetryContext.now
        // Disk commands have their own deadlines. A dataset-sized verification
        // must not restart forever because it exceeds a fixed 10/90s budget.
        if timeoutNanoseconds == 0 {
            return try await ApplicationLaunchProtection.detached(priority: .userInitiated) {
                try await DataTransferSession.$current.withValue(session) {
                    try await DataTransferSession.$progress.withValue(progress) {
                        try await DataTransferSession.run {
                            progress?.begin(.recovering)
                            return try await CleanupRetryContext.$automatic.withValue(automatic) {
                                try await CleanupRetryContext.$now.withValue(retryClock) {
                                    try await self.recoverMountOperation(transfer, finishPreparedRestore: finishPreparedRestore)
                                }
                            }
                        }
                    }
                }
            }
        }
        return try await ApplicationLaunchProtection.detached(priority: .userInitiated) {
            try await DataTransferSession.$current.withValue(session) {
                try await DataTransferSession.$progress.withValue(progress) {
                    progress?.begin(.recovering)
                    return try await withThrowingTaskGroup(of: AutomaticRecoveryResult.self) { group in
                        group.addTask {
                            try await CleanupRetryContext.$automatic.withValue(automatic) {
                                try await CleanupRetryContext.$now.withValue(retryClock) {
                                    try await self.recoverMountOperation(transfer, finishPreparedRestore: finishPreparedRestore)
                                }
                            }
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: timeoutNanoseconds)
                            throw AutomaticRecoveryError.timedOut
                        }
                        defer { group.cancelAll() }
                        return try await group.next()!
                    }
                }
            }
        }
    }

    func recoverFailedMountOperation(at path: String, direction: DataTransferRecord.Direction,
                                     operation error: Error) async throws -> DataTransferRecord {
        guard let transfer = try pendingMountTransfer(at: path, direction: direction) else { throw error }
        let result: AutomaticRecoveryResult
        do {
            result = try await recoverWithIndependentBudget(transfer,
                finishPreparedRestore: !Self.operationWasCancelled(error))
        } catch let recovery {
            throw AutomaticRecoveryError.incomplete(operation: error, recovery: recovery)
        }
        switch result {
        case .completed:
            guard let completed = try store.transfer(operationID: transfer.operationID), completed.isDataSwitchComplete else {
                throw AutomaticRecoveryError.incomplete(operation: error,
                    recovery: DataOperationSafety.Failure.inspection(path))
            }
            return completed
        case .rolledBack(let details):
            throw AutomaticRecoveryError.restored(operation: error, retainedDetails: details)
        }
    }

    static func operationWasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case MigrationError.ownershipRollbackFailed(_, let operation, _) = error {
            return operationWasCancelled(operation)
        }
        if case MigrationError.copyFailed(let operation) = error { return operationWasCancelled(operation) }
        if case DiskUtility.Failure.administratorPromptCancelled = error { return true }
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError
    }

    private func requireRecoveryJournal(_ expected: DataTransferRecord) throws {
        try Task.checkCancellation()
        guard expected.needsAutomaticCompletion else { throw RecoveryPaused() }
        guard try store.transfer(operationID: expected.operationID) == expected,
              !(try store.transfers()).contains(where: { $0.priorOperationID == expected.operationID }) else {
            throw RecoveryJournalChanged(operation: DataOperationSafety.Failure.conflict(expected.originalPath))
        }
    }

    private func finishVerifiedRecovery(_ transfer: DataTransferRecord) async throws {
        guard transfer.isVerifiedSwitchRecoverable, let encoded = transfer.baseline else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        var state = VerifiedMountResume(transfer: transfer, transfers: try store.transfers(),
            mounts: try store.recordsStrict(), links: try store.managedLinks(), cleanups: try store.pendingCleanups())
        try requireVerifiedResumeLedger(state)
        try requireVerifiedResumeTopology(state)
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        do {
            if transfer.direction == .migrate { try await resumeVerifiedMountMigration(&state, baseline: baseline) }
            else { try await resumeVerifiedMountRestore(&state, baseline: baseline) }
        } catch {
            do { try requireVerifiedResumeLedger(state) }
            catch { throw RecoveryJournalChanged(operation: error) }
            throw error
        }
        synchronizeAgent(store)
    }

    private func recoverMountOperation(_ expected: DataTransferRecord,
                                       finishPreparedRestore: Bool) async throws -> AutomaticRecoveryResult {
        try requireRecoveryJournal(expected)
        DataTransferSession.progress?.setDirectory(URL(fileURLWithPath: expected.originalPath))
        if expected.isDataSwitchComplete { return .completed }
        if expected.rollbackCompletedAt != nil {
            return try await cleanupRolledBackOperation(expected)
        }
        let local = URL(fileURLWithPath: expected.originalPath)
        if expected.direction == .migrate, isMountPoint(local) {
            // A live destination can contain newer data. Never replace it with
            // the old local backup merely because the final journal write failed.
            try await finishVerifiedRecovery(expected)
            return .completed
        }
        if expected.direction == .migrate, expected.isVerifiedSwitchRecoverable, expected.backupIdentity != nil {
            do {
                try await finishVerifiedRecovery(expected)
                return .completed
            } catch {
                try Task.checkCancellation()
                guard !RecoveryJournalChanged.isContained(in: error), !isMountPoint(local) else { throw error }
                // The final mount can fail repeatedly (busy/permissions). If
                // the candidate never became active, restore the local entry.
                // rollBackMountMigration proves its contents before doing so.
            }
        }
        if expected.direction == .restore, !isMountPoint(local), !isSymbolicLink(at: local),
           let identity = try? DataPathIdentity.capture(local),
           expected.destinationIdentity.map({ identity.matchesFilesystemObject($0) }) == true {
            try await finishVerifiedRecovery(expected)
            return .completed
        }
        if expected.direction == .restore, expected.isVerifiedSwitchRecoverable, finishPreparedRestore {
            do {
                try await finishVerifiedRecovery(expected)
                return .completed
            } catch {
                try Task.checkCancellation()
                guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
                // The source is still authoritative. A move/mount failure must
                // fall back to restoring that source's usable entry.
            }
        }
        var transfer = try store.transfer(operationID: expected.operationID) ?? expected
        if transfer.isPreparationRecoverable {
            do {
                try await cancelPreparation(transfer, preserveUnclaimedMaterials: false)
                return .rolledBack(retainedDetails: nil)
            } catch {
                try Task.checkCancellation()
                guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
                transfer = try store.transfer(operationID: expected.operationID) ?? transfer
            }
        }
        if transfer.direction == .migrate { return try await rollBackMountMigration(transfer) }
        return try await rollBackMountRestore(transfer)
    }

    private func requireOriginalLocalData(_ transfer: DataTransferRecord) throws {
        let local = URL(fileURLWithPath: transfer.originalPath)
        guard !isMountPoint(local), !isSymbolicLink(at: local),
              try DataPathIdentity.capture(local).matchesFilesystemObject(transfer.sourceIdentity) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
    }

    private func cleanupRolledBackOperation(_ expected: DataTransferRecord) async throws -> AutomaticRecoveryResult {
        var retained: String?
        do {
            if expected.direction == .migrate { try await removeUnactivatedMigrationVolume(expected) }
            else { try await removeUnactivatedRestoreCopy(expected) }
        } catch {
            try Task.checkCancellation()
            guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
            retained = "原数据入口已恢复；自动清理尚未完成：".localized + error.localizedDescription
        }
        guard let current = try store.transfer(operationID: expected.operationID) else { return .rolledBack(retainedDetails: nil) }
        try requireRecoveryJournal(current)
        try store.finishAutomaticMountRollback(current, preserving: retained, verifyingFilesystem: {})
        return .rolledBack(retainedDetails: retained)
    }

    /// Root identity proves that the restored source, or a completed successor,
    /// still supplies the live data. Its contents may legitimately have changed.
    private func currentRollbackSource(_ transfer: DataTransferRecord) async throws -> URL {
        let local = URL(fileURLWithPath: transfer.originalPath)
        if transfer.direction == .migrate, (try? requireOriginalLocalData(transfer)) != nil { return local }
        if transfer.direction == .restore, (try? requireRestoredMount(transfer)) != nil,
           let uuid = transfer.sourceIdentity.volumeUUID {
            try await requireExpectedVolume(uuid, at: local)
            return local
        }
        let successors = try store.transfers().filter {
            $0.rollbackCompletedAt == nil && $0.isDataSwitchComplete && $0.originalPath == transfer.originalPath
                && $0.sourceIdentity.matchesFilesystemObject(transfer.sourceIdentity)
        }
        guard successors.count == 1, let successor = successors.first else {
            throw DataOperationSafety.Failure.inspection(local.path)
        }
        let current = try store.completedLocation(after: successor.operationID)
        try await requireActiveData(for: current)
        return URL(fileURLWithPath: current.activePath)
    }

    private func rollBackMountMigration(_ expected: DataTransferRecord) async throws -> AutomaticRecoveryResult {
        var transfer = expected
        try requireRecoveryJournal(transfer)
        let local = URL(fileURLWithPath: transfer.originalPath)
        guard !isMountPoint(local) else { throw DataOperationSafety.Failure.conflict(local.path) }
        let originalIsLocal = !isSymbolicLink(at: local)
            && (try? DataPathIdentity.capture(local).matchesFilesystemObject(transfer.sourceIdentity)) == true
        if !originalIsLocal {
            guard let path = transfer.backupPath else { throw DataOperationSafety.Failure.inspection(local.path) }
            let backup = URL(fileURLWithPath: path)
            guard backup.deletingLastPathComponent() == local.deletingLastPathComponent(),
                  !isMountPoint(backup), !isSymbolicLink(at: backup),
                  try DataPathIdentity.capture(backup).matchesFilesystemObject(transfer.sourceIdentity) else {
                throw DataOperationSafety.Failure.conflict(path)
            }
            // A final journal failure followed by a reboot can leave a newer
            // destination at an automatic or private mount instead of local.
            // Never reactivate the old backup until redundancy is proven.
            try await requireUnactivatedMigrationDestination(&transfer)
            try requireRecoveryJournal(transfer)
            guard !isMountPoint(backup), !isSymbolicLink(at: backup),
                  try DataPathIdentity.capture(backup).matchesFilesystemObject(transfer.sourceIdentity) else {
                throw DataOperationSafety.Failure.conflict(backup.path)
            }
            try safety.requireLocalRestoreParent(at: local, isMountPoint: isMountPoint)
            if try verifiedResumeEntryExists(local) { try removeEmptyMountPoint(at: local, bundleIdentifier: transfer.bundleIdentifier) }
            try requireRecoveryJournal(transfer)
            try moveTree(backup, to: local)
            try DurableFileIO.syncDirectory(at: local.deletingLastPathComponent())
        }
        try requireOriginalLocalData(transfer)
        try store.finishAutomaticMountRollback(transfer, preserving: "AppPorts 正在自动清理本次操作的临时数据。".localized) {
            try requireOriginalLocalData(transfer)
        }
        transfer = try store.transfer(operationID: transfer.operationID) ?? transfer
        var retained: String?
        do { try await removeUnactivatedMigrationVolume(transfer) }
        catch {
            try Task.checkCancellation()
            guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
            retained = "原数据入口已恢复；自动清理尚未完成：".localized + error.localizedDescription
        }
        transfer = try store.transfer(operationID: transfer.operationID) ?? transfer
        try requireRecoveryJournal(transfer)
        try store.finishAutomaticMountRollback(transfer, preserving: retained) {
            try requireOriginalLocalData(transfer)
        }
        synchronizeAgent(store)
        return .rolledBack(retainedDetails: retained)
    }

    private func requireUnactivatedMigrationDestination(_ transfer: inout DataTransferRecord) async throws {
        guard let uuid = transfer.createdVolumeUUID, let identity = transfer.destinationIdentity,
              let encoded = transfer.baseline, let stagingPath = transfer.stagingPath,
              stagingPath == stagingMountRootURL.appendingPathComponent(transfer.operationID.uuidString).path else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        let info = try await disk.volumeInfo(for: uuid)
        try requireRecoveryJournal(transfer)
        guard info.isAPFS, info.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame else {
            throw DataOperationSafety.Failure.conflict(uuid)
        }
        let candidate: URL
        if let path = info.mountPoint, !path.isEmpty {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = URL(fileURLWithPath: stagingPath)
            guard let parentIdentity = transfer.stagingParentIdentity,
                  try DataPathIdentity.capture(candidate.deletingLastPathComponent()).matchesFilesystemObject(parentIdentity) else {
                throw DataOperationSafety.Failure.conflict(stagingPath)
            }
            try prepareCandidateCleanupMountPoint(&transfer, at: candidate)
            try await mountVolume(uuid, at: candidate, operationID: transfer.operationID.uuidString, allowRelocation: false,
                                  requireOwnership: baseline.ownershipCompatibility?.destinationIgnoresOwnership != true)
        }
        try await safety.requireNoKnownWriters(at: candidate, bundleIdentifier: transfer.bundleIdentifier)
        try await requireExpectedVolume(uuid, at: candidate)
        try requireRecoveryJournal(transfer)
        guard !isSymbolicLink(at: candidate),
              try DataPathIdentity.capture(candidate, volumeUUID: uuid).matchesFilesystemObject(identity) else {
            throw DataOperationSafety.Failure.conflict(candidate.path)
        }
        if transfer.hasNeverActivatedMigrationCandidate {
            try requireExclusiveMigrationCandidate(transfer)
            guard DiskUtility.pathsMatch(candidate.path, stagingPath),
                  let container = transfer.volumeCreationContainerUUID,
                  try await disk.apfsContainerUUID(containingVolume: uuid).caseInsensitiveCompare(container) == .orderedSame,
                  let record = transfer.recoveryMountRecord else {
                throw DataOperationSafety.Failure.inspection(candidate.path)
            }
            try requireVolumeMarker(at: candidate, record: record)
            try requireRecoveryJournal(transfer)
        } else { try TreeCopySession.verifyCopy(at: candidate, against: baseline) }
    }

    private func prepareCandidateCleanupMountPoint(_ transfer: inout DataTransferRecord, at staging: URL) throws {
        try requireRecoveryJournal(transfer)
        let parent = staging.deletingLastPathComponent()
        guard let parentIdentity = transfer.stagingParentIdentity, !isSymbolicLink(at: parent),
              try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity) else {
            throw DataOperationSafety.Failure.conflict(parent.path)
        }
        if try !verifiedResumeEntryExists(staging) {
            guard transfer.candidateRemovalMountPointIdentity == nil else {
                throw DataOperationSafety.Failure.conflict(staging.path)
            }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try DurableFileIO.syncDirectory(at: parent)
            transfer.candidateRemovalMountPointIdentity = try DataPathIdentity.capture(staging)
            try store.updateTransfer(transfer)
        }
        guard !isSymbolicLink(at: staging), !isMountPoint(staging) else {
            throw DataOperationSafety.Failure.conflict(staging.path)
        }
        if let identity = transfer.candidateRemovalMountPointIdentity ?? transfer.stagingIdentity {
            if try DataPathIdentity.capture(staging).matchesFilesystemObject(identity) { return }
            // A crash after mkdir but before saving the cleanup claim leaves
            // an empty placeholder, not an unclaimed payload. Its parent and
            // exact operation path are already proven; adopt only that empty
            // directory, never an existing/replaced volume root or data tree.
            guard transfer.candidateRemovalMountPointIdentity == nil,
                  try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty else {
                throw DataOperationSafety.Failure.conflict(staging.path)
            }
            transfer.candidateRemovalMountPointIdentity = try DataPathIdentity.capture(staging)
            try store.updateTransfer(transfer)
        } else {
            // The UUID is known but creation failed before claiming any payload.
            guard transfer.destinationIdentity == nil,
                  try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty else {
                throw DataOperationSafety.Failure.conflict(staging.path)
            }
            transfer.candidateRemovalMountPointIdentity = try DataPathIdentity.capture(staging)
            try store.updateTransfer(transfer)
        }
    }

    /// A failed candidate must not be owned by a live index or another journal,
    /// even if that record refers to the same volume through a different path.
    private func requireExclusiveMigrationCandidate(_ transfer: DataTransferRecord, mountedPath: String? = nil) throws {
        try requireRecoveryJournal(transfer)
        guard transfer.mode == .mount, transfer.direction == .migrate, !transfer.isDataSwitchComplete,
              transfer.retainedCopyRemovedAt == nil, let uuid = transfer.createdVolumeUUID,
              let staging = transfer.stagingPath else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        func sameVolume(_ value: String?) -> Bool { value?.caseInsensitiveCompare(uuid) == .orderedSame }
        func overlaps(_ path: String) -> Bool {
            [staging, mountedPath].compactMap { $0 }.contains {
                DataPathTopology.overlaps(DataPathTopology.relationship($0, path))
            }
        }
        func referencesVolume(_ value: DataTransferRecord) -> Bool {
            sameVolume(value.createdVolumeUUID) || sameVolume(value.sourceIdentity.volumeUUID)
                || sameVolume(value.destinationIdentity?.volumeUUID) || sameVolume(value.destinationVolumeUUID)
                || sameVolume(value.backupIdentity?.volumeUUID) || sameVolume(value.recoveryMountRecord?.volumeUUID)
        }
        guard try !store.recordsStrict().contains(where: { sameVolume($0.volumeUUID) || overlaps($0.mountPointPath) }),
              try !store.pendingCleanups().contains(where: {
                  sameVolume($0.mountRecord.volumeUUID) || overlaps($0.localPath)
                    || $0.restoreStagingPath.map(overlaps) == true
              }),
              try !store.managedLinks().contains(where: {
                  sameVolume($0.destinationIdentity.volumeUUID) || $0.topologyEntries.contains { overlaps($0.path) }
              }),
              try !store.transfers().contains(where: {
                  $0.operationID != transfer.operationID && (referencesVolume($0)
                    || $0.topologyEntries.contains { overlaps($0.path) })
              }),
              try !store.preservedMaterials().contains(where: {
                  sameVolume($0.volumeUUID) || $0.paths.contains(where: overlaps)
                    || $0.recoveryRecord.map(referencesVolume) == true
              }) else { throw DataOperationSafety.Failure.conflict(staging) }
    }

    /// Reconnection gives an unused candidate a new device number and may
    /// mount it at /Volumes. Prove its persistent identity before detaching it;
    /// deletion still happens through the private staging and final checks.
    private func detachAutomaticallyMountedCandidate(_ transfer: DataTransferRecord, at automatic: URL) async throws {
        guard transfer.hasNeverActivatedMigrationCandidate,
              let uuid = transfer.createdVolumeUUID, let identity = transfer.destinationIdentity,
              let record = transfer.recoveryMountRecord,
              record.volumeName == transfer.volumeCreationName,
              record.volumeUUID.caseInsensitiveCompare(uuid) == .orderedSame,
              automatic.deletingLastPathComponent().standardizedFileURL == automaticMountRootURL,
              automatic.lastPathComponent == record.volumeName else {
            throw DataOperationSafety.Failure.conflict(automatic.path)
        }
        let parentIdentity = try DataPathIdentity.capture(automaticMountRootURL)
        func verifyOwnership() throws {
            try requireExclusiveMigrationCandidate(transfer, mountedPath: automatic.path)
            guard !isSymbolicLink(at: automaticMountRootURL),
                  try DataPathIdentity.capture(automaticMountRootURL).matchesFilesystemObject(parentIdentity),
                  try DataPathIdentity.capture(automatic, volumeUUID: uuid).matchesFilesystemObject(identity) else {
                throw DataOperationSafety.Failure.conflict(automatic.path)
            }
            try requireVolumeMarker(at: automatic, record: record)
        }
        try verifyOwnership()
        let local = try await currentRollbackSource(transfer)
        try await requireExpectedVolume(uuid, at: automatic)
        try await safety.requireNoKnownWriters(at: automatic)
        try await safety.requireNoKnownWriters(at: local, bundleIdentifier: transfer.bundleIdentifier)
        try await requireExpectedVolume(uuid, at: automatic)
        _ = try await currentRollbackSource(transfer)
        try verifyOwnership()
        let sourceIdentity = try DataPathIdentity.capture(local)
        let sourceWasMounted = isMountPoint(local)
        let authorization = try DiskUtility.DeletionAuthorizationEvidence(
            ledger: store.fileURLForDeletionAuthorization, directories: [local, automaticMountRootURL, automatic])
        try await disk.unmountCandidate(uuid, at: automatic, authorizationEvidence: authorization) {
            try self.store.recheckWriterAdmission()
            try verifyOwnership()
            guard !self.isSymbolicLink(at: local), self.isMountPoint(local) == sourceWasMounted,
                  try DataPathIdentity.capture(local).matchesFilesystemObject(sourceIdentity) else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        }
        try requireExclusiveMigrationCandidate(transfer, mountedPath: automatic.path)
        _ = try await currentRollbackSource(transfer)
        guard !isMountPoint(automatic) else { throw MigrationError.unmountFailed(automatic, "") }
        let info = try await disk.volumeInfo(for: uuid)
        guard info.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame,
              info.mountPoint?.isEmpty ?? true else { throw DataOperationSafety.Failure.conflict(automatic.path) }
    }

    /// Preparation cancellation and rolled-back cleanup share this path. A
    /// never-activated, claimed candidate is disposable; ambiguous legacy and
    /// activation-attempted volumes still need the original content proof.
    func removeUnactivatedMigrationVolume(_ expected: DataTransferRecord) async throws {
        var transfer = expected
        try requireRecoveryJournal(transfer)
        _ = try await currentRollbackSource(transfer)
        guard let uuid = transfer.createdVolumeUUID else {
            if let container = transfer.volumeCreationContainerUUID {
                guard let name = transfer.volumeCreationName,
                      try await !disk.hasAPFSVolume(named: name, inContainerUUID: container) else {
                    throw DataOperationSafety.Failure.inspection(transfer.volumeCreationName ?? transfer.originalPath)
                }
                try requireRecoveryJournal(transfer)
            }
            return
        }
        guard let container = transfer.volumeCreationContainerUUID, let stagingPath = transfer.stagingPath,
              stagingPath == stagingMountRootURL.appendingPathComponent(transfer.operationID.uuidString).path else {
            throw DataOperationSafety.Failure.inspection(uuid)
        }
        try requireExclusiveMigrationCandidate(transfer)
        let staging = URL(fileURLWithPath: stagingPath)
        let parent = staging.deletingLastPathComponent()
        func requireParent() throws {
            guard let identity = transfer.stagingParentIdentity,
                  !isSymbolicLink(at: parent),
                  try DataPathIdentity.capture(parent).matchesFilesystemObject(identity) else {
                throw DataOperationSafety.Failure.conflict(parent.path)
            }
        }
        func removePlaceholder() throws {
            guard try verifiedResumeEntryExists(staging) else {
                if transfer.preparationRemovalParentIdentity != nil || transfer.candidateRemovalMountPointIdentity != nil {
                    try requireParent()
                    try synchronizeCleanupParent(parent)
                    try requireParent()
                }
                return
            }
            try requireParent()
            guard let identity = transfer.candidateRemovalMountPointIdentity ?? transfer.stagingIdentity,
                  !isMountPoint(staging), !isSymbolicLink(at: staging),
                  try DataPathIdentity.capture(staging).matchesFilesystemObject(identity) else {
                throw DataOperationSafety.Failure.conflict(stagingPath)
            }
            try removeEmptyMountPoint(at: staging)
            try synchronizeCleanupParent(parent)
            try requireParent()
        }
        if try await !disk.apfsVolumeIsPresent(uuid, inContainer: container) {
            try requireExclusiveMigrationCandidate(transfer)
            _ = try await currentRollbackSource(transfer)
            try removePlaceholder()
            return
        }
        let local = try await currentRollbackSource(transfer)
        guard try await disk.apfsContainerUUID(containingVolume: uuid).caseInsensitiveCompare(container) == .orderedSame else {
            throw DataOperationSafety.Failure.conflict(uuid)
        }
        let info = try await disk.volumeInfo(for: uuid)
        guard info.isAPFS, info.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame else {
            throw DataOperationSafety.Failure.conflict(uuid)
        }
        if let current = info.mountPoint, !current.isEmpty, !DiskUtility.pathsMatch(current, stagingPath) {
            try await detachAutomaticallyMountedCandidate(transfer, at: URL(fileURLWithPath: current))
        }
        // Creation may have failed before the private parent was claimed. Only
        // an empty volume can use that older recovery route below.
        if transfer.stagingParentIdentity == nil {
            guard transfer.destinationIdentity == nil else { throw DataOperationSafety.Failure.conflict(parent.path) }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            transfer.stagingParentIdentity = try DataPathIdentity.capture(parent)
            try store.updateTransfer(transfer)
        }
        try requireParent()
        let baseline = try (transfer.baseline ?? transfer.sourceBaseline).map {
            try PropertyListDecoder().decode(TreeCopySnapshot.self, from: $0)
        }
        try requireExclusiveMigrationCandidate(transfer)
        _ = try await currentRollbackSource(transfer)
        if !isMountPoint(staging) {
            try prepareCandidateCleanupMountPoint(&transfer, at: staging)
            let requiresOwnership = baseline.map { $0.ownershipCompatibility?.destinationIgnoresOwnership != true }
                ?? (transfer.recoveryMountRecord?.ownershipPolicy == .owners)
            try await mountVolume(uuid, at: staging, operationID: transfer.operationID.uuidString,
                                  allowRelocation: false, requireOwnership: requiresOwnership)
        }
        try await requireExpectedVolume(uuid, at: staging)
        try await safety.requireNoKnownWriters(at: staging)
        try await safety.requireNoKnownWriters(at: local, bundleIdentifier: transfer.bundleIdentifier)
        try requireExclusiveMigrationCandidate(transfer)
        func verifyCandidate() throws {
            try requireParent()
            guard !isSymbolicLink(at: staging) else { throw DataOperationSafety.Failure.conflict(stagingPath) }
            if let identity = transfer.destinationIdentity {
                guard try DataPathIdentity.capture(staging, volumeUUID: uuid).matchesFilesystemObject(identity) else {
                    throw DataOperationSafety.Failure.conflict(stagingPath)
                }
                if transfer.hasNeverActivatedMigrationCandidate {
                    guard transfer.preparationPath == stagingPath, transfer.sourceBaseline != nil,
                          let creationParent = transfer.preparationParentIdentity,
                          try DataPathIdentity.capture(parent).matchesFilesystemObject(creationParent),
                          let record = transfer.recoveryMountRecord,
                          record.volumeName == transfer.volumeCreationName else {
                        throw DataOperationSafety.Failure.inspection(stagingPath)
                    }
                    try requireVolumeMarker(at: staging, record: record)
                } else {
                    guard let baseline else { throw DataOperationSafety.Failure.inspection(stagingPath) }
                    if transfer.baseline != nil { try TreeCopySession.verifyCopy(at: staging, against: baseline) }
                    else { _ = try TreeCopySession.partialCopySnapshot(at: staging, source: local, against: baseline) }
                }
            } else {
                guard Set(try FileManager.default.contentsOfDirectory(atPath: stagingPath)).isSubset(of: Self.volumeSystemArtifacts) else {
                    throw DataOperationSafety.Failure.conflict(stagingPath)
                }
            }
            if try verifiedResumeEntryExists(staging.appendingPathComponent(Self.volumeMarkerFileName)) {
                guard Self.readVolumeMarkerUUID(at: staging)?.caseInsensitiveCompare(uuid) == .orderedSame else {
                    throw DataOperationSafety.Failure.conflict(stagingPath)
                }
            }
        }
        try verifyCandidate()
        transfer.preparationRemovalParentIdentity = transfer.preparationRemovalParentIdentity ?? transfer.stagingParentIdentity
        try store.updateTransfer(transfer)
        if transfer.hasNeverActivatedMigrationCandidate {
            // The original remains authoritative throughout this failed copy.
            // We do not remove any of its files; new unreadable application
            // children must not prevent disposal of our unused candidate.
            try DurableFileIO.syncDirectory(at: local)
        } else { try DurableFileIO.syncTree(at: local, excludingRootEntries: Self.volumeSystemArtifacts) }
        let syncedSourceIdentity = try DataPathIdentity.capture(local)
        let sourceWasMounted = isMountPoint(local)
        try await requireExpectedVolume(uuid, at: staging)
        try requireExclusiveMigrationCandidate(transfer)
        _ = try await currentRollbackSource(transfer)
        try verifyCandidate()
        try await unmountVolume(mountPoint: staging)
        try requireExclusiveMigrationCandidate(transfer)
        _ = try await currentRollbackSource(transfer)
        try requireParent()
        guard !isMountPoint(staging) else { throw MigrationError.unmountFailed(staging, "") }
        let unmounted = try await disk.volumeInfo(for: uuid)
        guard unmounted.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame,
              unmounted.mountPoint?.isEmpty ?? true,
              try await disk.apfsContainerUUID(containingVolume: uuid).caseInsensitiveCompare(container) == .orderedSame else {
            throw DataOperationSafety.Failure.conflict(uuid)
        }
        try requireExclusiveMigrationCandidate(transfer)
        let deleting = transfer
        let authorization = try DiskUtility.DeletionAuthorizationEvidence(
            ledger: store.fileURLForDeletionAuthorization, directories: [local, parent])
        try await deleteAPFSVolume(uuid, requireUnmounted: true, authorizationEvidence: authorization) {
            try self.store.recheckWriterAdmission()
            try self.requireExclusiveMigrationCandidate(deleting)
            guard !self.isMountPoint(staging), !self.isSymbolicLink(at: local),
                  self.isMountPoint(local) == sourceWasMounted,
                  try DataPathIdentity.capture(local).matchesFilesystemObject(syncedSourceIdentity),
                  let identity = deleting.stagingParentIdentity,
                  try DataPathIdentity.capture(parent).matchesFilesystemObject(identity) else {
                throw DataOperationSafety.Failure.conflict(stagingPath)
            }
        }
        guard try await !disk.apfsVolumeIsPresent(uuid, inContainer: container) else {
            throw DataOperationSafety.Failure.inspection(uuid)
        }
        try removePlaceholder()
    }

    private func requireRestoredMount(_ transfer: DataTransferRecord) throws {
        let local = URL(fileURLWithPath: transfer.originalPath)
        guard isMountPoint(local), let uuid = transfer.sourceIdentity.volumeUUID else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        if transfer.sourceIdentity.isResolved {
            guard try DataPathIdentity.capture(local, volumeUUID: uuid).matchesFilesystemObject(transfer.sourceIdentity) else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        }
    }

    private func rollBackMountRestore(_ expected: DataTransferRecord) async throws -> AutomaticRecoveryResult {
        var transfer = expected
        guard let record = transfer.recoveryMountRecord else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        try requireRecoveryJournal(transfer)
        let local = record.mountPointURL
        if !isMountPoint(local) {
            try safety.requireLocalRestoreParent(at: local, isMountPoint: isMountPoint)
            let hint = try await knownMountPoint(for: record, operationID: transfer.operationID.uuidString)
            if case .mounted(let current) = hint {
                try await safety.requireNoKnownWriters(at: current, bundleIdentifier: transfer.bundleIdentifier)
            }
            try requireRecoveryJournal(transfer)
            let requiresOwnership: Bool
            if let encoded = transfer.baseline ?? transfer.sourceBaseline {
                let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
                requiresOwnership = baseline.ownershipCompatibility?.sourceIgnoresOwnership != true
            } else if let flags = transfer.originalSourceMountFlags ?? transfer.legacyMountFlags {
                requiresOwnership = flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0
            } else {
                requiresOwnership = record.ownershipPolicy == .owners || transfer.legacyRootOwnership != nil
            }
            try await mountVolume(record.volumeUUID, at: local, operationID: transfer.operationID.uuidString,
                                  knownMountPoint: hint, requireOwnership: requiresOwnership, bundleIdentifier: record.bundleIdentifier)
        }
        try await requireExpectedVolume(record.volumeUUID, at: local)
        try requireRestoredMount(transfer)
        if let flags = transfer.originalSourceMountFlags ?? transfer.legacyMountFlags {
            try requireRecoveryJournal(transfer)
            try await restoreOriginalMountOptions(mountPoint: local, volumeUUID: record.volumeUUID, originalFlags: flags,
                                                  bundleIdentifier: record.bundleIdentifier)
        }
        try store.finishAutomaticMountRollback(transfer, preserving: "AppPorts 正在自动清理本次操作的临时数据。".localized) {
            try requireRestoredMount(transfer)
        }
        transfer = try store.transfer(operationID: transfer.operationID) ?? transfer
        var retained: String?
        do { try await removeUnactivatedRestoreCopy(transfer) }
        catch {
            try Task.checkCancellation()
            guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
            retained = "原数据入口已恢复；自动清理尚未完成：".localized + error.localizedDescription
        }
        transfer = try store.transfer(operationID: transfer.operationID) ?? transfer
        try await requireExpectedVolume(record.volumeUUID, at: local)
        try requireRecoveryJournal(transfer)
        let removalPath = transfer.stagingPath.flatMap { path in
            (try? TreeCopySession.retainedRemovalURL(at: URL(fileURLWithPath: path), removalID: transfer.operationID))?.path
        }
        try store.finishAutomaticMountRollback(transfer, preserving: retained,
            additionalMaterialPaths: removalPath.map { [$0] } ?? []) {
            try requireRestoredMount(transfer)
        }
        synchronizeAgent(store)
        return .rolledBack(retainedDetails: retained)
    }

    private func removeUnactivatedRestoreCopy(_ transfer: DataTransferRecord) async throws {
        guard let path = transfer.stagingPath else { return }
        let staging = URL(fileURLWithPath: path)
        guard let actual = try TreeCopySession.retainedRemovalURL(at: staging, removalID: transfer.operationID) else { return }
        guard let identity = transfer.destinationIdentity, let encoded = transfer.baseline ?? transfer.sourceBaseline,
              let parentIdentity = transfer.preparationParentIdentity,
              !isMountPoint(actual), !isSymbolicLink(at: actual),
              try DataPathIdentity.capture(actual).matchesFilesystemObject(identity),
              try DataPathIdentity.capture(staging.deletingLastPathComponent()).matchesFilesystemObject(parentIdentity) else {
            throw DataOperationSafety.Failure.conflict(path)
        }
        let local = try await currentRollbackSource(transfer)
        try await safety.requireNoKnownWriters(at: local, bundleIdentifier: transfer.bundleIdentifier)
        try await safety.requireNoKnownWriters(at: actual)
        try requireRecoveryJournal(transfer)
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        // A full candidate/removal manifest proves the obsolete bytes without
        // comparing today's live tree to yesterday's contents. Partial copies
        // still require the matching source bytes to prove their prefixes.
        let removal: TreeCopySnapshot
        let wasRemoving = transfer.preparationRemovalBaseline != nil
        if let saved = transfer.preparationRemovalBaseline {
            removal = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: saved)
        } else if transfer.baseline != nil {
            removal = try TreeCopySession.verifiedCopySnapshot(at: actual, against: baseline)
        } else {
            removal = try TreeCopySession.partialCopySnapshot(at: staging, source: local, against: baseline,
                sourceVolumeUUID: DiskUtility.mountedVolumeUUID(at: local))
        }
        var removing = transfer
        removing.sourceBaseline = removing.sourceBaseline ?? encoded
        removing.preparationRemovalBaseline = try removing.preparationRemovalBaseline ?? PropertyListEncoder().encode(removal)
        removing.preparationRemovalParentIdentity = removing.preparationRemovalParentIdentity ?? parentIdentity
        try store.updateTransfer(removing)
        try DurableFileIO.syncTree(at: local, excludingRootEntries: Self.volumeSystemArtifacts)
        try TreeCopySession.removeVerifiedCopy(at: staging, against: removal, allowPartialRemoval: wasRemoving,
            expectedVolumeUUID: identity.volumeUUID, removalID: transfer.operationID)
        try DurableFileIO.syncDirectory(at: staging.deletingLastPathComponent())
    }

    /// Runs under the caller's operation lock with a noninteractive DiskUtility.
    /// Failed recovery remains durable; unchanged background failures stay quiet.
    @discardableResult
    func performAutomaticMaintenance(only operationID: UUID? = nil, ignoresRetryBackoff: Bool = false,
                                     now: @escaping @Sendable () -> Date = { Date() }) async -> [String] {
        await CleanupRetryContext.$automatic.withValue(!ignoresRetryBackoff) {
            await CleanupRetryContext.$now.withValue(now) {
                await self.performScheduledMaintenance(only: operationID, ignoresRetryBackoff: ignoresRetryBackoff)
            }
        }
    }

    private func performScheduledMaintenance(only operationID: UUID?, ignoresRetryBackoff: Bool) async -> [String] {
        var warnings: [String] = []
        let transfers: [DataTransferRecord]
        let ejection: DiskEjectionPauseStore.Snapshot
        do {
            ejection = try await DiskEjectionPauseStore(store: store).refreshed(using: disk)
            transfers = try store.transfers()
            if ignoresRetryBackoff, let operationID,
               let selected = transfers.first(where: { $0.operationID == operationID && $0.mode == .mount }),
               try store.manualMountPauseBlocks(selected) {
                return [ManualMountPauseError.retryPaused.localizedDescription]
            }
        }
        catch { return [error.localizedDescription] }
        for transfer in transfers where transfer.mode == .mount && !transfer.isDataSwitchComplete && transfer.needsAutomaticCompletion
            && (operationID == nil || transfer.operationID == operationID) {
            do {
                if try store.manualMountPauseBlocks(transfer) { continue }
            } catch { warnings.append(error.localizedDescription); continue }
            if ejection.blocks(transfer) { continue }
            if Task.isCancelled { return warnings }
            // Defer expensive residue checks only if a usable original entry
            // still exists. Never defer the work needed to restore that entry.
            if !ignoresRetryBackoff, CleanupRetryBackoff.shouldDefer(until: transfer.nextAutomaticRetryAt, now: CleanupRetryContext.now()),
               let source = try? await currentRollbackSource(transfer), VolumePathProbe.isReadableDirectory(source) { continue }
            do {
                let result = try await recoverWithIndependentBudget(transfer, finishPreparedRestore: false)
                if case .rolledBack(let reason?) = result {
                    warnings.append(transfer.appName + ": " + reason)
                    CleanupRetryContext.recordFailureIfUnchanged(transfer, store: store)
                }
            }
            catch {
                warnings.append(transfer.appName + ": " + error.localizedDescription)
                if var current = try? store.transfer(operationID: transfer.operationID), current.recoverableReason != error.localizedDescription {
                    current.recoverableReason = error.localizedDescription
                    try? store.updateTransfer(current)
                }
                CleanupRetryContext.recordFailureIfUnchanged(transfer, store: store)
            }
        }
        guard let completed = try? store.transfers() else { return warnings }
        for transfer in completed where transfer.mode == .mount && transfer.isDataSwitchComplete && transfer.needsAutomaticCompletion
            && (operationID == nil || transfer.operationID == operationID) {
            do {
                if try store.manualMountPauseBlocks(transfer) { continue }
            } catch { warnings.append(error.localizedDescription); continue }
            if ejection.blocks(transfer) { continue }
            if Task.isCancelled { return warnings }
            guard ignoresRetryBackoff || !CleanupRetryBackoff.shouldDefer(until: transfer.nextAutomaticRetryAt, now: CleanupRetryContext.now()) else { continue }
            guard let record = transfer.recoveryMountRecord else { continue }
            if let warning = await completeSuccessfulTransfer(operationID: transfer.operationID, direction: transfer.direction,
                record: record, progressHandler: nil) {
                warnings.append(warning.message)
                CleanupRetryContext.recordFailureIfUnchanged(transfer, store: store)
            }
        }
        guard operationID == nil else { return warnings }
        for cleanup in (try? store.pendingCleanups()) ?? [] {
            do {
                if try store.isManuallyUnmounted(cleanup.mountRecord) { continue }
            } catch { warnings.append(error.localizedDescription); continue }
            if ejection.blocks(volumeUUIDs: [cleanup.mountRecord.volumeUUID],
                paths: [cleanup.localPath, cleanup.mountRecord.externalRootPath]) { continue }
            // Legacy restore staging can be required for recovering the entry.
            guard ignoresRetryBackoff || cleanup.restoreStagingPath != nil
                || !CleanupRetryBackoff.shouldDefer(until: cleanup.nextAutomaticRetryAt, now: CleanupRetryContext.now()) else { continue }
            if let warning = await retryCleanup(.init(cleanup: cleanup, details: "")) {
                warnings.append(warning.message)
                recordCleanupRetry(.legacy(cleanup.id), failed: true, now: CleanupRetryContext.now())
            } else { recordCleanupRetry(.legacy(cleanup.id), failed: false, now: CleanupRetryContext.now()) }
        }
        warnings += await cleanupPreservedRestoreMaterials(ignoresRetryBackoff: ignoresRetryBackoff)
        return warnings
    }

    private func recordCleanupRetry(_ target: CleanupRetryTarget, failed: Bool, now: Date) {
        do { try store.recordCleanupRetry(target, failed: failed, now: now) }
        catch { AppLogger.shared.logError("无法保存清理重试时间", error: error, errorCode: "CLEANUP-RETRY-SAVE-FAILED") }
    }

    /// Private placement and inode identity do not prove redundancy. Full
    /// copies require saved verification; partial copies require source bytes.
    func cleanupPreservedRestoreMaterials(at originalPath: String? = nil, ignoresRetryBackoff: Bool? = nil) async -> [String] {
        var warnings: [String] = []
        for material in (try? store.preservedMaterials()) ?? [] {
            do {
                if let recovery = material.recoveryRecord, try store.manualMountPauseBlocks(recovery) { continue }
                if try DiskEjectionPauseStore(store: store).snapshot().blocks(volumeUUIDs: [material.volumeUUID],
                    paths: material.paths, containerUUID: material.containerUUID) { continue }
            } catch { return [error.localizedDescription] }
            guard (ignoresRetryBackoff ?? !CleanupRetryContext.automatic)
                || !CleanupRetryBackoff.shouldDefer(until: material.nextAutomaticRetryAt, now: CleanupRetryContext.now()) else { continue }
            guard originalPath == nil || originalPath == material.originalPath,
                  material.mode == .mount, material.direction == .restore,
                  material.volumeUUID == nil, let transfer = material.recoveryRecord,
                  transfer.operationID == material.id, !transfer.isDataSwitchComplete,
                  transfer.mode == material.mode, transfer.direction == material.direction,
                  transfer.originalPath == material.originalPath, transfer.appName == material.appName,
                  let candidateIdentity = transfer.destinationIdentity,
                  let parentIdentity = transfer.preparationParentIdentity,
                  let stagingPath = transfer.stagingPath else { continue }
            do {
                var material = material
                let local = URL(fileURLWithPath: material.originalPath)
                let staging = local.deletingLastPathComponent().appendingPathComponent(".appports-restore-staging-" + material.id.uuidString)
                let recovery = stagingMountRootURL.appendingPathComponent("recovery-" + material.id.uuidString)
                guard staging.path == stagingPath,
                      Set(material.paths).isSubset(of: [staging.path, recovery.path]),
                      existingRealDirectory(at: local), !isSymbolicLink(at: local),
                      try DataPathIdentity.capture(staging.deletingLastPathComponent()).matchesFilesystemObject(parentIdentity),
                      try !DataPathIdentity.capture(local).matchesFilesystemObject(candidateIdentity),
                      try store.transfers().allSatisfy({ $0.originalPath != local.path || $0.rollbackCompletedAt != nil || $0.isDataSwitchComplete }) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
                try await safety.requireNoKnownWriters(at: local, bundleIdentifier: transfer.bundleIdentifier)
                if isMountPoint(local) {
                    guard let record = try store.recordsStrict().first(where: { $0.mountPointPath == local.path }) else {
                        throw DataOperationSafety.Failure.conflict(local.path)
                    }
                    try await requireExpectedVolume(record.volumeUUID, at: local)
                }
                let activeIdentity = try DataPathIdentity.capture(local)
                guard transfer.sourceIdentity.matchesFilesystemObject(activeIdentity),
                      VolumePathProbe.isReadableDirectory(local) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
                if let actual = try TreeCopySession.retainedRemovalURL(at: staging, removalID: material.id) {
                    guard !isMountPoint(actual), !isSymbolicLink(at: actual),
                          try DataPathIdentity.capture(actual).matchesFilesystemObject(candidateIdentity) else {
                        throw DataOperationSafety.Failure.conflict(actual.path)
                    }
                    try await safety.requireNoKnownWriters(at: actual)
                    let baseline: TreeCopySnapshot
                    let wasRemoving = transfer.preparationRemovalBaseline != nil
                    if let saved = transfer.preparationRemovalBaseline {
                        baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: saved)
                    } else if let verified = transfer.baseline {
                        baseline = try TreeCopySession.verifiedCopySnapshot(at: actual,
                            against: PropertyListDecoder().decode(TreeCopySnapshot.self, from: verified))
                    } else if let partial = transfer.sourceBaseline {
                        baseline = try TreeCopySession.partialCopySnapshot(at: actual, source: local,
                            against: PropertyListDecoder().decode(TreeCopySnapshot.self, from: partial),
                            sourceVolumeUUID: DiskUtility.mountedVolumeUUID(at: local))
                    } else {
                        throw DataOperationSafety.Failure.inspection(local.path)
                    }
                    if !wasRemoving {
                        material = try store.checkpointPreservedRemoval(PropertyListEncoder().encode(baseline), expected: material)
                    }
                    try DurableFileIO.syncTree(at: local, excludingRootEntries: Self.volumeSystemArtifacts)
                    guard try store.preservedMaterial(id: material.id) == material,
                          try DataPathIdentity.capture(local) == activeIdentity,
                          try DataPathIdentity.capture(staging.deletingLastPathComponent()).matchesFilesystemObject(parentIdentity) else {
                        throw DataOperationSafety.Failure.conflict(local.path)
                    }
                    try TreeCopySession.removeVerifiedCopy(at: actual, against: baseline, allowPartialRemoval: wasRemoving,
                        expectedVolumeUUID: candidateIdentity.volumeUUID, removalID: material.id, requireSourceIdentity: true)
                    try DurableFileIO.syncDirectory(at: staging.deletingLastPathComponent())
                }
                if try verifiedResumeEntryExists(recovery) {
                    guard !isMountPoint(recovery), !isSymbolicLink(at: recovery),
                          try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty else {
                        throw DataOperationSafety.Failure.conflict(recovery.path)
                    }
                    try removeEmptyMountPoint(at: recovery)
                }
                try store.removePreservedMaterialRecord(material)
            } catch {
                warnings.append(material.appName + ": " + error.localizedDescription)
                recordCleanupRetry(.material(material.id), failed: true, now: CleanupRetryContext.now())
            }
        }
        return warnings
    }
}
