import Foundation

/// Images are explicit application-library destinations, not physical disks or
/// container-migration records. Never delete or repair an image on failure.
struct AppLibraryImageService: Sendable {
    struct Record: Codable, Equatable, Sendable {
        var imagePath: String
        var mountPath: String
        var volumeUUID: String?
        var libraryPath: String?

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
    var mountedUUID: @Sendable (URL) -> String? = { url in
        guard DiskUtility.isMountPoint(url) else { return nil }
        return DiskUtility.mountedVolumeUUID(at: url)
    }
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
        try requireDirectory(directory)
        // Require the containing filesystem to be mounted now. Do not create
        // parent directories under an offline /Volumes share.
        let properties = try directory.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        guard properties.volumeIsInternal == false || properties.volumeIsLocal == false,
              let volume = DiskUtility.mountedVolumePath(containing: directory), volume != "/",
              !directory.path.hasPrefix("/Volumes/") || volume.hasPrefix("/Volumes/") else {
            throw Failure(message: "请选择已挂载的外部存储或 SMB 共享目录。".localized)
        }
        let image = directory.appendingPathComponent(name + ".sparsebundle", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: image.path) else {
            throw Failure(message: "该位置已有同名文件，请更换名称或打开已有映像。".localized)
        }
        // Do not retry another backend after creation fails: a partial image
        // may already exist. Neither backend may overwrite the destination.
        try await createImage(at: image, name: name, capacityGiB: capacityGiB)
        return Record(imageURL: image)
    }

    func createImage(at image: URL, name: String, capacityGiB: Int) async throws {
        try Self.validate(name: name, capacityGiB: capacityGiB)
        let support = try await runner.run(executable: "/usr/sbin/diskutil",
            arguments: ["image", "create", "blank", "--help"], timeout: 10)
        if let process = support.runningProcess { throw ShellCommandUnconfirmedTermination(process: process) }
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
        let image = URL(fileURLWithPath: record.imagePath)
        try requireDirectory(image)
        let mount = URL(fileURLWithPath: record.mountPath)
        guard image.pathExtension.lowercased() == "sparsebundle",
              mount.pathComponents.count == 3,
              mount.deletingLastPathComponent().path == "/Volumes",
              mount.standardizedFileURL.path == record.mountPath else {
            throw Failure(message: "映像记录无效，请重新打开映像。".localized)
        }
        var entries = try await attachedVolumes(for: image)
        if entries == nil {
            // Never mount over a directory, symlink or another mounted volume.
            guard !FileManager.default.fileExists(atPath: record.mountPath),
                  (try? FileManager.default.attributesOfItem(atPath: record.mountPath)) == nil else {
                throw Failure(message: "映像挂载位置已被占用，请在 Finder 中检查后重试。".localized + "\n\n" + record.mountPath)
            }
            let support = try await runner.run(executable: "/usr/sbin/diskutil",
                arguments: ["image", "attach", "--help"], timeout: 10)
            if support.status == 0, !support.timedOut, support.stdoutText.contains("--noMount") {
                _ = try await command("/usr/sbin/diskutil", ["image", "attach", "--plist",
                    "--mountPoint", record.mountPath, image.path], timeout: 600)
            } else {
                _ = try await command("/usr/bin/hdiutil", ["attach", "-plist", "-noautofsck",
                    "-nobrowse", "-mountpoint", record.mountPath, image.path], timeout: 600)
            }
            entries = try await attachedVolumes(for: image)
        }
        guard let entries else { throw identityFailure() }
        let verified = try await verifiedVolume(entries, expectedUUID: record.volumeUUID)
        var updated = record
        updated.volumeUUID = verified.uuid
        updated.libraryPath = verified.url.path
        AppLogger.shared.logContext("应用库映像已挂载并核对身份",
            details: [("image", image.path), ("mount_point", verified.url.path), ("volume_uuid", verified.uuid)])
        return (updated, verified.url)
    }

    /// nil means detached. An attached but unmounted image is not reattached:
    /// it requires explicit inspection instead of a second write attachment.
    private func attachedVolumes(for image: URL) async throws -> [[String: String]]? {
        let data = try await command("/usr/bin/hdiutil", ["info", "-plist"])
        return try Self.attachedVolumes(data: data, image: image)
    }

    static func attachedVolumes(data: Data, image: URL) throws -> [[String: String]]? {
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
            guard let device = entity["dev-entry"] as? String,
                  let point = entity["mount-point"] as? String, !point.isEmpty else { return nil }
            return ["device": device, "mount": point]
        }
    }

    private func verifiedVolume(_ entries: [[String: String]], expectedUUID: String?) async throws -> (url: URL, uuid: String) {
        var candidates: [(URL, String)] = []
        for entry in entries {
            guard let device = entry["device"], let point = entry["mount"],
                  point.hasPrefix("/Volumes/"), device.hasPrefix("/dev/disk") else { throw identityFailure() }
            let data = try await command("/usr/sbin/diskutil", ["info", "-plist", device])
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { throw identityFailure() }
            guard info["FilesystemType"] as? String == "apfs" else { continue }
            guard let uuid = info["VolumeUUID"] as? String, UUID(uuidString: uuid) != nil,
                  info["MountPoint"] as? String == point,
                  info["WritableVolume"] as? Bool == true else { throw identityFailure() }
            if let expectedUUID, uuid.caseInsensitiveCompare(expectedUUID) != .orderedSame { continue }
            let url = URL(fileURLWithPath: point)
            guard mountedUUID(url)?.caseInsensitiveCompare(uuid) == .orderedSame else { throw identityFailure() }
            candidates.append((url, uuid))
        }
        guard candidates.count == 1 else { throw identityFailure() }
        return candidates[0]
    }

    private func requireDirectory(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Failure(message: "无法访问所选目录或映像，请先在 Finder 中连接共享。".localized)
        }
    }

    private func identityFailure() -> Failure {
        Failure(message: "无法确认映像中的唯一可写 APFS 磁盘，未更改迁移目标。".localized)
    }

    private func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> Data {
        let result = try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
        if let process = result.runningProcess { throw ShellCommandUnconfirmedTermination(process: process) }
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
