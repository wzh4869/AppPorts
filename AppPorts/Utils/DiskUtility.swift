//
//  DiskUtility.swift
//  AppPorts
//

import Darwin
import Foundation

// MARK: - 外部命令执行

struct ShellCommandResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
    let timedOut: Bool

    var stdoutText: String { String(decoding: standardOutput, as: UTF8.self) }
    var stderrText: String { String(decoding: standardError, as: UTF8.self) }
    var combinedText: String {
        (stdoutText + "\n" + stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 可注入的命令执行器；测试用假执行器记录调用顺序并伪造输出。
protocol ShellCommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult
}

/// 用 Process 执行外部命令。超时后终止进程，避免 diskutil 挂死时整个操作卡住。
struct ProcessCommandRunner: ShellCommandRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let collector = OutputCollector()
            let readers = DispatchGroup()
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                collector.setStandardOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                collector.setStandardError(errorPipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }

            process.terminationHandler = { finished in
                // 等两个管道读完再返回结果，但不阻塞系统的高优先级退出回调线程。
                let status = finished.terminationStatus
                readers.notify(queue: .global(qos: .utility)) {
                    continuation.resume(returning: collector.result(status: status))
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                // 释放写端，让两个读取任务立即结束。
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                collector.markTimedOut()
                process.terminate()
            }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var standardOutput = Data()
        private var standardError = Data()
        private var timedOut = false

        func setStandardOutput(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            standardOutput = data
        }

        func setStandardError(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            standardError = data
        }

        func markTimedOut() {
            lock.lock(); defer { lock.unlock() }
            timedOut = true
        }

        func result(status: Int32) -> ShellCommandResult {
            lock.lock(); defer { lock.unlock() }
            return ShellCommandResult(status: status, standardOutput: standardOutput, standardError: standardError, timedOut: timedOut)
        }
    }
}

// MARK: - diskutil 封装

/// `diskutil` 与 `statfs` 封装，供容器数据挂载迁移使用。
///
/// 所有 diskutil 调用都带超时；查询类命令统一用 `-plist` 解析，避免依赖人类可读输出。
struct DiskUtility: Sendable {
    struct VolumeInfo: Equatable, Sendable {
        let deviceIdentifier: String
        let volumeUUID: String?
        let volumeName: String?
        let filesystemType: String?
        let apfsContainerReference: String?
        let mountPoint: String?
        var isEncrypted: Bool = false

        var isAPFS: Bool {
            filesystemType?.lowercased() == "apfs"
        }
    }

