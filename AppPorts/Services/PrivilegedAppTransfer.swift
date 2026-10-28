import AppKit
import Darwin
import Foundation

/// A one-shot administrator operation, not an elevated GUI or a persistent helper.
/// The ordinary process keeps its operation lock and owns all journal writes.
enum PrivilegedAppTransfer {
    static let argument = "--privileged-app-transfer"

    struct Request: Codable {
        enum Action: String, Codable { case exchange, remove }
        let action: Action
        let record: AppTransferRecord
        let sourceBaseline: AppTransferBaseline
        var candidateBaseline: AppTransferBaseline?
        var portalBaseline: AppTransferBaseline?
        var cleanupItem: AppTransferCleanupItem?
        var contentFingerprints: [String: String] = [:]

        func preparedForAuthorization() throws -> Self {
            var request = self
            for url in try verificationRoots() {
                request.contentFingerprints[url.path] = try SignatureSnapshot.fingerprint(of: url)
            }
            return request
        }

        func verificationRoots() throws -> [URL] {
            guard let portal = record.stagedPortalURL else { throw CocoaError(.fileReadCorruptFile) }
            if action == .exchange {
                return [URL(fileURLWithPath: record.sourcePath), URL(fileURLWithPath: record.destinationPath), portal]
            }
            guard let item = cleanupItem,
                  let retained = try TreeCopySession.retainedRemovalURL(at: portal, removalID: item.id) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return [retained]
        }
    }

    static func authorize(_ request: Request) throws {
        try authorize(request, argument: argument)
    }

    static func authorize<T: Encodable>(_ request: T, argument: String) throws {
        guard let executable = Bundle.main.executableURL else { throw CocoaError(.executableNotLoadable) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppPorts-authorization-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("request.plist")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(request)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let result: ShellCommandResult
        do {
            result = try DiskUtility.runWithAdministratorPrivileges(executable: executable.path,
                arguments: [argument, url.path, String(getuid())])
        } catch DiskUtility.Failure.administratorPromptCancelled {
            throw CancellationError()
        }
        guard result.status == 0 else {
            throw NSError(domain: "AppPorts.AdministratorTransfer", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: String(data: result.standardError, encoding: .utf8) ?? ""])
        }
    }

