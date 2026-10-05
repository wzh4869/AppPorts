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
    var backupIdentity: DataPathIdentity?
    var createdVolumeUUID: String?
    /// A restore can reference its earlier successful migration without discarding that migration's retained original.
    let priorOperationID: UUID?
    let createdAt: Date
    let policyVersion: Int
    var phase: Phase
    var baseline: Data?
    /// Preserve the effective legacy root owner without rewriting the retained source manifest.
    var legacyRootOwnership: TreeCopySnapshot.Ownership? = nil
    /// Original noowners flags; absent if the source already uses owners or is restored offline.
    var legacyMountFlags: UInt32? = nil
    /// Identity of our private empty mount point, recorded before the mount attempt.
    var recoveryMountPointIdentity: DataPathIdentity? = nil
    var recoverableReason: String?

    init(operationID: UUID = UUID(), mode: Mode, direction: Direction, sourceID: String? = nil,
         appName: String, bundleIdentifier: String? = nil, dataDirType: String,
         originalPath: String, activePath: String, destinationPath: String,
         backupPath: String? = nil, stagingPath: String? = nil,
         sourceIdentity: DataPathIdentity, destinationIdentity: DataPathIdentity? = nil,
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
            && sourceIdentity.isVolumeOnly && destinationIdentity == nil && backupIdentity == nil
            && baseline == nil && createdVolumeUUID == nil
            && activePath == originalPath && destinationPath == originalPath
            && backupPath != nil && stagingPath != nil
    }

    var topologyEntries: [DataPathTopology.Entry] {
        let origin: DataPathTopology.Origin = [.awaitingUserVerification, .cleanupRequested].contains(phase) ? .retained : .transfer
        return [originalPath, activePath, destinationPath, backupPath, stagingPath].compactMap { $0 }.map {
            .init(path: $0, origin: origin, operationID: operationID, volumeUUID: createdVolumeUUID)
        }
    }
}
