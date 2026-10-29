//
//  DiskUtility.swift
//  AppPorts
//

import Darwin
import Foundation
import CryptoKit

// MARK: - 外部命令执行

struct ShellCommandResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
    let timedOut: Bool
    var outputWasTruncated: Bool = false
    var runningProcess: ShellCommandProcessReference? = nil

    var stdoutText: String { String(decoding: standardOutput, as: UTF8.self) }
    var stderrText: String { String(decoding: standardError, as: UTF8.self) }
    var combinedText: String {
        (stdoutText + "\n" + stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A PID alone is not a durable process identity: it may be reused after exit.
struct ShellCommandProcessReference: Codable, Equatable, Sendable {
    let processIdentifier: Int32
    let startSeconds: UInt64?
    let startMicroseconds: UInt64?
}

struct ShellCommandUnconfirmedTermination: LocalizedError, Sendable {
    let process: ShellCommandProcessReference
    var errorDescription: String? {
        "后台命令尚未确认退出，AppPorts 会在其结束后自动继续处理。进程：".localized
            + String(process.processIdentifier)
    }
}

/// 可注入的命令执行器；测试用假执行器记录调用顺序并伪造输出。
protocol ShellCommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult
    func run(executable: String, arguments: [String], standardInput: Data, timeout: TimeInterval) async throws -> ShellCommandResult
}

extension ShellCommandRunning {
    func run(executable: String, arguments: [String], standardInput: Data, timeout: TimeInterval) async throws -> ShellCommandResult {
        throw CocoaError(.featureUnsupported)
    }
}

/// 用 Process 执行外部命令。超时后终止进程，避免 diskutil 挂死时整个操作卡住。
struct ProcessCommandRunner: ShellCommandRunning {
    /// nil preserves complete plist/JSON responses for existing callers.
    /// Logging commands can retain only a bounded tail while still draining pipes.
    var captureLimit: Int? = nil

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        try await runCommand(executable: executable, arguments: arguments, standardInput: nil, timeout: timeout)
    }

    func run(executable: String, arguments: [String], standardInput: Data, timeout: TimeInterval) async throws -> ShellCommandResult {
        guard standardInput.count <= 4096 else { throw CocoaError(.fileWriteInvalidFileName) }
        return try await runCommand(executable: executable, arguments: arguments, standardInput: standardInput, timeout: timeout)
    }

    private func runCommand(executable: String, arguments: [String], standardInput: Data?, timeout: TimeInterval) async throws -> ShellCommandResult {
        // Include dispatch queueing and process launch in the caller's time budget.
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try Self.execute(executable: executable,
                        arguments: arguments, standardInput: standardInput, deadline: deadline, cancellation: cancellation, captureLimit: captureLimit)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    /// Nonblocking pipe reads let one deadline cover the child AND inherited pipes.
    /// This worker never blocks Foundation's process termination callback queue.
    private static func execute(executable: String, arguments: [String], standardInput: Data? = nil, deadline: TimeInterval,
                                cancellation: CancellationState, captureLimit: Int?) throws -> ShellCommandResult {
        if cancellation.isCancelled { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return ShellCommandResult(status: -1, standardOutput: Data(), standardError: Data(), timedOut: true)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let input = standardInput == nil ? nil : Pipe()
        process.standardInput = input?.fileHandleForReading ?? FileHandle.nullDevice
        defer {
            try? input?.fileHandleForReading.close()
            try? input?.fileHandleForWriting.close()
        }
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let handles = [output.fileHandleForReading, error.fileHandleForReading]
        defer { handles.forEach { try? $0.close() } }
        let fds = handles.map(\.fileDescriptor)
        // A blocking read would bypass the deadline. Validate this before spawning a child.
        for fd in fds {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try process.run()
        let processReference = reference(process.processIdentifier)
        if let input, let standardInput {
            let fd = input.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            standardInput.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && errno == EINTR { continue }
                    else { break }
                }
            }
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
        }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        var streams = [Data(), Data()]
        var ended = [false, false]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var stoppingAt: TimeInterval?
        var timedOut = false
        var outputWasTruncated = false
        while true {
            // Bound each drain so an endlessly writing child cannot hide the deadline.
            for index in fds.indices where !ended[index] {
                for _ in 0..<16 {
                    let count = Darwin.read(fds[index], &buffer, buffer.count)
                    if count > 0 {
                        let bytes = buffer.prefix(count)
                        if let requested = captureLimit {
                            let limit = max(0, requested)
                            if streams[index].count + count > limit { outputWasTruncated = true }
                            if count >= limit { streams[index] = Data(bytes.suffix(limit)) }
                            else {
                                let overflow = max(0, streams[index].count + count - limit)
                                if overflow > 0 { streams[index].removeFirst(overflow) }
                                streams[index].append(contentsOf: bytes)
                            }
                        } else { streams[index].append(contentsOf: bytes) }
                    }
                    else if count == 0 { ended[index] = true; break }
                    else if errno == EINTR { continue }
                    else { break }
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            // Check the full budget even when a slow launch has already exited by this poll.
            if stoppingAt == nil, now >= deadline || cancellation.isCancelled {
                timedOut = now >= deadline
                stoppingAt = now
                if process.isRunning { process.terminate() }
            }
            if !process.isRunning && ended.allSatisfy({ $0 }) { break }
            if let stoppingAt {
                if !process.isRunning { break }
                if now - stoppingAt >= 0.25 { _ = kill(process.processIdentifier, SIGKILL) }
                if now - stoppingAt >= 1 { break }
            }
            var descriptors = fds.enumerated().map { index, fd in
                pollfd(fd: ended[index] ? -1 : fd, events: Int16(POLLIN), revents: 0)
            }
            _ = poll(&descriptors, nfds_t(descriptors.count), 20)
            // EOF pipes report immediately even while the child is still alive.
            if ended.contains(true) { Thread.sleep(forTimeInterval: 0.005) }
        }
        if cancellation.isCancelled {
            if process.isRunning { throw ShellCommandUnconfirmedTermination(process: processReference) }
            throw CancellationError()
        }
        return ShellCommandResult(status: process.isRunning ? -1 : process.terminationStatus,
            standardOutput: streams[0], standardError: streams[1], timedOut: timedOut,
            outputWasTruncated: outputWasTruncated, runningProcess: process.isRunning ? processReference : nil)
    }

    static func runSynchronously(executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellCommandResult {
        try execute(executable: executable, arguments: arguments,
                    deadline: ProcessInfo.processInfo.systemUptime + timeout,
                    cancellation: CancellationState(), captureLimit: 65536)
    }

    private static func reference(_ pid: Int32) -> ShellCommandProcessReference {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return .init(processIdentifier: pid, startSeconds: read == size ? info.pbi_start_tvsec : nil,
                     startMicroseconds: read == size ? info.pbi_start_tvusec : nil)
    }

    static func isRunning(_ process: ShellCommandProcessReference) throws -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        if proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size {
            if let seconds = process.startSeconds, let microseconds = process.startMicroseconds {
                return seconds == info.pbi_start_tvsec && microseconds == info.pbi_start_tvusec
            }
            return true
        }
        if kill(process.processIdentifier, 0) != 0, errno == ESRCH { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
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
        var isLocked: Bool = false

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
    private let ejectionInventoryOverride: (@Sendable () async throws -> ExternalDiskInventory)?

    /// - Parameter administratorRunner: diskutil 或还原时的 mount -u 被权限检查拒绝后，用它重试一次。
    ///   传 nil 表示不能弹出管理员授权框（后台代理）。
    init(
        runner: ShellCommandRunning = ProcessCommandRunner(),
        commandTimeout: TimeInterval = 180,
        ejectionInventory: (@Sendable () async throws -> ExternalDiskInventory)? = nil,
        administratorRunner: AdministratorRunner? = { try DiskUtility.runWithAdministratorPrivileges(executable: $0, arguments: $1) }
    ) {
        self.runner = runner
        self.commandTimeout = commandTimeout
        self.administratorRunner = administratorRunner
        self.ejectionInventoryOverride = ejectionInventory
    }

    /// 通过共享脚本执行管理员命令，短期保留同一授权会话；是否再次验证由系统决定。
    static func runWithAdministratorPrivileges(executable: String, arguments: [String]) throws -> ShellCommandResult {
        let command = ([executable] + arguments).map(shellQuoted).joined(separator: " ")
        return try AdministratorAuthorization.shared.run(command: command)
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

    func ejectionInventory() async throws -> ExternalDiskInventory {
        if let ejectionInventoryOverride { return try await ejectionInventoryOverride() }
        let list = try await runPlist(["list", "-plist"])
        let apfs = try await runPlist(["apfs", "list", "-plist"])
        return try ExternalDiskInventory.parse(list: list, apfs: apfs, connection: ExternalDiskInventory.connectionID)
    }

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
            isEncrypted: (plist["Encryption"] as? Bool == true)
                || (plist["Encrypted"] as? Bool == true) || (plist["FileVault"] as? Bool == true),
            isLocked: plist["Locked"] as? Bool == true
        )
    }

    // MARK: 卷操作

    /// Use DiskArbitration's normal add-volume operation, as in 1.9.0.
    /// Direct newfs_apfs access works on user-attached images but requires raw
    /// device privileges on physical disks. Application data uses noowners.
    func createAPFSVolume(inContainer container: String, name: String, encryption: APFSVolumeEncryption.Credentials? = nil) async throws -> String {
        guard container.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              !name.isEmpty else {
            throw Failure.unexpectedOutput(command: "diskutil apfs addVolume", output: "Invalid container or volume name")
        }
        let before = try await creationContainer(container)
        let arguments = ["apfs", "addVolume", container, "APFS", name, "-nomount"]
            + (encryption == nil ? [] : ["-stdinpassphrase"])
        let command = "diskutil " + arguments.joined(separator: " ")
        if let encryption { try await runWithPassphrase(arguments, passphrase: encryption.passphrase) }
        else { _ = try await run(arguments) }
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

    /// Sensitive operations never log output or place credentials in process arguments.
    private func runWithPassphrase(_ arguments: [String], passphrase: String) async throws {
        try APFSVolumeEncryption.validate(passphrase)
        let result = try await runner.run(executable: Self.diskutilPath, arguments: arguments,
                                          standardInput: Data((passphrase + "\n").utf8), timeout: commandTimeout)
        if let running = result.runningProcess { throw ShellCommandUnconfirmedTermination(process: running) }
        guard !result.timedOut, result.status == 0 else {
            throw APFSVolumeEncryption.Failure.commandFailed
        }
    }

    func unlockVolume(_ volume: String, passphrase: String) async throws {
        // Unlock without mounting; the existing anchored mount protocol chooses the destination.
        try await runWithPassphrase(["apfs", "unlockVolume", volume, "-user", "disk", "-stdinpassphrase", "-nomount"],
                                    passphrase: passphrase)
        let info = try await volumeInfo(for: volume)
        guard !info.isLocked else { throw APFSVolumeEncryption.Failure.commandFailed }
        if let uuid = info.volumeUUID { APFSVolumeEncryption.rememberVerifiedPassphrase(passphrase, for: uuid) }
    }

    func verifyPassphrase(_ volume: String, passphrase: String) async throws {
        try await runWithPassphrase(["apfs", "unlockVolume", volume, "-user", "disk", "-stdinpassphrase", "-verify"],
                                    passphrase: passphrase)
        if let uuid = (try await volumeInfo(for: volume)).volumeUUID {
            APFSVolumeEncryption.rememberVerifiedPassphrase(passphrase, for: uuid)
        }
    }

    func unlockIfNeeded(_ info: VolumeInfo) async throws {
        guard info.isEncrypted || info.isLocked else { return }
        guard let uuid = info.volumeUUID else {
            if info.isLocked { throw APFSVolumeEncryption.Failure.waitingForUnlock(info.deviceIdentifier) }
            return
        }
        // Pin available credentials before copying, even if the volume is currently unlocked.
        let passphrase = try? APFSVolumeEncryption.reusablePassphrase(for: uuid)
        guard info.isLocked else { return }
        guard let passphrase else { throw APFSVolumeEncryption.Failure.waitingForUnlock(uuid) }
        do { try await unlockVolume(uuid, passphrase: passphrase) }
        catch is CancellationError { throw CancellationError() }
        catch let pending as ShellCommandUnconfirmedTermination { throw pending }
        catch {
            APFSVolumeEncryption.forgetTransientPassphrase(for: uuid)
            throw APFSVolumeEncryption.Failure.waitingForUnlock(uuid)
        }
    }

    static func isVolumeLocked(_ volume: String) -> Bool {
        guard let result = try? ProcessCommandRunner.runSynchronously(executable: diskutilPath,
            arguments: ["info", "-plist", volume], timeout: 15), result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.standardOutput, format: nil) as? [String: Any]
        else { return false }
        return plist["Locked"] as? Bool == true
    }

    private struct CreationContainer {
        struct Volume { let uuid: String; let device: String; let name: String }
        let uuid: String
        let volumes: [Volume]
    }

    /// Record the container namespace before requesting a new volume. An
    /// interrupted creator can expose its intent without guessing a volume by name.
    func apfsCreationContainerUUID(_ reference: String) async throws -> String {
        try await creationContainer(reference).uuid
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


    /// UUID-based inventory makes cleanup retry distinguish deletion from an
    /// unplugged drive; a transient device identifier cannot supply that proof.
    func apfsContainerUUID(containingVolume volumeUUID: String) async throws -> String {
        let containers = try await apfsCleanupInventory()
        let matches = containers.filter { $0.volumes.contains(volumeUUID.uppercased()) }
        guard matches.count == 1, let match = matches.first else {
            throw Failure.unexpectedOutput(command: "diskutil apfs list", output: "Retained volume is unavailable or ambiguous")
        }
        return match.uuid
    }

    func apfsVolumeIsPresent(_ volumeUUID: String, inContainer containerUUID: String) async throws -> Bool {
        let containers = try await apfsCleanupInventory()
        guard let container = containers.first(where: { $0.uuid == containerUUID.uppercased() }) else {
            throw Failure.unexpectedOutput(command: "diskutil apfs list", output: "Retained volume's APFS container is offline")
        }
        guard !containers.contains(where: { $0.uuid != container.uuid && $0.volumes.contains(volumeUUID.uppercased()) }) else {
            throw Failure.unexpectedOutput(command: "diskutil apfs list", output: "Retained volume container changed")
        }
        return container.volumes.contains(volumeUUID.uppercased())
    }

    /// An unsuccessful creator may leave no volume at all. Proving absence in
    /// the original, online container ends that intent; a name never authorizes
    /// deleting or adopting an existing volume.
    func hasAPFSVolume(named name: String, inContainerUUID containerUUID: String) async throws -> Bool {
        let plist = try await runPlist(["apfs", "list", "-plist"])
        guard let containers = plist["Containers"] as? [[String: Any]] else {
            throw Failure.unexpectedOutput(command: "diskutil apfs list", output: "Missing APFS containers")
        }
        let matches = containers.filter { ($0["APFSContainerUUID"] as? String)?.caseInsensitiveCompare(containerUUID) == .orderedSame }
        guard matches.count == 1, let container = matches.first,
              let volumes = container["Volumes"] as? [[String: Any]],
              volumes.allSatisfy({ $0["Name"] is String && $0["APFSVolumeUUID"] is String }) else {
            throw Failure.unexpectedOutput(command: "diskutil apfs list", output: "Creation container is offline or unreadable")
        }
        return volumes.contains { $0["Name"] as? String == name }
    }

    /// One APFS query and one kernel mount-table snapshot for diagnostics.
    /// An invalid or failed query is propagated, never treated as an empty disk.
    func volumeStateSnapshot() async throws -> VolumeStateClassifier.Snapshot {
        // The ordinary command logger includes raw stdout. This diagnostic
        // query sees unrelated volume names, so neither log nor surface it.
        let result = try await runner.run(executable: Self.diskutilPath,
            arguments: ["apfs", "list", "-plist"], timeout: min(commandTimeout, 5))
        guard result.status == 0, !result.timedOut, !result.outputWasTruncated,
              let plist = try? PropertyListSerialization.propertyList(from: result.standardOutput, format: nil) as? [String: Any] else {
            throw Failure.unexpectedOutput(command: "diskutil apfs list", output: "Diagnostic inventory unavailable")
        }
        return try Self.parseVolumeStateSnapshot(plist, mounts: Self.kernelMountTable())
    }

    /// A fresh, caller-owned kernel snapshot includes hidden mounts and APFS
    /// snapshots, even after a bridge keeps its IOMedia object following eject.
    static func kernelMountTable() throws -> [String: String] {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&entries, MNT_NOWAIT)
        guard count > 0, let entries else {
            throw Failure.unexpectedOutput(command: "getmntinfo", output: "Mount inventory unavailable")
        }
        defer { free(entries) }
        var mounts: [String: String] = [:]
        for index in 0..<Int(count) {
            var entry = entries[index]
            let device = withUnsafePointer(to: &entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
            }
            let path = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
            }
            mounts[device] = path
        }
        return mounts
    }

    static func parseVolumeStateSnapshot(_ plist: [String: Any], mounts: [String: String]) throws -> VolumeStateClassifier.Snapshot {
        func invalid() -> Failure { .unexpectedOutput(command: "diskutil apfs list", output: "Invalid diagnostic inventory") }
        guard let containers = plist["Containers"] as? [[String: Any]] else { throw invalid() }
        var result: [String: VolumeStateClassifier.Volume] = [:]
        for container in containers {
            guard let volumes = container["Volumes"] as? [[String: Any]] else { throw invalid() }
            for volume in volumes {
                guard let uuid = volume["APFSVolumeUUID"] as? String, !uuid.isEmpty,
                      let device = volume["DeviceIdentifier"] as? String, !device.isEmpty,
                      let name = volume["Name"] as? String, result[uuid.uppercased()] == nil else { throw invalid() }
                result[uuid.uppercased()] = .init(uuid: uuid.uppercased(), name: name,
                    mountPoint: mounts["/dev/" + device], locked: volume["Locked"] as? Bool ?? false)
            }
        }
        return .init(volumes: result)
    }

    private func apfsCleanupInventory() async throws -> [(uuid: String, volumes: Set<String>)] {
        let plist = try await runPlist(["apfs", "list", "-plist"])
        guard let values = plist["Containers"] as? [[String: Any]] else {
            throw Failure.unexpectedOutput(command: "diskutil apfs list", output: "Missing container inventory")
        }
        var seenContainers: Set<String> = []
        var seenVolumes: Set<String> = []
        return try values.map { value in
            guard let uuid = value["APFSContainerUUID"] as? String, !uuid.isEmpty,
                  seenContainers.insert(uuid.uppercased()).inserted,
                  let volumes = value["Volumes"] as? [[String: Any]] else {
                throw Failure.unexpectedOutput(command: "diskutil apfs list", output: "Invalid container inventory")
            }
            let ids = try volumes.map { volume -> String in
                guard let id = volume["APFSVolumeUUID"] as? String, !id.isEmpty,
                      seenVolumes.insert(id.uppercased()).inserted else {
                    throw Failure.unexpectedOutput(command: "diskutil apfs list", output: "Invalid volume inventory")
                }
                return id.uppercased()
            }
            return (uuid.uppercased(), Set(ids))
        }
    }

    func mount(volume: String, at mountPoint: URL, requireOwnership: Bool = false, readOnly: Bool = false) async throws {
        let options = ["-mountOptions", requireOwnership ? "owners" : "noowners"]
        _ = try await run(["mount"] + (readOnly ? ["readOnly"] : [])
            + ["nobrowse", "-mountPoint", mountPoint.path] + options + [volume])
    }

    /// Explicit restore only. Keep Finder/safety flags while enabling real ownership.
    func setOwnershipForRestore(mountPoint: URL, originalFlags: UInt32, enabled: Bool) async throws {
        let flags = enabled ? originalFlags & ~UInt32(MNT_IGNORE_OWNERSHIP) : originalFlags
        var options = Self.updateOptions(addingNobrowseTo: flags)
        if enabled { options += ",owners" }
        _ = try await run(["-u", "-o", options, mountPoint.path], executable: Self.mountPath)
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

    struct DeletionAuthorizationEvidence {
        let ledger: URL
        let ledgerDigest: String
        let directories: [(URL, DataPathIdentity)]

        init(ledger: URL, directories: [URL]) throws {
            self.ledger = ledger
            ledgerDigest = SHA256.hash(data: try Data(contentsOf: ledger)).map { String(format: "%02x", $0) }.joined()
            self.directories = try directories.map { ($0, try DataPathIdentity.capture($0)) }
        }
    }

    /// Runs inside the authorized shell, AFTER any credential prompt. The
    /// ledger digest binds the already checked references and user choices;
    /// root identities preserve current data without forbidding new source writes.
    static func guardedDeletionScript(volumeUUID: String, device: String,
                                      evidence: DeletionAuthorizationEvidence,
                                      diskutilExecutable: String = diskutilPath) throws -> String {
        try guardedCandidateMutationScript(volumeUUID: volumeUUID, device: device, mountedAt: nil,
            evidence: evidence, diskutilExecutable: diskutilExecutable)
    }

    private static func guardedCandidateMutationScript(volumeUUID: String, device: String, mountedAt: URL?,
                                                        evidence: DeletionAuthorizationEvidence,
                                                        diskutilExecutable: String = diskutilPath) throws -> String {
        guard device.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil,
              !evidence.directories.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let diskCommand = shellQuoted(diskutilExecutable)
        let mountGuard = mountedAt.map { "[ \"$candidate_mount\" = \(shellQuoted($0.path)) ] || exit 73" }
            ?? "[ -z \"$candidate_mount\" ] || exit 73"
        let mutation = mountedAt == nil ? "apfs deleteVolume" : "unmount"
        var guards = [String]()
        for (url, identity) in evidence.directories {
            guard let device = identity.device, let inode = identity.inode else { throw CocoaError(.fileReadCorruptFile) }
            let path = shellQuoted(url.path)
            guards.append("[ ! -L \(path) ] && [ -d \(path) ] || exit 73")
            guards.append("[ \"$(/usr/bin/stat -f '%d:%i' \(path))\" = \(shellQuoted("\(device):\(inode)")) ] || exit 73")
        }
        return """
        set -eu
        candidate_info=$(\(diskCommand) info -plist \(shellQuoted(device)))
        candidate_field() { /usr/bin/printf '%s' "$candidate_info" | /usr/bin/plutil -extract "$1" raw -o - -; }
        [ "$(candidate_field DeviceIdentifier)" = \(shellQuoted(device)) ] || exit 73
        [ "$(candidate_field VolumeUUID | /usr/bin/tr '[:lower:]' '[:upper:]')" = \(shellQuoted(volumeUUID.uppercased())) ] || exit 73
        [ "$(candidate_field FilesystemType)" = apfs ] || exit 73
        [ "$(/usr/bin/printf '%s' "$candidate_info" | /usr/bin/plutil -type MountPoint -)" = string ] || exit 73
        candidate_mount=$(candidate_field MountPoint)
        \(mountGuard)
        \(guards.joined(separator: "\n"))
        [ ! -L \(shellQuoted(evidence.ledger.path)) ] || exit 73
        candidate_ledger_digest=$(/usr/bin/shasum -a 256 < \(shellQuoted(evidence.ledger.path)))
        [ "${candidate_ledger_digest%% *}" = \(shellQuoted(evidence.ledgerDigest)) ] || exit 73
        exec \(diskCommand) \(mutation) \(shellQuoted(device))
        """
    }

    /// A failed candidate may return at the system automount after reconnect.
    /// Bind the non-forced unmount to its exact device, UUID and current path,
    /// including inside the privileged process after the authorization prompt.
    func unmountCandidate(_ volumeUUID: String, at mountPoint: URL,
                          authorizationEvidence: DeletionAuthorizationEvidence,
                          beforeUnmount: @escaping () throws -> Void) async throws {
        let resolved = try await volumeInfo(for: volumeUUID)
        let device = resolved.deviceIdentifier
        func requireMountedIdentity(_ info: VolumeInfo) throws {
            guard info.isAPFS, info.deviceIdentifier == device,
                  info.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame,
                  info.mountPoint == mountPoint.path else {
                throw Failure.unexpectedOutput(command: "diskutil info", output: "Candidate identity or mount changed for \(volumeUUID)")
            }
        }
        try requireMountedIdentity(resolved)
        _ = try await run(["unmount", device], beforeAttempt: {
            try requireMountedIdentity(try await volumeInfo(for: device))
            try beforeUnmount()
        }, administratorFallback: { administrator in
            let script = try Self.guardedCandidateMutationScript(volumeUUID: volumeUUID, device: device,
                mountedAt: mountPoint, evidence: authorizationEvidence)
            return try administrator("/bin/sh", ["-c", script])
        })
    }

    func deleteAPFSVolume(_ volumeUUID: String, requireUnmounted: Bool = false,
                          authorizationEvidence: DeletionAuthorizationEvidence? = nil,
                          beforeDeletion: @escaping () throws -> Void = {}) async throws {
        // Resolve the recorded volume identity, then recheck its device before
        // deletion. A failed lookup never authorizes deletion by the input name.
        let resolved = try await volumeInfo(for: volumeUUID)
        let device = resolved.deviceIdentifier
        guard !volumeUUID.isEmpty, resolved.isAPFS,
              resolved.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame,
              !device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !requireUnmounted || (resolved.mountPoint?.isEmpty ?? true) else {
            throw Failure.unexpectedOutput(command: "diskutil info", output: "APFS volume identity does not match \(volumeUUID)")
        }
        _ = try await run(["apfs", "deleteVolume", device], beforeAttempt: {
            let current = try await volumeInfo(for: device)
            guard current.isAPFS, current.deviceIdentifier == device,
                  current.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame,
                  !requireUnmounted || (current.mountPoint?.isEmpty ?? true) else {
                throw Failure.unexpectedOutput(command: "diskutil info", output: "APFS device identity or mount changed for \(volumeUUID)")
            }
            try beforeDeletion()
        }, administratorFallback: { administrator in
            guard requireUnmounted else { return try administrator(Self.diskutilPath, ["apfs", "deleteVolume", device]) }
            guard let authorizationEvidence else {
                throw Failure.privilegeRequired(command: "diskutil apfs deleteVolume")
            }
            let script = try Self.guardedDeletionScript(volumeUUID: volumeUUID, device: device, evidence: authorizationEvidence)
            return try administrator("/bin/sh", ["-c", script])
        })
        APFSVolumeEncryption.removeSavedPassphrase(for: volumeUUID)
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
    private func run(_ arguments: [String], executable: String = Self.diskutilPath,
                     beforeAttempt: (() async throws -> Void)? = nil,
                     administratorFallback: ((AdministratorRunner) throws -> ShellCommandResult)? = nil) async throws -> ShellCommandResult {
        let command = URL(fileURLWithPath: executable).lastPathComponent + " " + arguments.joined(separator: " ")
        try await beforeAttempt?()
        var result = try await runner.run(executable: executable, arguments: arguments, timeout: commandTimeout)
        AppLogger.shared.logContext(
            "磁盘命令执行完成",
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
        // mount_apfs reports EX_NOPERM (77), rather than DiskArbitration's
        // kDAReturnNotPrivileged. Only mount accepts these POSIX diagnostics.
        let mountPermissionDenied = executable == Self.mountPath
            && (result.status == 77 || result.combinedText.localizedCaseInsensitiveContains("Operation not permitted")
                || result.combinedText.localizedCaseInsensitiveContains("Permission denied"))
        if result.status != 0, Self.indicatesPrivilegeFailure(result.combinedText) || mountPermissionDenied {
            try Task.checkCancellation()
            guard let administratorRunner else {
                AppLogger.shared.logContext(
                    "磁盘命令需要管理员权限，但当前环境无法提权",
                    details: [("command", command)],
                    level: "WARN"
                )
                throw Failure.privilegeRequired(command: command)
            }
            AppLogger.shared.logContext(
                "磁盘命令被权限检查拒绝，改用管理员权限重试",
                details: [("command", command)],
                level: "WARN"
            )
            try await beforeAttempt?()
            if let administratorFallback { result = try administratorFallback(administratorRunner) }
            else { result = try administratorRunner(executable, arguments) }
            AppLogger.shared.logContext(
                "磁盘命令（管理员权限）执行完成",
                details: [("command", command), ("status", String(result.status)), ("output", String(result.combinedText.prefix(2000)))],
                level: "TRACE"
            )
        }
        if result.timedOut { throw Failure.timedOut(command: command) }
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
