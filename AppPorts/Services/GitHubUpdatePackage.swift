import CryptoKit
import Foundation
import Security

struct GitHubUpdateAsset: Codable, Equatable, Sendable {
    let name: String
    let size: Int64
    let browserDownloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name, size, digest
        case browserDownloadURL = "browser_download_url"
    }

    var sha256: String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let value = String(digest.dropFirst(7)).lowercased()
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return value
    }

    var isSupported: Bool {
        let url = browserDownloadURL
        let lower = name.lowercased()
        return url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.path.hasPrefix("/wzh4869/AppPorts/releases/download/")
            && lower.hasPrefix("appports") && !lower.contains("symbol")
            && ["zip", "dmg"].contains((name as NSString).pathExtension.lowercased())
            && size > 0 && size <= 512 * 1024 * 1024 && sha256 != nil
    }

    static func select(from assets: [Self], architecture: String = nativeArchitecture) -> Self? {
        let candidates = assets.filter { asset in
            guard asset.isSupported else { return false }
            let name = asset.name.lowercased()
            let arm = name.contains("arm64") || name.contains("aarch64") || name.contains("apple-silicon")
            let intel = name.contains("x86_64") || name.contains("x64") || name.contains("intel")
            return (!arm && !intel) || (arm && intel) || (architecture == "arm64" ? arm : intel)
        }
        // Prefer a single ZIP over a DMG when both packaging formats are published.
        for ext in ["zip", "dmg"] {
            let matches = candidates.filter { ($0.name as NSString).pathExtension.lowercased() == ext }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { return nil }
        }
        return nil
    }

    static var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

enum AppUpdateError: LocalizedError {
    case package, checksum, application, location, changed

    var errorDescription: String? {
        switch self {
        case .package: return "此版本没有可自动安装的更新包，请前往 GitHub 发布页下载。".localized
        case .checksum: return "更新包校验失败，请重新下载。".localized
        case .application: return "更新包中的应用不兼容或已损坏，请前往发布页下载。".localized
        case .location: return "当前位置无法自动替换应用，请前往发布页手动更新。".localized
        case .changed: return "应用已发生变化，请重新检查更新。".localized
        }
    }
}

struct PreparedAppUpdate: Sendable {
    let workspace: URL
    let destination: URL
    let originalIdentity: String
    let stagedIdentity: String
    let version: String
    var stagedApplication: URL { workspace.appendingPathComponent("AppPorts.app") }
}

struct GitHubUpdatePackage: Sendable {
    let runner: any ShellCommandRunning
    let session: URLSession

    init(runner: any ShellCommandRunning = ProcessCommandRunner(), session: URLSession = .shared) {
        self.runner = runner
        self.session = session
    }

