import Darwin
import Foundation

enum PrivilegedDataCleanup {
    static let argument = "--privileged-data-cleanup"

    struct Request: Codable, Sendable {
        let transfer: DataTransferRecord
        let currentLocation: DataTransferRecord
    }

    static func authorize(_ request: Request) throws {
        try PrivilegedAppTransfer.authorize(request, argument: argument)
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == argument else { return false }
        do {
            try perform(PrivilegedAppTransfer.readRequest(Request.self, arguments: args))
            return true
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    // The command-line entry requires root; tests use this same remover on isolated files.
    static func perform(_ request: Request) throws {
        let context = try validatedContext(request)
        try TreeCopySession.removeVerifiedCopy(at: context.retained, against: context.baseline,
            allowPartialRemoval: true, expectedVolumeUUID: request.transfer.backupIdentity?.volumeUUID,
            removalID: request.transfer.operationID, requireSourceIdentity: true, willRemove: {
                try requireCurrentLocation(request.currentLocation)
                try require(request.transfer.cleanupParentIdentity, at: context.retained.deletingLastPathComponent())
            })
        try DurableFileIO.syncDirectory(at: context.retained.deletingLastPathComponent())
    }

    private static func validatedContext(_ request: Request) throws -> (retained: URL, baseline: TreeCopySnapshot) {
        let transfer = request.transfer
        guard transfer.mode == .symlink, transfer.isDataSwitchComplete, transfer.phase == .cleanupRequested,
              transfer.retainedCopyRemovedAt == nil, transfer.cleanupParentIdentity != nil,
              request.currentLocation.originalPath == transfer.originalPath,
              let path = transfer.backupPath, let baseline = transfer.baseline else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let retained = URL(fileURLWithPath: path)
        let active = URL(fileURLWithPath: request.currentLocation.activePath)
        guard !DataPathTopology.overlaps(DataPathTopology.relationship(retained.path, active.path)),
              !DiskUtility.isMountPoint(retained),
              let actual = try TreeCopySession.retainedRemovalURL(at: retained, removalID: transfer.operationID) else {
            throw TreeCopyError.unsafeLayout(path)
        }
        try require(transfer.cleanupParentIdentity, at: retained.deletingLastPathComponent())
        try require(transfer.backupIdentity, at: actual)
        try requireCurrentLocation(request.currentLocation)
        return (retained, try PropertyListDecoder().decode(TreeCopySnapshot.self, from: baseline))
    }

    private static func requireCurrentLocation(_ current: DataTransferRecord) throws {
        guard current.isDataSwitchComplete else { throw CocoaError(.fileReadCorruptFile) }
        let active = URL(fileURLWithPath: current.activePath)
        var info = stat()
        guard lstat(active.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw TreeCopyError.sourceChanged(active.path)
        }
        try require(current.destinationIdentity, at: active)
        if current.mode == .mount, current.direction == .migrate {
            guard let uuid = current.createdVolumeUUID,
                  DiskUtility.mountedVolumeUUID(at: active)?.caseInsensitiveCompare(uuid) == .orderedSame else {
                throw TreeCopyError.sourceChanged(active.path)
            }
        }
    }

    private static func require(_ identity: DataPathIdentity?, at url: URL) throws {
        guard let identity, try identity.matchesFilesystemObject(DataPathIdentity.capture(url)) else {
            throw TreeCopyError.sourceChanged(url.path)
        }
    }
}
