import Foundation

/// Images are explicit application-library destinations, not physical disks or
/// container-migration records. Never delete or repair an image on failure.
struct AppLibraryImageService: Sendable {
    struct Record: Codable, Equatable, Sendable {
        var imagePath: String
        var mountPath: String
        var volumeUUID: String?
        var libraryPath: String?
        var networkShareURL: String?
        var imageRelativePath: String?
        var backingVolumeUUID: String?

        init(imageURL: URL) {
            imagePath = imageURL.standardizedFileURL.path
            mountPath = "/Volumes/" + imageURL.deletingPathExtension().lastPathComponent
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var runner: any ShellCommandRunning = ProcessCommandRunner(captureLimit: 4 * 1024 * 1024)
    var mountedUUID: (@Sendable (URL) -> String?)? = nil
    var files = AppLibraryImageFileAccess()
    static let preferenceKey = "AppLibraryImageRecord"

    static func validate(name: String, capacityGiB: Int) throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name != ".", name != "..", name.utf8.count <= 100,
              !name.contains(where: { $0 == "/" || $0 == ":" || $0.isNewline || $0 == "\0" }),
              (1...65536).contains(capacityGiB) else {
            throw Failure(message: "请输入有效的磁盘名称和 1–65536 GiB 的最大容量。".localized)
        }
    }

    func create(in directory: URL, name: String, capacityGiB: Int) async throws -> Record {
        try Self.validate(name: name, capacityGiB: capacityGiB)
        // Require an online external filesystem without blocking this process on NAS metadata.
        guard try await files.inspect(.creationDirectory(directory.path)).value == true else {
            throw Failure(message: "请选择已挂载的外部存储或 SMB 共享目录。".localized)
        }
        let image = directory.appendingPathComponent(name + ".sparsebundle", isDirectory: true)
        guard try await files.inspect(.occupied(image.path)).value == false else {
            throw Failure(message: "该位置已有同名文件，请更换名称或打开已有映像。".localized)
        }
        // Do not retry another backend after creation fails: a partial image
        // may already exist. Neither backend may overwrite the destination.
        try await createImage(at: image, name: name, capacityGiB: capacityGiB)
        return try await files.captured(Record(imageURL: image))
    }

    func createImage(at image: URL, name: String, capacityGiB: Int) async throws {
        try Self.validate(name: name, capacityGiB: capacityGiB)
        let support = try await AppLibraryImageFileAccess.readCommand(runner: runner, executable: "/usr/sbin/diskutil",
            arguments: ["image", "create", "blank", "--help"], timeout: 10)
        if support.runningProcess != nil { throw CocoaError(.fileReadUnknown) }
        if support.status == 0, !support.timedOut, support.stdoutText.contains("UDSB") {
            // Use an exact byte count: modern diskutil documents bytes as its
            // default unit, unlike the legacy hdiutil size suffix.
            let bytes = Int64(capacityGiB) * 1024 * 1024 * 1024
            _ = try await command("/usr/sbin/diskutil", ["image", "create", "blank", "--plist",
                "--format", "UDSB", "--size", String(bytes), "--fs", "APFS",
                "--volumeName", name, image.path], timeout: 600)
        } else {
            _ = try await command("/usr/bin/hdiutil", ["create", "-size", "\(capacityGiB)g",
                "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", name, image.path], timeout: 600)
        }
    }

