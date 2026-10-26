import Darwin
import Foundation

/// No-follow filesystem identity. Paths may change during a switch; these facts must not.
struct DataPathIdentity: Codable, Equatable, Sendable {
    let device: UInt64?
    let inode: UInt64?
    var volumeUUID: String?

    init(device: UInt64, inode: UInt64, volumeUUID: String? = nil) {
        self.device = device
        self.inode = inode
        self.volumeUUID = volumeUUID
    }

    /// Offline APFS restore intent. Enrich exactly once after the private mount is inspected.
    init(volumeUUID: String) {
        self.device = nil
        self.inode = nil
        self.volumeUUID = volumeUUID
    }

    var isResolved: Bool { device != nil && (inode ?? 0) > 0 }
    var isVolumeOnly: Bool { device == nil && inode == nil && !(volumeUUID ?? "").isEmpty }

    /// Semantic identity across APFS reattachment. Callers must independently prove
    /// the volume UUID at the inspected path; Codable/Equatable retains exact recorded facts.
    func matchesFilesystemObject(_ other: DataPathIdentity) -> Bool {
        guard isResolved, other.isResolved, inode == other.inode else { return false }
        if let expected = volumeUUID, let actual = other.volumeUUID {
            return !expected.isEmpty && expected.caseInsensitiveCompare(actual) == .orderedSame
        }
        return device == other.device
    }

    static func capture(_ url: URL, volumeUUID: String? = nil) throws -> DataPathIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var resolvedUUID = volumeUUID
        if resolvedUUID == nil {
            // A symlink's inode belongs to its parent filesystem, not its target.
            var identityURL = info.st_mode & S_IFMT == S_IFLNK ? url.deletingLastPathComponent() : url
            identityURL.removeAllCachedResourceValues()
            resolvedUUID = try identityURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        }
        return DataPathIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), volumeUUID: resolvedUUID)
    }
}

/// Intent, recovery state, and ordinary retained copies share one durable operation ID.
/// `baseline` is supplied by the verified copier; legacy cleanup records never acquire one implicitly.
struct DataTransferRecord: Codable, Equatable, Identifiable, Sendable {
    enum Mode: String, Codable, Sendable { case mount, symlink }
    enum Direction: String, Codable, Sendable { case migrate, restore }
    enum Phase: String, Codable, CaseIterable, Sendable {
        case preparing, copying, verified, switching, awaitingUserVerification, cleanupRequested, needsRecovery
    }

    var id: UUID { operationID }
    let operationID: UUID
    let mode: Mode
    let direction: Direction
    /// Source-relative UI identifier, never derived from the active external path.
    let sourceID: String?
    let appName: String
    let bundleIdentifier: String?
    let dataDirType: String
    var originalPath: String
    var activePath: String
    var destinationPath: String
    var backupPath: String?
    var stagingPath: String?
    var sourceIdentity: DataPathIdentity
    var destinationIdentity: DataPathIdentity?
    /// Captured before copying so a surviving mount-point directory cannot
    /// make an offline target volume look like an untouched local destination.
    var destinationVolumeUUID: String?
    var backupIdentity: DataPathIdentity?
    var createdVolumeUUID: String?
    /// Follows the verified location of this source across migration, restore,
    /// and a later migration while an earlier copy still awaits cleanup.
    let priorOperationID: UUID?
    let createdAt: Date
    let policyVersion: Int
    var phase: Phase
    var baseline: Data?
    /// Prepared before creating/writing the candidate. It never means the
    /// destination was verified and is never replaced by current source data.
    var sourceBaseline: Data? = nil
    /// The private candidate may be published at destinationPath after it is
    /// verified. Parent and root identities are claimed before payload writes.
    var preparationPath: String? = nil
    var preparationParentIdentity: DataPathIdentity? = nil
    var stagingParentIdentity: DataPathIdentity? = nil
    var stagingIdentity: DataPathIdentity? = nil
    /// Persisted before asking the system to create a volume. A missing UUID
    /// after this point is unknown material, never permission to delete a name.
    var volumeCreationContainerUUID: String? = nil
    var volumeCreationName: String? = nil
    var originalSourceMountFlags: UInt32? = nil
    /// A snapshot of the actual proven partial candidate, saved before removal.
    var preparationRemovalBaseline: Data? = nil
    var preparationRemovalParentIdentity: DataPathIdentity? = nil
    /// Preserve the effective legacy root owner without rewriting the retained source manifest.
    var legacyRootOwnership: TreeCopySnapshot.Ownership? = nil
    /// Original noowners flags; absent if the source already uses owners or is restored offline.
    var legacyMountFlags: UInt32? = nil
    /// Identity of our private empty mount point, recorded before the mount attempt.
    var recoveryMountPointIdentity: DataPathIdentity? = nil
    /// Persisted after the retained copy is verified and before deletion. Its
    /// parent identity distinguishes an already deleted copy from an offline
    /// disk or a replacement directory when cleanup resumes after a restart.
    var cleanupParentIdentity: DataPathIdentity? = nil
    /// An absent APFS volume counts as deleted only while this exact container
    /// is online and its complete volume list confirms the UUID is absent.
    var cleanupVolumeContainerUUID: String? = nil
    /// Written only after this retained copy was physically removed and the
    /// deletion synchronized. A later location may still need this small
    /// identity link while an older, unrelated copy is offline.
    var retainedCopyRemovedAt: Date? = nil
    enum CleanupDisposition: String, Codable, Sendable { case deferred, keep }
    /// A user decision, not proof that any data was deleted. Keep the identity
    /// chain and manifests so a later explicit retry is still fully verified.
    var cleanupDisposition: CleanupDisposition? = nil

