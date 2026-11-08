import Foundation

/// Filesystem metadata on an offline SMB mount can block inside the kernel.
/// Run read-only queries in a bounded process; never abandon a mount writer.
struct AppLibraryImageFileAccess: Sendable {
    static let launchArgument = "--inspect-library-image"

    enum Request: Codable, Sendable {
        case capture(AppLibraryImageService.Record)
        case resolve(AppLibraryImageService.Record)
        case source(AppLibraryImageService.Record)
        case creationDirectory(String)
        case occupied(String)
        case mountedUUID(String)
        case share(String)
    }

    struct Reply: Codable, Sendable {
        var record: AppLibraryImageService.Record?
        var uuid: String?
        var path: String?
        var value: Bool?
    }

    var inspect: @Sendable (Request) async throws -> Reply = { try await AppLibraryImageFileAccess.query($0) }

    func captured(_ record: AppLibraryImageService.Record) async throws -> AppLibraryImageService.Record {
        if record.networkShareURL != nil || record.backingVolumeUUID != nil { return record }
        guard let result = try await inspect(.capture(record)).record else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    func resolved(_ record: AppLibraryImageService.Record) async throws -> AppLibraryImageService.Record {
        if record.backingVolumeUUID == nil { return record }
        guard let result = try await inspect(.resolve(record)).record else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    func mountedUUID(at url: URL) async throws -> String? {
        try await inspect(.mountedUUID(url.path)).uuid
    }

    func mountedShare(for remote: URL) async throws -> URL? {
        try await inspect(.share(remote.absoluteString)).path.map { URL(fileURLWithPath: $0) }
    }

    static func query(_ request: Request, runner: any ShellCommandRunning = ProcessCommandRunner(captureLimit: 64 * 1024),
                      executable: URL? = Bundle.main.executableURL) async throws -> Reply {
        guard let executable else { throw CocoaError(.executableNotLoadable) }
        let payload = try JSONEncoder().encode(request).base64EncodedString()
        let result = try await readCommand(runner: runner, executable: executable.path,
            arguments: [launchArgument, payload], timeout: 10)
        // An unconfirmed reader has no filesystem write side effects. Do not
        // turn a stuck metadata read into a permanently held operation lock.
        guard result.status == 0, !result.timedOut, result.runningProcess == nil,
              !result.outputWasTruncated else { throw CocoaError(.fileReadUnknown) }
        return try JSONDecoder().decode(Reply.self, from: result.standardOutput)
    }

    static func readCommand(runner: any ShellCommandRunning, executable: String,
                            arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        do {
            let result = try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
            guard result.runningProcess == nil else { throw CocoaError(.fileReadUnknown) }
            return result
        } catch is ShellCommandUnconfirmedTermination {
            // Cancellation can throw this instead of returning runningProcess.
            // A reader must never enter the caller's unfinished-writer wait loop.
            if Task.isCancelled { throw CancellationError() }
            throw CocoaError(.fileReadUnknown)
        }
    }

    /// Also usable with isolated fixture paths; production calls this only in the reader process.
    static func evaluate(_ request: Request) throws -> Reply {
        switch request {
        case .capture(let record):
            return Reply(record: AppLibraryImageRecovery.captureStorageLocation(record))
        case .resolve(let record):
            return Reply(record: try AppLibraryImageRecovery.resolveLocalImage(record))
        case .source(let record):
            let image = URL(fileURLWithPath: record.imagePath)
            try requireDirectory(image)
            let uuid = DiskUtility.mountedVolumeUUID(at: image)
            if let expected = record.backingVolumeUUID,
               uuid?.caseInsensitiveCompare(expected) != .orderedSame { throw CocoaError(.fileReadUnknown) }
            return Reply(uuid: uuid, value: true)
        case .creationDirectory(let path):
            let directory = URL(fileURLWithPath: path)
            try requireDirectory(directory)
            let properties = try directory.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
            let volume = DiskUtility.mountedVolumePath(containing: directory)
            return Reply(value: (properties.volumeIsInternal == false || properties.volumeIsLocal == false)
                && volume != nil && volume != "/"
                && (!path.hasPrefix("/Volumes/") || volume?.hasPrefix("/Volumes/") == true))
        case .occupied(let path):
            return Reply(value: FileManager.default.fileExists(atPath: path)
                || (try? FileManager.default.attributesOfItem(atPath: path)) != nil)
        case .mountedUUID(let path):
            let url = URL(fileURLWithPath: path)
            return Reply(uuid: DiskUtility.isMountPoint(url) ? DiskUtility.mountedVolumeUUID(at: url) : nil)
        case .share(let address):
            guard let remote = URL(string: address) else { throw CocoaError(.fileReadCorruptFile) }
            return Reply(path: AppLibraryImageRecovery.mountedShare(for: remote)?.path)
        }
    }

    private static func requireDirectory(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().first == launchArgument else { return }
        do {
            guard CommandLine.arguments.count == 3,
                  let data = Data(base64Encoded: CommandLine.arguments[2]), data.count <= 32 * 1024 else { exit(2) }
            let request = try JSONDecoder().decode(Request.self, from: data)
            let response = try JSONEncoder().encode(evaluate(request))
            try FileHandle.standardOutput.write(contentsOf: response)
            exit(0)
        } catch {
            AppLogger.shared.logContext("应用库映像只读检查失败", details: [("error", error.localizedDescription)], level: "WARN")
            exit(1)
        }
    }
}