    func mount(_ record: Record) async throws -> (record: Record, libraryURL: URL) {
        let previousImage = URL(fileURLWithPath: record.imagePath)
        var record = try await files.resolved(record)
        record.mountPath = record.libraryPath ?? record.mountPath
        if record.imagePath != previousImage.path,
           try await attachedVolumes(for: previousImage) != nil { throw identityFailure() }
        let image = URL(fileURLWithPath: record.imagePath)
        let source = try await files.inspect(.source(record))
        guard source.value == true else { throw identityFailure() }
        let mount = URL(fileURLWithPath: record.mountPath)
        guard image.pathExtension.lowercased() == "sparsebundle",
              mount.pathComponents.count == 3,
              mount.deletingLastPathComponent().path == "/Volumes",
              mount.standardizedFileURL.path == record.mountPath else {
            throw Failure(message: "映像记录无效，请重新打开映像。".localized)
        }
        var devices = try await imageDevices(for: image)
        let wasAttached = devices != nil
        if devices == nil {
            try await requireVacantMount(record.mountPath)
            let support = try await AppLibraryImageFileAccess.readCommand(runner: runner, executable: "/usr/sbin/diskutil",
                arguments: ["image", "attach", "--help"], timeout: 10)
            if support.status == 0, !support.timedOut, support.stdoutText.contains("--noMount") {
                _ = try await command("/usr/sbin/diskutil", ["image", "attach", "--plist", "--noMount", image.path], timeout: 600)
            } else {
                _ = try await command("/usr/bin/hdiutil", ["attach", "-plist", "-noautofsck", "-nomount", image.path], timeout: 600)
            }
            devices = try await imageDevices(for: image)
        }
        guard let devices, !devices.isEmpty else { throw identityFailure() }
        do {
            let candidate = try await identifiedVolume(devices, expectedUUID: record.volumeUUID,
                                                       preferredMount: record.mountPath)
            if let existing = candidate.mount, record.libraryPath != nil,
               existing != record.mountPath { throw identityFailure() }
            var updated = try await files.captured(record)
            if let captured = updated.backingVolumeUUID,
               source.uuid?.caseInsensitiveCompare(captured) != .orderedSame { throw identityFailure() }
            if candidate.mount == nil {
                try await requireVacantMount(record.mountPath)
                try Task.checkCancellation()
                // Let Disk Arbitration create the mount directory. -mountPoint
                // requires an existing directory, conflicting with vacancy checks.
                _ = try await command("/usr/sbin/diskutil", ["mount", candidate.device], timeout: 600)
            }
            guard let entries = try await attachedVolumes(for: image) else { throw identityFailure() }
            let verified = try await verifiedVolume(entries, expectedUUID: candidate.uuid)
            guard record.libraryPath == nil || verified.url.path == record.mountPath else { throw identityFailure() }
            updated.mountPath = verified.url.path
            updated.volumeUUID = verified.uuid
            updated.libraryPath = verified.url.path
            AppLogger.shared.logContext("应用库映像已挂载并核对身份",
                details: [("image", image.path), ("mount_point", verified.url.path), ("volume_uuid", verified.uuid)])
            return (updated, verified.url)
        } catch let pending as ShellCommandUnconfirmedTermination {
            // Never roll back while an attach/mount writer might still be running.
            throw pending
        } catch {
            if !wasAttached {
                do {
                    try await Task.detached { try await self.detachOwnedImage(image, devices: devices) }.value
                } catch let pending as ShellCommandUnconfirmedTermination { throw pending }
                catch {
                    AppLogger.shared.logContext("映像挂载失败，附加设备已保留，请检查",
                        details: [("image", image.path), ("error", error.localizedDescription)], level: "WARN")
                }
            }
            throw error
        }
    }

    private func requireVacantMount(_ path: String) async throws {
        guard try await files.inspect(.occupied(path)).value == false else {
            throw Failure(message: "映像挂载位置已被占用，请在 Finder 中检查后重试。".localized + "\n\n" + path)
        }
    }

    struct ImageDevice: Sendable {
        let device: String
        let mount: String?
        var contentHint: String? = nil
    }