    var retryFailureCount: Int? = nil
    var nextAutomaticRetryAt: Date? = nil

    var needsAutomaticCompletion: Bool { cleanupDisposition == nil }
    var needsAttention: Bool { retainedCopyRemovedAt == nil && cleanupDisposition != .keep }

    /// Preserve the exact proposed mount across a verified switch interruption.
    /// It is never reconstructed from a volume name or a current mount path.
    var recoveryMountRecord: ContainerMountRecord? = nil
    /// The original usable entry has been restored. The full record remains
    /// until automatic cleanup of this attempt's candidate has also finished.
    var rollbackCompletedAt: Date? = nil
    /// New mount migrations save false at creation and true BEFORE attempting
    /// to mount the candidate at the application entry. Nil is legacy/unknown.
    var candidateActivationAttempted: Bool? = nil
    /// Cleanup may recreate a private placeholder removed after verification.
    /// Keep this claim separate from the immutable preparation placeholder.
    var candidateRemovalMountPointIdentity: DataPathIdentity? = nil
    var recoverableReason: String?

    init(operationID: UUID = UUID(), mode: Mode, direction: Direction, sourceID: String? = nil,
         appName: String, bundleIdentifier: String? = nil, dataDirType: String,
         originalPath: String, activePath: String, destinationPath: String,
         backupPath: String? = nil, stagingPath: String? = nil,
         sourceIdentity: DataPathIdentity, destinationIdentity: DataPathIdentity? = nil,
         destinationVolumeUUID: String? = nil,
         backupIdentity: DataPathIdentity? = nil, createdVolumeUUID: String? = nil,
         priorOperationID: UUID? = nil, createdAt: Date = Date(), policyVersion: Int = 1,
         phase: Phase = .preparing, baseline: Data? = nil, recoverableReason: String? = nil) {
        self.operationID = operationID
        self.mode = mode
        self.direction = direction
        self.sourceID = sourceID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.dataDirType = dataDirType
        self.originalPath = originalPath
        self.activePath = activePath
        self.destinationPath = destinationPath
        self.backupPath = backupPath
        self.stagingPath = stagingPath
        self.sourceIdentity = sourceIdentity
        self.destinationIdentity = destinationIdentity
        self.destinationVolumeUUID = destinationVolumeUUID
        self.backupIdentity = backupIdentity
        self.createdVolumeUUID = createdVolumeUUID
        self.priorOperationID = priorOperationID
        self.createdAt = createdAt
        self.policyVersion = policyVersion
        self.phase = phase
        self.baseline = baseline
        self.recoverableReason = recoverableReason
    }

    var isUnstartedMountRestore: Bool {
        mode == .mount && direction == .restore && [.preparing, .needsRecovery].contains(phase)
            && (sourceIdentity.isVolumeOnly || sourceIdentity.isResolved) && destinationIdentity == nil && backupIdentity == nil
            && baseline == nil && createdVolumeUUID == nil
            && activePath == originalPath && destinationPath == originalPath
            && backupPath != nil && stagingPath != nil
    }

    /// Display candidate only; services prove the source is still authoritative
    /// before restarting or cancelling any claimed/unknown preparation.
    var isPreparationRecoverable: Bool {
        !isDataSwitchComplete && rollbackCompletedAt == nil && baseline == nil
            && [.preparing, .copying, .needsRecovery].contains(phase)
    }

