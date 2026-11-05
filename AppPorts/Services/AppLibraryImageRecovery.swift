import Foundation
import NetFS

/// Shared by the foreground controller and the windowless login agent.
enum AppLibraryImageRecovery {
    static let networkMountArgument = "--mount-library-share"

    static func loadRecord(defaults: UserDefaults = .standard) -> AppLibraryImageService.Record? {
        defaults.synchronize()
        guard let data = defaults.data(forKey: AppLibraryImageService.preferenceKey),
              let record = try? JSONDecoder().decode(AppLibraryImageService.Record.self, from: data) else { return nil }
        return record
    }

    static func selectedRecord(defaults: UserDefaults = .standard) -> AppLibraryImageService.Record? {
        guard let record = loadRecord(defaults: defaults),
              defaults.string(forKey: "ExternalDrivePath") == (record.libraryPath ?? record.mountPath) else { return nil }
        return record
    }

    /// Retain the account name for system credential lookup, never the password.
    static func sanitizedShareURL(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "smb", let host = parts.host, !host.isEmpty,
              url.pathComponents.filter({ $0 != "/" }).count == 1 else { return nil }
        parts.scheme = "smb"
        parts.host = host.lowercased()
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    static func captureStorageLocation(_ record: AppLibraryImageService.Record) -> AppLibraryImageService.Record {
        // Once captured, identity must never be replaced by a different disk
        // reusing the same /Volumes path.
        guard record.networkShareURL == nil, record.backingVolumeUUID == nil else { return record }
        let image = URL(fileURLWithPath: record.imagePath)
        guard let values = try? image.resourceValues(forKeys: [.volumeURLKey, .volumeURLForRemountingKey,
                .volumeUUIDStringKey, .volumeIsLocalKey, .volumeIsInternalKey]),
              let root = values.volume,
              let relative = relativeImagePath(image: image, root: root) else { return record }
        var updated = record
        if let remote = values.volumeURLForRemounting, let share = sanitizedShareURL(remote) {
            updated.networkShareURL = share.absoluteString
            updated.imageRelativePath = relative
        } else if values.volumeIsLocal == true, values.volumeIsInternal == false,
                  let uuid = values.volumeUUIDString, !uuid.isEmpty {
            updated.backingVolumeUUID = uuid
            updated.imageRelativePath = relative
        }
        return updated
    }

    /// Resolve the containing disk independently of the APFS volume inside the image.
    /// Never fall back to the old path when another disk has taken its name.
    static func resolveLocalImage(
        _ record: AppLibraryImageService.Record,
        mountedVolumes: [URL]? = nil,
        volumeUUID: (URL) -> String? = { DiskUtility.mountedVolumeUUID(at: $0) }
    ) throws -> AppLibraryImageService.Record {
        guard let uuid = record.backingVolumeUUID else { return record }
        guard !uuid.isEmpty, record.networkShareURL == nil,
              let relative = record.imageRelativePath, validRelativePath(relative) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let volumes = mountedVolumes ?? FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
        let matches = volumes.filter { volumeUUID($0)?.caseInsensitiveCompare(uuid) == .orderedSame }
        guard matches.count == 1 else { throw CocoaError(.fileNoSuchFile) }
        var updated = record
        updated.imagePath = matches[0].appendingPathComponent(relative).path
        return updated
    }

    static func relativeImagePath(image: URL, root: URL) -> String? {
        let prefix = root.standardizedFileURL.path + "/"
        guard image.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
        let path = String(image.standardizedFileURL.path.dropFirst(prefix.count))
        guard validRelativePath(path) else { return nil }
        return path
    }

    static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && (path as NSString).pathExtension.lowercased() == "sparsebundle"
    }

    static func matchingShare(_ remote: URL, expected: URL) -> Bool {
        guard let lhs = sanitizedShareURL(remote), let rhs = sanitizedShareURL(expected) else { return false }
        return lhs == rhs
    }