    private func imageDevices(for image: URL) async throws -> [ImageDevice]? {
        guard var devices = try Self.attachedDevices(data: await command("/usr/bin/hdiutil", ["info", "-plist"], readOnly: true), image: image) else { return nil }
        // Unmounted APFS images may expose only the physical store in hdiutil.
        // Resolve synthesized volumes through that store, never by volume name.
        for store in devices where store.contentHint == "Apple_APFS"
            || store.contentHint?.caseInsensitiveCompare("7C3457EF-0000-11AA-AA11-00306543ECAC") == .orderedSame {
            let data = try await command("/usr/sbin/diskutil", ["apfs", "list", "-plist"], readOnly: true)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let containers = plist["Containers"] as? [[String: Any]] else { throw identityFailure() }
            let matching = containers.filter { container in
                (container["PhysicalStores"] as? [[String: Any]])?.contains {
                    ($0["DeviceIdentifier"] as? String).map { "/dev/" + $0 == store.device } == true
                } == true
            }
            guard matching.count == 1 else { throw identityFailure() }
            for container in matching {
                guard let physicalStores = container["PhysicalStores"] as? [[String: Any]],
                      physicalStores.count == 1,
                      let identifier = physicalStores[0]["DeviceIdentifier"] as? String,
                      "/dev/" + identifier == store.device,
                      let volumes = container["Volumes"] as? [[String: Any]] else { throw identityFailure() }
                for volume in volumes {
                    guard let identifier = volume["DeviceIdentifier"] as? String,
                          !identifier.contains("/"), identifier.hasPrefix("disk") else { throw identityFailure() }
                    let device = "/dev/" + identifier
                    if !devices.contains(where: { $0.device == device }) {
                        let point = (volume["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        devices.append(ImageDevice(device: device, mount: point))
                    }
                }
            }
        }
        return devices
    }

    private func identifiedVolume(_ devices: [ImageDevice], expectedUUID: String?, preferredMount: String) async throws -> (device: String, uuid: String, mount: String?) {
        var matches: [(String, String, String?)] = []
        for entry in devices {
            guard entry.device.hasPrefix("/dev/disk") else { throw identityFailure() }
            let data = try await command("/usr/sbin/diskutil", ["info", "-plist", entry.device], readOnly: true)
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw identityFailure() }
            guard info["FilesystemType"] as? String == "apfs" else { continue }
            guard let uuid = info["VolumeUUID"] as? String, UUID(uuidString: uuid) != nil else { throw identityFailure() }
            if let expectedUUID, uuid.caseInsensitiveCompare(expectedUUID) != .orderedSame { continue }
            let point = (info["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // An unmounted APFS volume reports WritableVolume=false even on
            // writable media. Verify volume writability after mounting it.
            guard point == nil ? info["WritableMedia"] as? Bool == true
                : info["WritableVolume"] as? Bool == true else { continue }
            // APFS inventories may omit MountPoint; diskutil info is the
            // current source of truth for each device belonging to this image.
            guard point == nil || point!.hasPrefix("/Volumes/") else { continue }
            matches.append((entry.device, uuid, point))
        }
        // A selected image may contain several usable volumes. Prefer the
        // existing library mount, then keep device order stable across reads.
        let ordered = matches.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        guard let result = ordered.first(where: { $0.2 == preferredMount }) ?? ordered.first else { throw identityFailure() }
        return result
    }

    /// Scope launch-time data mounts to devices actually backed by this image.
    func volumeUUIDs(in record: Record) async throws -> Set<String> {
        guard let devices = try await imageDevices(for: URL(fileURLWithPath: record.imagePath)) else { throw identityFailure() }
        var result = Set<String>()
        for entry in devices {
            let data = try await command("/usr/sbin/diskutil", ["info", "-plist", entry.device], readOnly: true)
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw identityFailure() }
            if info["FilesystemType"] as? String == "apfs", let uuid = info["VolumeUUID"] as? String {
                result.insert(uuid.uppercased())
            }
        }
        return result
    }

    /// Caller holds OperationLock. Detach only the selected image, never its backing disk/share.
    func unmount(_ record: Record, pauses: DiskEjectionPauseStore) async throws {
        guard let expected = record.volumeUUID, UUID(uuidString: expected) != nil else { throw identityFailure() }
        let image = URL(fileURLWithPath: record.imagePath)
        guard let devices = try await imageDevices(for: image) else {
            try pauses.pauseImage(record, volumeUUIDs: [], mountPaths: [])
            return
        }
        _ = try await identifiedVolume(devices, expectedUUID: expected,
                                      preferredMount: record.libraryPath ?? record.mountPath)
        let uuids = try await volumeUUIDs(in: record)
        // Persist before dispatch: denial, busy files and partial unmounts must not trigger remount.
        try pauses.pauseImage(record, volumeUUIDs: uuids, mountPaths: Set(devices.compactMap(\.mount)))
        do {
            try await detachOwnedImage(image, devices: devices)
        } catch let pending as ShellCommandUnconfirmedTermination {
            // A timed-out detach may still be writing. Keep the caller's lock
            // until it exits, just as attachment and creation do.
            while (try? ProcessCommandRunner.isRunning(pending.process)) != false {
                await Task.detached { try? await Task.sleep(nanoseconds: 1_000_000_000) }.value
            }
            throw pending
        }
        guard try await imageDevices(for: image) == nil else { throw identityFailure() }
    }

    private func detachOwnedImage(_ image: URL, devices: [ImageDevice]) async throws {
        guard let current = try await imageDevices(for: image) else { return }
        guard Set(current.map(\.device)) == Set(devices.map(\.device)),
              let root = devices.first(where: { entry in
                  let suffix = entry.device.dropFirst("/dev/disk".count)
                  return entry.device.hasPrefix("/dev/disk") && !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
              }) else { throw identityFailure() }
        _ = try await command("/usr/bin/hdiutil", ["detach", root.device], timeout: 30)
    }

    /// nil means detached. Existing attachments are reused without attaching a second writer.
    private func attachedVolumes(for image: URL) async throws -> [[String: String]]? {
        guard let devices = try await imageDevices(for: image) else { return nil }
        var entries: [[String: String]] = []
        for entry in devices {
            var point = entry.mount
            if point == nil {
                let data = try await command("/usr/sbin/diskutil", ["info", "-plist", entry.device], readOnly: true)
                guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw identityFailure()
                }
                point = info["MountPoint"] as? String
            }
            if let point, !point.isEmpty { entries.append(["device": entry.device, "mount": point]) }
        }
        return entries
    }

    static func attachedVolumes(data: Data, image: URL) throws -> [[String: String]]? {
        try attachedDevices(data: data, image: image)?.compactMap { entry in
            entry.mount.map { ["device": entry.device, "mount": $0] }
        }
    }

    static func attachedDevices(data: Data, image: URL) throws -> [ImageDevice]? {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            throw Failure(message: "无法核对映像对应的磁盘，请在 Finder 中检查后重试。".localized)
        }
        let matches = images.filter {
            guard let path = $0["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL == image.standardizedFileURL
        }
        guard matches.count <= 1 else {
            throw Failure(message: "无法核对映像对应的磁盘，请在 Finder 中检查后重试。".localized)
        }
        guard let match = matches.first else { return nil }
        guard let entities = match["system-entities"] as? [[String: Any]] else {
            throw Failure(message: "无法核对映像对应的磁盘，请在 Finder 中检查后重试。".localized)
        }
        return entities.compactMap { entity in
            guard let device = entity["dev-entry"] as? String else { return nil }
            let point = (entity["mount-point"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ImageDevice(device: device, mount: point, contentHint: entity["content-hint"] as? String)
        }
    }

    private func verifiedVolume(_ entries: [[String: String]], expectedUUID: String?) async throws -> (url: URL, uuid: String) {
        var candidates: [(URL, String)] = []
        for entry in entries {
            guard let device = entry["device"], let point = entry["mount"],
                  device.hasPrefix("/dev/disk") else { throw identityFailure() }
            let data = try await command("/usr/sbin/diskutil", ["info", "-plist", device], readOnly: true)
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { throw identityFailure() }
            guard info["FilesystemType"] as? String == "apfs" else { continue }
            guard let uuid = info["VolumeUUID"] as? String, UUID(uuidString: uuid) != nil else { throw identityFailure() }
            if let expectedUUID, uuid.caseInsensitiveCompare(expectedUUID) != .orderedSame { continue }
            guard point.hasPrefix("/Volumes/"), info["MountPoint"] as? String == point,
                  info["WritableVolume"] as? Bool == true else { throw identityFailure() }
            let url = URL(fileURLWithPath: point)
            guard try await currentMountedUUID(at: url)?.caseInsensitiveCompare(uuid) == .orderedSame else { throw identityFailure() }
            candidates.append((url, uuid))
        }
        guard let candidate = candidates.first else { throw identityFailure() }
        return candidate
    }

    func currentMountedUUID(at url: URL) async throws -> String? {
        if let mountedUUID { return mountedUUID(url) }
        return try await files.mountedUUID(at: url)
    }

    private func identityFailure(line: UInt = #line) -> Failure {
        AppLogger.shared.logContext("应用库映像核对失败",
            details: [("check_line", String(line))], level: "ERROR")
        return Failure(message: "映像操作未完成，已有文件会保留。".localized)
    }

    private func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30,
                         readOnly: Bool = false) async throws -> Data {
        let result: ShellCommandResult
        if readOnly {
            result = try await AppLibraryImageFileAccess.readCommand(runner: runner, executable: executable, arguments: arguments, timeout: timeout)
        } else {
            result = try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
        }
        if let process = result.runningProcess {
            if readOnly { throw CocoaError(.fileReadUnknown) }
            throw ShellCommandUnconfirmedTermination(process: process)
        }
        guard result.status == 0, !result.timedOut, !result.outputWasTruncated else {
            AppLogger.shared.logContext("应用库映像命令失败", details: [
                ("executable", executable), ("status", String(result.status)),
                ("timeout", String(result.timedOut)), ("output", result.combinedText)], level: "ERROR")
            let detail = result.stderrText.split(whereSeparator: \.isNewline).last.map(String.init)
                ?? result.stdoutText.split(whereSeparator: \.isNewline).last.map(String.init)
            let message = "映像操作未完成，已有文件会保留。".localized
            throw Failure(message: detail.map { message + "\n\n" + String($0.suffix(2000)) } ?? message)
        }
        return result.standardOutput
    }
}