    /// Executed before SwiftUI, user defaults, writer registration or login agents initialize.
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == argument else { return false }
        do {
            try perform(readRequest(Request.self, arguments: args))
            return true
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func readRequest<T: Decodable>(_ type: T.Type, arguments: [String]) throws -> T {
        guard geteuid() == 0, arguments.count == 4, let owner = uid_t(arguments[3]), owner != 0 else {
            throw POSIXError(.EPERM)
        }
        let fd = open(arguments[2], O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == owner, info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 256 * 1024 * 1024 else { throw POSIXError(.EPERM) }
        return try PropertyListDecoder().decode(type, from: handle.readToEnd() ?? Data())
    }

    /// Internal for isolated fixtures. The command-line entry above always requires root.
    static func perform(_ request: Request) throws {
        let record = request.record
        let source = URL(fileURLWithPath: record.sourcePath)
        let destination = URL(fileURLWithPath: record.destinationPath)
        let parent = source.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".appports-entry-" + record.operationID.uuidString)
        guard record.direction == .migrate, record.switchIntentRecorded, record.hasCandidateBaseline,
              record.portalStagePath == stage.path, let portal = record.stagedPortalURL,
              let portalIdentity = record.portalIdentity, let stageIdentity = record.portalStageIdentity,
              let candidateIdentity = record.candidateIdentity,
              source.standardizedFileURL.path == source.path,
              destination.standardizedFileURL.path == destination.path,
              parent.resolvingSymlinksInPath().path == parent.path,
              destination.deletingLastPathComponent().resolvingSymlinksInPath().path == destination.deletingLastPathComponent().path,
              source != destination, source != stage,
              !destination.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(destination.path + "/") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try require(record.sourceParentIdentity, at: parent)
        try require(record.destinationParentIdentity, at: destination.deletingLastPathComponent())
        try require(stageIdentity, at: stage)
        try require(candidateIdentity, at: destination)
        // The app-bundle profile deliberately omits per-file digests. Bind the
        // password-prompt window to full fingerprints rather than weakening it
        // to file sizes or merely re-adopting whatever is present afterwards.
        let roots = try request.verificationRoots()
        guard Set(request.contentFingerprints.keys) == Set(roots.map(\.path)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for root in roots {
            guard try SignatureSnapshot.fingerprint(of: root) == request.contentFingerprints[root.path] else {
                throw TreeCopyError.sourceChanged(root.path)
            }
        }
        switch request.action {
        case .exchange:
            guard !record.isSwitchComplete, let candidate = request.candidateBaseline,
                  let portalBaseline = request.portalBaseline else { throw CocoaError(.fileReadCorruptFile) }
            try require(record.sourceIdentity, at: source)
            try require(portalIdentity, at: portal)
            try verify(request.sourceBaseline, at: source)
            try verify(candidate, at: destination)
            try verify(portalBaseline, at: portal)
            for (relative, wasValid) in record.signatureChecks where wasValid {
                guard relative.isEmpty || relative.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                for root in [source, destination] {
                    let app = relative.isEmpty ? root : root.appendingPathComponent(relative)
                    guard try AppTransferTransaction.signatureIsValid(at: app) else {
                        throw TreeCopyError.verificationFailed(app.path)
                    }
                }
            }
            try requireNotRunning(record, roots: [source, destination])
            // Recheck object identities after the potentially long verification and password prompt.
            try require(record.sourceIdentity, at: source)
            try require(portalIdentity, at: portal)
            try require(record.sourceParentIdentity, at: parent)
            try require(stageIdentity, at: stage)
            // Keep parent directories open without following a substituted stage
            // symlink. Administrator privileges must not turn a path race into
            // an exchange in an unrelated directory.
            let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parentFD >= 0 else { throw POSIXError(.EACCES) }
            defer { close(parentFD) }
            let stageFD = openat(parentFD, stage.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard stageFD >= 0 else { throw POSIXError(.EACCES) }
            defer { close(stageFD) }
            try requireDescriptor(parentFD, identity: record.sourceParentIdentity, at: parent)
            try requireDescriptor(stageFD, identity: stageIdentity, at: stage)
            var original = stat(), entry = stat()
            guard fstatat(parentFD, source.lastPathComponent, &original, AT_SYMLINK_NOFOLLOW) == 0,
                  fstatat(stageFD, portal.lastPathComponent, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  UInt64(original.st_ino) == record.sourceIdentity.inode,
                  UInt64(entry.st_ino) == portalIdentity.inode else { throw TreeCopyError.sourceChanged(source.path) }
            guard renameatx_np(parentFD, source.lastPathComponent, stageFD, portal.lastPathComponent,
                               UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard fsync(parentFD) == 0, fsync(stageFD) == 0 else { throw POSIXError(.EIO) }
            try DurableFileIO.syncDirectory(at: parent)
            try DurableFileIO.syncDirectory(at: stage)
        case .remove:
            guard record.isSwitchComplete, record.signatureFactsCommitted,
                  let item = request.cleanupItem, item.role == .source,
                  item.path == portal.path, item.originalPath == source.path,
                  item.identity.matchesFilesystemObject(record.sourceIdentity), item.deletionStarted,
                  record.cleanupItems.contains(where: { $0.id == item.id && $0.path == item.path && $0.deletionStarted }),
                  let tree = request.sourceBaseline.tree else { throw CocoaError(.fileReadCorruptFile) }
            try require(portalIdentity, at: source)
            try require(item.parentIdentity, at: stage)
            guard let retained = try TreeCopySession.retainedRemovalURL(at: portal, removalID: item.id) else { return }
            try require(item.identity, at: retained)
            try requireNotRunning(record, roots: [source, retained])
            // Reuse the exact checkpointed, identity-checked remover, including partial deletions.
            try TreeCopySession.removeVerifiedCopy(at: portal, against: tree, allowPartialRemoval: true,
                expectedVolumeUUID: item.identity.volumeUUID, removalID: item.id, requireSourceIdentity: true,
                profile: .appBundle, willRemove: {
                    try require(candidateIdentity, at: destination)
                    try require(portalIdentity, at: source)
                    try require(record.sourceParentIdentity, at: parent)
                    try require(stageIdentity, at: stage)
                })
            try DurableFileIO.syncDirectory(at: stage)
        }
    }

    private static func require(_ identity: DataPathIdentity, at url: URL) throws {
        guard try identity.matchesFilesystemObject(DataPathIdentity.capture(url)) else {
            throw TreeCopyError.sourceChanged(url.path)
        }
    }

    private static func requireDescriptor(_ fd: Int32, identity: DataPathIdentity, at url: URL) throws {
        try require(identity, at: url)
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, lstat(url.path, &named) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              opened.st_mode & S_IFMT == S_IFDIR else { throw TreeCopyError.sourceChanged(url.path) }
    }

    private static func verify(_ baseline: AppTransferBaseline, at url: URL) throws {
        if let tree = baseline.tree {
            if let uuid = baseline.volumeUUID {
                try TreeCopySession.verifyUnchanged(at: url, against: tree, expectedVolumeUUID: uuid, profile: .appBundle)
            } else { try TreeCopySession.verifyUnchanged(at: url, against: tree, profile: .appBundle) }
        } else if let identity = baseline.linkIdentity, let target = baseline.linkTarget {
            try require(identity, at: url)
            guard try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target else {
                throw TreeCopyError.sourceChanged(url.path)
            }
        } else { throw CocoaError(.fileReadCorruptFile) }
    }

    private static func requireNotRunning(_ record: AppTransferRecord, roots: [URL]) throws {
        let applications = NSWorkspace.shared.runningApplications.map {
            AppRunningState.RunningApplication(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
        }
        for root in roots {
            for relative in record.applicationPaths {
                guard relative.isEmpty || relative.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let app = relative.isEmpty ? root : root.appendingPathComponent(relative)
                if AppRunningState.isRunning(appURL: app, applications: applications) { throw AppMoverError.appIsRunning }
            }
        }
    }
}

@main
enum AppPortsEntryPoint {
    static func main() {
        if PrivilegedAppTransfer.runIfRequested() { return }
        if PrivilegedDataCleanup.runIfRequested() { return }
        AppMoverApp.main()
    }
}