    /// This is historical evidence, not deletion authority. The caller must
    /// still prove live source, exclusive ownership, identities and no writers.
    var hasNeverActivatedMigrationCandidate: Bool {
        guard mode == .mount, direction == .migrate, !isDataSwitchComplete,
              retainedCopyRemovedAt == nil else { return false }
        if let candidateActivationAttempted { return !candidateActivationAttempted }
        // Schema 7–11 writers durably saved the completed baseline before
        // activation and never cleared it on failure. A source manifest alone
        // is preparation evidence, not a completed verification.
        return baseline == nil && sourceBaseline != nil && backupIdentity == nil
            && [.preparing, .copying, .needsRecovery].contains(phase)
    }

    var materialPaths: [String] {
        guard retainedCopyRemovedAt == nil else { return [] }
        return Array(Set([preparationPath, stagingPath, backupPath,
                   destinationPath == originalPath ? nil : destinationPath].compactMap { $0 })).sorted()
    }

    /// Cleanup errors do not undo the committed data switch.
    var isDataSwitchComplete: Bool {
        [.awaitingUserVerification, .cleanupRequested].contains(phase)
    }

    /// The prior location must supply this operation's actual source identity.
    /// Only an unstarted mount restore may defer its inode inspection. A new
    /// migration after restore always requires the resolved local object.
    func followsLocation(of prior: DataTransferRecord) -> Bool {
        guard priorOperationID == prior.operationID,
              originalPath == prior.originalPath, let identity = prior.destinationIdentity,
              prior.isDataSwitchComplete
                || prior.direction == .migrate && prior.phase == .needsRecovery && prior.baseline != nil else { return false }
        if prior.direction == .restore {
            guard direction == .migrate, prior.isDataSwitchComplete,
                  prior.activePath == prior.originalPath, prior.destinationPath == prior.originalPath else { return false }
        } else if mode != prior.mode || direction != .restore && mode != .symlink { return false }
        return identity.matchesFilesystemObject(sourceIdentity)
            || mode == .mount && direction == .restore && sourceIdentity.isVolumeOnly
                && [.preparing, .needsRecovery].contains(phase)
                && identity.volumeUUID?.caseInsensitiveCompare(sourceIdentity.volumeUUID ?? "") == .orderedSame
    }

    /// A UI candidate; resuming still verifies the ledger, both copies and the
    /// actual entry before continuing the existing operation.
    var isVerifiedSwitchRecoverable: Bool {
        [.verified, .switching, .needsRecovery].contains(phase)
            && rollbackCompletedAt == nil && preparationRemovalBaseline == nil
            && baseline != nil && destinationIdentity != nil && cleanupParentIdentity == nil
            && backupPath != nil && sourceIdentity.isResolved
            && (mode == .symlink || direction == .restore || recoveryMountRecord != nil)
    }

    var isUnstartedSymlinkRestore: Bool {
        guard mode == .symlink, direction == .restore,
              [.preparing, .copying, .needsRecovery].contains(phase),
              sourceIdentity.isResolved, backupIdentity == sourceIdentity,
              destinationIdentity == nil, baseline == nil, cleanupParentIdentity == nil,
              destinationVolumeUUID == nil, createdVolumeUUID == nil,
              legacyRootOwnership == nil, legacyMountFlags == nil, recoveryMountPointIdentity == nil,
              activePath == backupPath, destinationPath == originalPath,
              let backupPath, backupPath != originalPath else { return false }
        let original = URL(fileURLWithPath: originalPath).standardizedFileURL
        return originalPath == original.path && stagingPath == original.deletingLastPathComponent()
            .appendingPathComponent(".appports-restore-\(operationID)").path
    }

    /// A display candidate only. Execution must also prove that the original
    /// entry has the same identity and no copy, backup or related operation exists.
    var isUnstartedSymlinkMigration: Bool {
        guard mode == .symlink, direction == .migrate,
              [.preparing, .copying, .needsRecovery].contains(phase),
              sourceIdentity.isResolved,
              activePath == originalPath, destinationPath != originalPath,
              destinationIdentity == nil, backupIdentity == nil, baseline == nil,
              createdVolumeUUID == nil, stagingPath == nil,
              legacyRootOwnership == nil, legacyMountFlags == nil,
              recoveryMountPointIdentity == nil, cleanupParentIdentity == nil else { return false }
        let original = URL(fileURLWithPath: originalPath).standardizedFileURL
        let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let expectedBackup = original.deletingLastPathComponent()
            .appendingPathComponent(".appports-migration-backup-\(original.lastPathComponent)-\(operationID)")
        return originalPath == original.path && destinationPath == destination.path
            && destination.lastPathComponent == original.lastPathComponent
            && backupPath == expectedBackup.path
    }