    static func mountedShare(for remote: URL) -> URL? {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey])?
            .first { root in
                guard let value = try? root.resourceValues(forKeys: [.volumeURLForRemountingKey]),
                      let url = value.volumeURLForRemounting else { return false }
                return matchingShare(url, expected: remote)
            }
    }

    /// Caller holds OperationLock. Failure retains the selected record for the next launchd tick.
    static func recoverSelected(
        defaults: UserDefaults = .standard,
        service: AppLibraryImageService = AppLibraryImageService(),
        runner: any ShellCommandRunning = ProcessCommandRunner(),
        ejection: DiskEjectionPauseStore.Snapshot = .init(pauses: []),
        findShare: ((URL) async throws -> URL?)? = nil,
        connect: (URL) async throws -> Void = { try await connectShare($0) }
    ) async {
        guard let original = selectedRecord(defaults: defaults) else { return }
        var record = original
        let expectedRecord = original
        do {
            guard !ejection.blocks(volumeUUIDs: [record.backingVolumeUUID], paths: [record.imagePath]) else { return }
            let shareLocation = findShare ?? { try await service.files.mountedShare(for: $0) }
            if let address = record.networkShareURL, let remote = URL(string: address),
               sanitizedShareURL(remote)?.absoluteString == address,
               let relative = record.imageRelativePath, validRelativePath(relative) {
                var root = try await shareLocation(remote)
                if root == nil {
                    try await connect(remote)
                    root = try await shareLocation(remote)
                }
                guard let root else { throw CocoaError(.fileNoSuchFile) }
                record.imagePath = root.appendingPathComponent(relative).path
            }
            // Restore backing storage before querying an APFS device that may
            // be blocked waiting on that storage.
            let point = URL(fileURLWithPath: record.libraryPath ?? record.mountPath)
            let actualUUID = try await service.currentMountedUUID(at: point)
            let alreadyMounted = record.volumeUUID.map { actualUUID?.caseInsensitiveCompare($0) == .orderedSame } ?? false
            if alreadyMounted, record.backingVolumeUUID != nil || record.networkShareURL != nil { return }
            record = try await service.files.resolved(record)
            guard !ejection.blocks(volumeUUIDs: [record.backingVolumeUUID], paths: [record.imagePath]) else { return }
            if record.imagePath != expectedRecord.imagePath {
                // Both USB and SMB may reappear at another /Volumes path.
                // An old device attachment must not become a second writer.
                let result = try await AppLibraryImageFileAccess.readCommand(runner: runner, executable: "/usr/bin/hdiutil",
                    arguments: ["info", "-plist"], timeout: 30)
                if result.runningProcess != nil { throw CocoaError(.fileReadUnknown) }
                guard result.status == 0, !result.timedOut, !result.outputWasTruncated,
                      try AppLibraryImageService.attachedVolumes(data: result.standardOutput,
                        image: URL(fileURLWithPath: expectedRecord.imagePath)) == nil else { throw CocoaError(.fileWriteFileExists) }
            }
            // Check selection again after connecting; another process may have changed it.
            guard selectedRecord(defaults: defaults) == expectedRecord else { return }
            // Existing portals refer to the previously selected library path.
            record.mountPath = original.libraryPath ?? original.mountPath
            let mounted = try await service.mount(record)
            guard mounted.libraryURL.path == (original.libraryPath ?? original.mountPath) else {
                throw CocoaError(.fileWriteFileExists)
            }
            guard selectedRecord(defaults: defaults) == expectedRecord else { return }
            try save(mounted.record, defaults: defaults)
        } catch let pending as ShellCommandUnconfirmedTermination {
            AppLogger.shared.log("后台应用库映像进程尚未退出，等待结束后释放操作锁", level: "WARN")
            // Keep the caller's cross-process lock until any writer actually exits.
            while (try? ProcessCommandRunner.isRunning(pending.process)) != false {
                await Task.detached { try? await Task.sleep(nanoseconds: 1_000_000_000) }.value
            }
        } catch {
            AppLogger.shared.logContext("后台应用库映像恢复未完成，稍后重试",
                details: [("error", error.localizedDescription)], level: "WARN")
        }
    }

    static func save(_ record: AppLibraryImageService.Record, defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(record), forKey: AppLibraryImageService.preferenceKey)
        defaults.synchronize()
    }

    /// Launch preparation is explicit to one image and does not change the selected library.
    static func restoreForLaunch(_ original: AppLibraryImageService.Record,
                                 service: AppLibraryImageService,
                                 ejection: DiskEjectionPauseStore.Snapshot) async throws -> AppLibraryImageService.Record {
        guard !ejection.blocks(volumeUUIDs: [original.backingVolumeUUID], paths: [original.imagePath]) else {
            throw DiskEjectionError.paused
        }
        var record = original
        if let address = record.networkShareURL {
            guard let remote = URL(string: address), sanitizedShareURL(remote)?.absoluteString == address,
                  let relative = record.imageRelativePath, validRelativePath(relative) else { throw CocoaError(.fileReadCorruptFile) }
            var root = try await service.files.mountedShare(for: remote)
            if root == nil {
                try await connectShare(remote)
                root = try await service.files.mountedShare(for: remote)
            }
            guard let root else { throw CocoaError(.fileNoSuchFile) }
            record.imagePath = root.appendingPathComponent(relative).path
        }
        record = try await service.files.resolved(record)
        guard !ejection.blocks(volumeUUIDs: [record.backingVolumeUUID], paths: [record.imagePath]) else { throw DiskEjectionError.paused }
        if record.imagePath != original.imagePath {
            let inventory = try await AppLibraryImageFileAccess.readCommand(runner: service.runner,
                executable: "/usr/bin/hdiutil", arguments: ["info", "-plist"], timeout: 10)
            guard inventory.status == 0, !inventory.timedOut, !inventory.outputWasTruncated,
                  try AppLibraryImageService.attachedVolumes(data: inventory.standardOutput,
                    image: URL(fileURLWithPath: original.imagePath)) == nil else { throw CocoaError(.fileWriteFileExists) }
        }
        let expected = original.libraryPath ?? original.mountPath
        if let uuid = original.volumeUUID,
           try await service.currentMountedUUID(at: URL(fileURLWithPath: expected))?.caseInsensitiveCompare(uuid) == .orderedSame {
            return record
        }
        let mounted = try await service.mount(record)
        guard mounted.libraryURL.path == expected else { throw CocoaError(.fileWriteFileExists) }
        return mounted.record
    }

    /// Read-only launch check: true only when `restoreForLaunch` would return
    /// without connecting, attaching or mounting. Storage that reappeared at
    /// another path still needs that method's attachment checks.
    static func isMountedForLaunch(_ record: AppLibraryImageService.Record,
                                   service: AppLibraryImageService,
                                   ejection: DiskEjectionPauseStore.Snapshot) async throws -> Bool {
        guard let uuid = record.volumeUUID,
              !ejection.blocks(volumeUUIDs: [record.backingVolumeUUID], paths: [record.imagePath]) else { return false }
        var current = record
        if let address = record.networkShareURL {
            guard let remote = URL(string: address), sanitizedShareURL(remote)?.absoluteString == address,
                  let relative = record.imageRelativePath, validRelativePath(relative),
                  let root = try await service.files.mountedShare(for: remote) else { return false }
            current.imagePath = root.appendingPathComponent(relative).path
        }
        guard try await service.files.resolved(current).imagePath == record.imagePath else { return false }
        let library = URL(fileURLWithPath: record.libraryPath ?? record.mountPath)
        return try await service.currentMountedUUID(at: library)?.caseInsensitiveCompare(uuid) == .orderedSame
    }

    private static func connectShare(_ remote: URL) async throws {
        guard let executable = Bundle.main.executableURL else { throw CocoaError(.executableNotLoadable) }
        let result = try await ProcessCommandRunner().run(executable: executable.path,
            arguments: [networkMountArgument, remote.absoluteString], timeout: 30)
        if let process = result.runningProcess { throw ShellCommandUnconfirmedTermination(process: process) }
        guard result.status == 0, !result.timedOut else { throw CocoaError(.fileReadUnknown) }
    }

    /// Separate bounded process: NetFS synchronous connection cannot block the agent indefinitely.
    static func runNetworkMountIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.dropFirst().first == networkMountArgument else { return }
        guard arguments.count == 3, let remote = URL(string: arguments[2]),
              sanitizedShareURL(remote) == remote else { exit(2) }
        let options = [kNAUIOptionKey as String: kNAUIOptionNoUI as String] as CFDictionary
        let mutableOptions = CFDictionaryCreateMutableCopy(nil, 0, options)
        var points: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(remote as CFURL, nil, nil, nil, mutableOptions, nil, &points)
        _ = points?.takeRetainedValue()
        exit(status == 0 ? 0 : 1)
    }
}