    func prepare(update: AppUpdateInfo, destination: URL,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedAppUpdate {
        guard update.source == .github, let asset = update.githubAsset, asset.isSupported else {
            throw AppUpdateError.package
        }
        let destination = destination.standardizedFileURL
        let original = try Self.validateDestination(destination)
        let workspace = destination.deletingLastPathComponent()
            .appendingPathComponent(".AppPorts-update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            var request = URLRequest(url: asset.browserDownloadURL)
            request.timeoutInterval = 300
            request.setValue("AppPorts-Updater", forHTTPHeaderField: "User-Agent")
            let delegate = UpdateDownloadProgress(expectedSize: asset.size, progress: progress)
            let (temporaryURL, response) = try await session.download(for: request, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https" else { throw AppUpdateError.package }
            let archive = workspace.appendingPathComponent("update." + (asset.name as NSString).pathExtension.lowercased())
            try FileManager.default.moveItem(at: temporaryURL, to: archive)
            try Self.verifyArchive(at: archive, asset: asset)
            try Task.checkCancellation()
            progress(1)

            if archive.pathExtension == "dmg" {
                try await extractDMG(archive, workspace: workspace)
            } else {
                try await extractZIP(archive, workspace: workspace)
            }
            let staged = workspace.appendingPathComponent("AppPorts.app")
            try await validateApplication(staged, version: update.version, currentApplication: destination)
            // Only remove quarantine from the downloaded, verified application, never system policy.
            _ = try await command("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
            guard try Self.identity(at: destination) == original else { throw AppUpdateError.changed }
            return PreparedAppUpdate(workspace: workspace, destination: destination, originalIdentity: original,
                                     stagedIdentity: try Self.identity(at: staged), version: update.version)
        } catch {
            // A failed detach must never turn recursive cleanup into deletion through a mounted volume.
            let mount = workspace.appendingPathComponent("mount")
            let mountedVolume = try? mount.resourceValues(forKeys: [.volumeURLKey]).volume
            if mountedVolume?.standardizedFileURL.path != mount.path {
                try? FileManager.default.removeItem(at: workspace)
            }
            throw error
        }
    }

    static func verifyArchive(at url: URL, asset: GitHubUpdateAsset) throws {
        guard asset.isSupported, let expected = asset.sha256,
              (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(asset.size) else {
            throw AppUpdateError.checksum
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw AppUpdateError.checksum
        }
    }

    static func validateDestination(_ url: URL) throws -> String {
        let parent = url.deletingLastPathComponent()
        guard url.pathExtension == "app", !url.path.hasPrefix("/Volumes/"),
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
              FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: url.path),
              Bundle(url: url)?.bundleIdentifier == "com.shimoko.AppPorts" else { throw AppUpdateError.location }
        let values = try url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .isDirectoryKey])
        guard values.isDirectory == true, values.volumeIsReadOnly != true else { throw AppUpdateError.location }
        return try identity(at: url)
    }

    static func identity(at url: URL) throws -> String {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeDirectory,
              let device = values[.systemNumber] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber else { throw AppUpdateError.changed }
        return "\(device):\(inode)"
    }

    private func extractDMG(_ archive: URL, workspace: URL) async throws {
        let mount = workspace.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        // Always attempt detach, including a partial attach or task cancellation.
        do {
            _ = try await command("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen",
                                                       "-mountpoint", mount.path, archive.path])
            let app = mount.appendingPathComponent("AppPorts.app")
            guard app.resolvingSymlinksInPath().path == app.path else { throw AppUpdateError.application }
            _ = try await command("/usr/bin/ditto", ["--noqtn", app.path, workspace.appendingPathComponent("AppPorts.app").path])
        } catch {
            _ = await detach(mount)
            throw error
        }
        guard await detach(mount) else { throw AppUpdateError.application }
    }

    private func detach(_ mount: URL) async -> Bool {
        let runner = runner
        // Cleanup must still run after download/preparation has been cancelled.
        return await Task.detached {
            let result = try? await runner.run(executable: "/usr/bin/hdiutil", arguments: ["detach", mount.path], timeout: 30)
            return result?.status == 0 && result?.timedOut == false
        }.value
    }

    private func extractZIP(_ archive: URL, workspace: URL) async throws {
        let entries = try await command("/usr/bin/unzip", ["-Z1", archive.path])
        let paths = entries.stdoutText.split(separator: "\n").map(String.init)
        guard !paths.isEmpty, paths.allSatisfy({ path in
            !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
                && (path.hasPrefix("AppPorts.app/") || path.hasPrefix("__MACOSX/"))
        }) else { throw AppUpdateError.package }
        _ = try await command("/usr/bin/ditto", ["-x", "-k", "--noqtn", archive.path, workspace.path])
    }

    func validateApplication(_ url: URL, version: String, currentApplication: URL) async throws {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.shimoko.AppPorts",
              let actual = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              actual == version,
              let current = Bundle(url: currentApplication)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version.compare(current, options: .numeric) == .orderedDescending,
              let executable = bundle.executableURL,
              executable.resolvingSymlinksInPath().path.hasPrefix(url.path + "/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw AppUpdateError.application }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let running = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard minimum.compare(running, options: .numeric) != .orderedDescending else { throw AppUpdateError.application }
        }
        let archs = try await command("/usr/bin/lipo", ["-archs", executable.path])
        guard archs.stdoutText.split(whereSeparator: \.isWhitespace).contains(Substring(GitHubUpdateAsset.nativeArchitecture)) else {
            throw AppUpdateError.application
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw AppUpdateError.application
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil)
        // Releases may be intentionally unsigned; an invalid existing signature is never accepted.
        guard status == errSecSuccess || status == errSecCSUnsigned else { throw AppUpdateError.application }
    }

    @discardableResult
    private func command(_ executable: String, _ arguments: [String]) async throws -> ShellCommandResult {
        let result = try await runner.run(executable: executable, arguments: arguments, timeout: 120)
        guard result.status == 0, !result.timedOut else {
            AppLogger.shared.logContext("更新包处理失败", details: [("command", executable), ("error", result.combinedText)])
            throw AppUpdateError.application
        }
        return result
    }
}

private final class UpdateDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedSize: Int64
    let progress: @Sendable (Double) -> Void

    init(expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedSize { downloadTask.cancel(); return }
        progress(min(1, Double(totalBytesWritten) / Double(expectedSize)))
    }
}