    var topologyEntries: [DataPathTopology.Entry] {
        let origin: DataPathTopology.Origin = isDataSwitchComplete ? .retained : .transfer
        if rollbackCompletedAt != nil {
            // The source is usable again. Only this attempt's private candidate
            // remains reserved; it must not block a later operation at the source.
            return Array(Set([stagingPath, preparationPath].compactMap { $0 })).map {
                .init(path: $0, origin: .retained, operationID: operationID, volumeUUID: createdVolumeUUID)
            }
        }
        if retainedCopyRemovedAt != nil {
            // Historical destinations are no longer reserved by an identity
            // link. Their surviving physical copies or live index own those
            // paths independently until their actual cleanup completes.
            return [.init(path: originalPath, origin: origin, operationID: operationID)]
        }
        var paths = [originalPath, activePath, destinationPath, backupPath, stagingPath].compactMap { $0 }
        // A staging wrapper already reserves every descendant. Treating its
        // own data child as a second root makes recovery conflict with itself
        // when it verifies that exact wrapper. Separate private candidates
        // still need their own reservation (migration and normalization).
        if let preparationPath {
            let coveredByStaging = stagingPath.map {
                let relation = DataPathTopology.relationship($0, preparationPath)
                return relation == .same || relation == .ancestor
            } ?? false
            if !coveredByStaging { paths.append(preparationPath) }
        }
        return paths.map {
            .init(path: $0, origin: origin, operationID: operationID, volumeUUID: createdVolumeUUID)
        }
    }
}

/// Internal material retained after an interrupted operation. Keep the original
/// journal so maintenance can distinguish an owned, never-activated staging
/// directory from unclaimed material; a summary alone cannot authorize deletion.
struct DataTransferMaterial: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let appName: String
    let mode: DataTransferRecord.Mode
    let direction: DataTransferRecord.Direction
    let originalPath: String
    let paths: [String]
    let volumeUUID: String?
    let volumeName: String?
    let containerUUID: String?
    let reason: String
    let createdAt: Date
    var recoveryRecord: DataTransferRecord? = nil

    var retryFailureCount: Int? = nil
    var nextAutomaticRetryAt: Date? = nil

    init(transfer: DataTransferRecord, reason: String, additionalPaths: [String] = []) {
        id = transfer.operationID
        appName = transfer.appName
        mode = transfer.mode
        direction = transfer.direction
        originalPath = transfer.originalPath
        paths = Array(Set(transfer.materialPaths + additionalPaths)).sorted()
        volumeUUID = transfer.createdVolumeUUID
        volumeName = transfer.volumeCreationName ?? transfer.recoveryMountRecord?.volumeName
        containerUUID = transfer.volumeCreationContainerUUID
        self.reason = reason
        createdAt = transfer.createdAt
        recoveryRecord = transfer
        retryFailureCount = transfer.retryFailureCount
        nextAutomaticRetryAt = transfer.nextAutomaticRetryAt
    }

    /// A detached index preserves its external location without authorizing cleanup.
    init(detachedLink link: ManagedDataLinkRecord, reason: String) {
        id = link.operationID
        appName = link.appName
        mode = .symlink
        direction = .migrate
        originalPath = link.originalPath
        paths = [link.destinationPath]
        volumeUUID = nil
        volumeName = nil
        containerUUID = nil
        self.reason = reason
        createdAt = link.createdAt
    }

    /// The live mount continues to own its volume. Only separate paths from an
    /// old cleanup become historical material when that cleanup is superseded.
    init(legacyCleanup: ContainerCleanupRecord, retainingDetachedVolume: Bool = false) {
        id = legacyCleanup.id
        appName = legacyCleanup.mountRecord.appName
        mode = .mount
        direction = legacyCleanup.kind == .migrationBackup ? .migrate : .restore
        originalPath = legacyCleanup.mountRecord.mountPointPath
        paths = [legacyCleanup.localPath, legacyCleanup.restoreStagingPath].compactMap { $0 }
            .filter { DataPathTopology.relationship($0, legacyCleanup.mountRecord.mountPointPath) != .same }
        volumeUUID = retainingDetachedVolume ? legacyCleanup.mountRecord.volumeUUID : nil
        volumeName = retainingDetachedVolume ? legacyCleanup.mountRecord.volumeName : nil
        containerUUID = nil
        reason = retainingDetachedVolume
            ? "数据已还原。旧版记录缺少可验证的清理凭据，AppPorts 暂时保留旧卷，不影响继续使用或迁移。".localized
            : "旧清理记录已接续到当前还原；这些额外位置仍保留，未删除其中的文件。".localized
        createdAt = legacyCleanup.mountRecord.createdAt
    }
}