    enum Failure: LocalizedError {
        case commandFailed(command: String, output: String)
        case timedOut(command: String)
        case unexpectedOutput(command: String, output: String)
        case administratorPromptCancelled(command: String)
        case privilegeRequired(command: String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let command, let output):
                return String(format: "磁盘命令执行失败（%@）：%@".localized, command, output)
            case .timedOut(let command):
                return String(format: "磁盘命令超时（%@）".localized, command)
            case .unexpectedOutput(let command, let output):
                return String(format: "无法解析磁盘命令输出（%@）：%@".localized, command, output)
            case .administratorPromptCancelled(let command):
                return String(format: "用户取消了管理员授权，无法执行磁盘命令（%@）".localized, command)
            case .privilegeRequired(let command):
                return String(format: "此系统版本要求管理员权限才能执行磁盘命令，当前环境无法弹出授权框（%@）".localized, command)
            }
        }
    }

    /// 以管理员权限执行命令；返回 nil 表示当前环境无法弹出授权框（如后台代理）。
    typealias AdministratorRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> ShellCommandResult

    static let diskutilPath = "/usr/sbin/diskutil"
    static let mountPath = "/sbin/mount"

    private let runner: ShellCommandRunning
    private let commandTimeout: TimeInterval
    private let administratorRunner: AdministratorRunner?

    /// - Parameter administratorRunner: 旧系统（macOS 12 等）的 DiskArbitration 不允许普通用户把卷挂到
    ///   自定义路径（`kDAReturnNotPrivileged`）。遇到这类失败时用它重试；传 nil 表示不能提权（后台代理）。
    init(
        runner: ShellCommandRunning = ProcessCommandRunner(),
        commandTimeout: TimeInterval = 180,
        administratorRunner: AdministratorRunner? = { try DiskUtility.runWithAdministratorPrivileges(executable: $0, arguments: $1) }
    ) {
        self.runner = runner
        self.commandTimeout = commandTimeout
        self.administratorRunner = administratorRunner
    }

    /// 通过 AppleScript 弹出系统密码框执行命令。同一进程内的授权会被系统缓存约 5 分钟，
    /// 一次迁移中的多条 diskutil 命令通常只提示一次。
    static func runWithAdministratorPrivileges(executable: String, arguments: [String]) throws -> ShellCommandResult {
        let command = ([executable] + arguments).map(shellQuoted).joined(separator: " ")
        let script = "do shell script \(AppMigrationService.appleScriptStringLiteral(command)) with administrator privileges"
        var errorInfo: NSDictionary?
        let output = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? -1
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
            if number == -128 {
                throw Failure.administratorPromptCancelled(command: command)
            }
            return ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data("\(message) (AppleScript error \(number))".utf8), timedOut: false)
        }
        return ShellCommandResult(status: 0, standardOutput: Data((output?.stringValue ?? "").utf8), standardError: Data(), timedOut: false)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// DiskArbitration 拒绝普通用户操作时的典型输出。
    static func indicatesPrivilegeFailure(_ output: String) -> Bool {
        output.contains("kDAReturnNotPrivileged")
            || output.localizedCaseInsensitiveContains("not allowed by the invoking user")
            || output.localizedCaseInsensitiveContains("Not privileged")
    }

    // MARK: 查询

    /// `target` 可以是挂载路径、设备标识（disk5s2）或 Volume UUID。
    func volumeInfo(for target: String) async throws -> VolumeInfo {
        let plist = try await runPlist(["info", "-plist", target])
        guard let deviceIdentifier = plist["DeviceIdentifier"] as? String else {
            throw Failure.unexpectedOutput(command: "diskutil info", output: target)
        }
        return VolumeInfo(
            deviceIdentifier: deviceIdentifier,
            volumeUUID: plist["VolumeUUID"] as? String,
            volumeName: plist["VolumeName"] as? String,
            filesystemType: plist["FilesystemType"] as? String,
            apfsContainerReference: plist["APFSContainerReference"] as? String,
            mountPoint: plist["MountPoint"] as? String,
            isEncrypted: (plist["Encrypted"] as? Bool == true) || (plist["FileVault"] as? Bool == true)
        )
    }

    // MARK: 卷操作

    /// Add a volume with an actual user-owned root so an owners-enabled mount
    /// can preserve source uid/gid. diskutil addVolume creates a root-owned root.
    /// A timed-out or failed creation is never retried: it may already have run.
    func createAPFSVolume(inContainer container: String, name: String) async throws -> String {
        guard container.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              !name.isEmpty else {
            throw Failure.unexpectedOutput(command: "newfs_apfs add volume", output: "Invalid container or volume name")
        }
        let before = try await creationContainer(container)
        let arguments = ["-A", "-w", "-U", String(getuid()), "-G", String(getgid()), "-v", name, container]
        let command = "newfs_apfs " + arguments.joined(separator: " ")
        let result = try await runner.run(executable: "/sbin/newfs_apfs", arguments: arguments, timeout: commandTimeout)
        if result.timedOut { throw Failure.timedOut(command: command) }
        guard result.status == 0 else { throw Failure.commandFailed(command: command, output: result.combinedText) }
        let after = try await creationContainer(container)
        let previousUUIDs = Set(before.volumes.map(\.uuid))
        let currentUUIDs = Set(after.volumes.map(\.uuid))
        let added = after.volumes.filter { !previousUUIDs.contains($0.uuid) }
        guard before.uuid == after.uuid, previousUUIDs.isSubset(of: currentUUIDs),
              added.count == 1, let fresh = added.first, fresh.name == name,
              !before.volumes.contains(where: { $0.device == fresh.device }) else {
            throw Failure.unexpectedOutput(command: command, output: "Cannot prove exactly one fresh volume in the original APFS container")
        }
        return fresh.device
    }

    private struct CreationContainer {
        struct Volume { let uuid: String; let device: String; let name: String }
        let uuid: String
        let volumes: [Volume]
    }

    private func creationContainer(_ reference: String) async throws -> CreationContainer {
        let arguments = ["apfs", "list", "-plist", reference]
        let plist = try await runPlist(arguments)
        func invalid() -> Failure {
            .unexpectedOutput(command: "diskutil " + arguments.joined(separator: " "), output: "Ambiguous APFS container identity")
        }
        guard let containers = plist["Containers"] as? [[String: Any]], containers.count == 1,
              let container = containers.first, container["ContainerReference"] as? String == reference,
              let uuid = container["APFSContainerUUID"] as? String, !uuid.isEmpty,
              let rawVolumes = container["Volumes"] as? [[String: Any]] else { throw invalid() }
        let volumes = try rawVolumes.map { value -> CreationContainer.Volume in
            guard let uuid = value["APFSVolumeUUID"] as? String, !uuid.isEmpty,
                  let device = value["DeviceIdentifier"] as? String,
                  device.range(of: "^" + reference + #"s[0-9]+$"#, options: .regularExpression) != nil,
                  let name = value["Name"] as? String else { throw invalid() }
            return .init(uuid: uuid.uppercased(), device: device, name: name)
        }
        guard Set(volumes.map(\.uuid)).count == volumes.count,
              Set(volumes.map(\.device)).count == volumes.count else { throw invalid() }
        return CreationContainer(uuid: uuid.uppercased(), volumes: volumes)
    }

    func findAPFSVolumeDevice(named name: String, inContainer container: String) async throws -> String? {
        let plist = try await runPlist(["apfs", "list", "-plist"])
        guard let containers = plist["Containers"] as? [[String: Any]] else { return nil }
        for entry in containers {
            guard entry["ContainerReference"] as? String == container,
                  let volumes = entry["Volumes"] as? [[String: Any]] else { continue }
            if let match = volumes.first(where: { ($0["Name"] as? String) == name }),
               let device = match["DeviceIdentifier"] as? String {
                return device
            }
        }
        return nil
    }

    func mount(volume: String, at mountPoint: URL, requireOwnership: Bool = false) async throws {
        let options = requireOwnership ? ["-mountOptions", "owners"] : []
        _ = try await run(["mount", "nobrowse", "-mountPoint", mountPoint.path] + options + [volume])
    }

    /// Explicit restore only. Keep Finder/safety flags while enabling real ownership.
    func setOwnershipForRestore(mountPoint: URL, originalFlags: UInt32, enabled: Bool) async throws {
        let flags = enabled ? originalFlags & ~UInt32(MNT_IGNORE_OWNERSHIP) : originalFlags
        var options = Self.updateOptions(addingNobrowseTo: flags)
        if enabled { options += ",owners" }
        let result = try await runner.run(executable: Self.mountPath,
            arguments: ["-u", "-o", options, mountPoint.path], timeout: commandTimeout)
        guard result.status == 0, !result.timedOut else {
            throw Failure.commandFailed(command: "mount ownership update", output: result.combinedText)
        }
    }

    /// 给早期版本挂上、没带 `nobrowse` 的卷补上这个选项，不用卸载。
    ///
    /// `mount -u` 会按给出的选项重设标志，只写 `nobrowse` 会把 `noowners` 等冲掉
    /// （2026-09-25 用临时映像实测），所以把现有的标志一并写回去。
    func hideFromFinder(mountPoint: URL, currentFlags: UInt32) async throws {
        let arguments = ["-u", "-o", Self.updateOptions(addingNobrowseTo: currentFlags), mountPoint.path]
        let result = try await runner.run(executable: Self.mountPath, arguments: arguments, timeout: commandTimeout)
        guard result.status == 0, !result.timedOut else {
            throw Failure.commandFailed(command: "mount " + arguments.joined(separator: " "), output: result.combinedText)
        }
    }

    static func updateOptions(addingNobrowseTo flags: UInt32) -> String {
        let preserved: [(Int32, String)] = [
            (MNT_RDONLY, "rdonly"),
            (MNT_NODEV, "nodev"),
            (MNT_NOSUID, "nosuid"),
            (MNT_NOEXEC, "noexec"),
            (MNT_IGNORE_OWNERSHIP, "noowners")
        ]
        let options = preserved.filter { flags & UInt32($0.0) != 0 }.map(\.1)
        return (["nobrowse"] + options).joined(separator: ",")
    }

    func unmount(mountPoint: URL, force: Bool = false) async throws {
        var arguments = ["unmount"]
        if force { arguments.append("force") }
        arguments.append(mountPoint.path)
        _ = try await run(arguments)
    }

    func deleteAPFSVolume(_ volume: String) async throws {
        // deleteVolume 只认设备标识；先把 Volume UUID 解析成 diskNsM。
        let device = (try? await volumeInfo(for: volume))?.deviceIdentifier ?? volume
        _ = try await run(["apfs", "deleteVolume", device])
    }

    // MARK: statfs

    /// 包含该路径的已挂载卷的挂载点（`/Volumes/hano`、`/` 等）；路径不存在时返回 nil。
    static func mountedVolumePath(containing url: URL) -> String? {
        var info = statfs()
        guard statfs(url.standardizedFileURL.path, &info) == 0 else { return nil }
        return withUnsafePointer(to: &info.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// 路径本身是否为挂载点（而不是挂载卷内的普通目录或未挂载的空目录）。
    static func isMountPoint(_ url: URL) -> Bool {
        guard let mountedOn = mountedVolumePath(containing: url) else { return false }
        return equivalentPaths(for: url).contains(mountedOn)
    }

    /// 挂载点的挂载标志（`statfs` 的 `f_flags`）；路径不存在时返回 nil。
    static func mountFlags(at url: URL) -> UInt32? {
        var info = statfs()
        guard statfs(url.standardizedFileURL.path, &info) == 0 else { return nil }
        return info.f_flags
    }

    /// 使用系统卷属性确认身份，不把路径上任意一个挂载卷都认作 AppPorts 的数据卷。
    static func mountedVolumeUUID(at url: URL) -> String? {
        // A reused URL may describe the filesystem that occupied this path
        // before a mount/unmount. Identity checks must query its current volume.
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        return try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    /// 路径所在卷的可用空间（字节）；查不到时返回 nil。
    ///
    /// 优先用「重要用途」口径，它把系统可以随时清掉的缓存也算作可用；
    /// 外置盘上这个值常常是 0，这时退回普通的可用空间。同一 APFS 容器里的卷共享这份空间。
    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// 同一个路径的几种合法写法。挂载点的名字来自内核（`statfs` 的 `f_mntonname`、
    /// `diskutil` 的 `MountPoint`），都是**解析过符号链接**的真实路径；
    /// 而记录里存的是应用路径，可能含符号链接（`/tmp`、用户自己建的软链），
    /// 直接字符串比较会把明明挂上的卷判成"不是挂载点"。
    ///
    /// 实测 `URL.resolvingSymlinksInPath()` 并不解析 `/tmp`（返回 `/tmp/...`），
    /// 所以还要再算一次内核的 `realpath()`。
    static func equivalentPaths(for url: URL) -> [String] {
        var paths = [url.standardizedFileURL.path]
        let foundationResolved = url.resolvingSymlinksInPath().path
        if !paths.contains(foundationResolved) { paths.append(foundationResolved) }
        if let kernelResolved = resolvedPath(url.path), !paths.contains(kernelResolved) {
            paths.append(kernelResolved)
        }
        return paths
    }

    /// 内核眼中的真实路径（`realpath(3)`）；路径不存在时返回 nil。
    static func resolvedPath(_ path: String) -> String? {
        guard let buffer = realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    /// 两条路径（其中一条可能带符号链接写法）是否指向同一个位置。
    static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = Set(equivalentPaths(for: URL(fileURLWithPath: lhs)))
        return equivalentPaths(for: URL(fileURLWithPath: rhs)).contains { left.contains($0) }
    }

    /// 同步查询卷是否在线（已连接，无论是否挂载）；供扫描器使用，带超时。
    static func isVolumeOnline(_ volume: String, timeout: TimeInterval = 15) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: diskutilPath)
        process.arguments = ["info", "-plist", volume]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            AppLogger.shared.logContext(
                "diskutil info 查询超时，已终止",
                details: [("volume", volume), ("timeout_sec", String(Int(timeout)))],
                level: "WARN"
            )
            return false
        }
        return process.terminationStatus == 0
    }

    /// 生成外置卷名称：可读、含应用标识，并带随机后缀避免重名。
    static func makeVolumeName(bundleIdentifier: String?, appName: String, directoryName: String) -> String {
        let identity = sanitizedVolumeNameComponent(bundleIdentifier ?? appName, limit: 40)
        let directory = sanitizedVolumeNameComponent(directoryName, limit: 24)
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        return "AppPorts-\(identity)-\(directory)-\(suffix)"
    }

    private static func sanitizedVolumeNameComponent(_ raw: String, limit: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") }
        let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        let result = String(trimmed.prefix(limit))
        return result.isEmpty ? "data" : result
    }

    // MARK: 私有辅助

    @discardableResult
    private func run(_ arguments: [String]) async throws -> ShellCommandResult {
        let command = "diskutil " + arguments.joined(separator: " ")
        var result = try await runner.run(executable: Self.diskutilPath, arguments: arguments, timeout: commandTimeout)
        AppLogger.shared.logContext(
            "diskutil 执行完成",
            details: [
                ("command", command),
                ("status", String(result.status)),
                ("timed_out", result.timedOut ? "true" : "false"),
                ("output", String(result.combinedText.prefix(2000)))
            ],
            level: "TRACE"
        )
        if result.timedOut {
            throw Failure.timedOut(command: command)
        }
        if result.status != 0, Self.indicatesPrivilegeFailure(result.combinedText) {
            // 旧系统的 DiskArbitration 只允许 root 使用自定义挂载点；请求管理员权限后重试一次。
            guard let administratorRunner else {
                AppLogger.shared.logContext(
                    "diskutil 需要管理员权限，但当前环境无法提权",
                    details: [("command", command)],
                    level: "WARN"
                )
                throw Failure.privilegeRequired(command: command)
            }
            AppLogger.shared.logContext(
                "diskutil 被 DiskArbitration 拒绝，改用管理员权限重试",
                details: [("command", command)],
                level: "WARN"
            )
            result = try administratorRunner(Self.diskutilPath, arguments)
            AppLogger.shared.logContext(
                "diskutil（管理员权限）执行完成",
                details: [("command", command), ("status", String(result.status)), ("output", String(result.combinedText.prefix(2000)))],
                level: "TRACE"
            )
        }
        guard result.status == 0 else {
            throw Failure.commandFailed(command: command, output: result.combinedText)
        }
        return result
    }

    private func runPlist(_ arguments: [String]) async throws -> [String: Any] {
        let result = try await run(arguments)
        guard let plist = try? PropertyListSerialization.propertyList(from: result.standardOutput, format: nil) as? [String: Any] else {
            throw Failure.unexpectedOutput(command: "diskutil " + arguments.joined(separator: " "), output: result.combinedText)
        }
        return plist
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}
