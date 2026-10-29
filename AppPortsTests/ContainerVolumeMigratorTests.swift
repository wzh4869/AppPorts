import Darwin
import Foundation
import Testing
@testable import AppPorts

/// 记录 diskutil 调用并按脚本返回结果；挂载状态用一张共享表模拟。
final class FakeDiskCommandRunner: ShellCommandRunning, @unchecked Sendable {
    struct Call: Codable, Equatable {
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var mountedPaths: Set<String> = []
    /// 卷 → 当前挂载路径。真实磁盘仲裁里一个卷同一时刻只能挂在一处。
    private var mountPathByVolume: [String: String] = [:]
    private var onlineVolumes: Set<String>
    private var containerReference: String
    private var externalFilesystem: String
    private var externalEncrypted: Bool
    private var failingCommandPrefix: [String]?
    private var privilegeDeniedPrefixes: [[String]] = []
    private var createdVolumeNames: [String: String] = [:]
    private var nextDeviceNumber = 9
    private let createdVolumeUUID: String?
    private var createdUUIDByDevice: [String: String] = [:]
    private var nextCreatedUUID: String?
    private var mountCommandCount = 0
    private var foreignAutomount: ForeignAutomount?
    private var hidesContentsOnUnmount = false
    private var stashedContents: [URL] = []
    private var underlyingDirectories: [String: URL] = [:]
    private var detachedVolumes: [String: URL] = [:]
    private var substitutedMount: (after: Int, volumeUUID: String)?
    private var commandMutation: CommandMutation?

    private struct CommandMutation {
        let arguments: [String]
        let mutation: @Sendable () throws -> Void
    }

    /// 模拟开机/插盘时系统抢先把卷挂到别处：第 `after` 次 mount 命令照样返回成功，
    /// 但卷实际落在 `path` 上（真实行为：卷已挂载时 diskutil 忽略 -mountPoint 参数）。
    private struct ForeignAutomount {
        let volume: String
        let path: String
        let after: Int
        let repeating: Bool
    }

    /// A process-restart probe persists only synthetic disks rooted in its
    /// temporary fixture. No diskutil invocation is replayed against macOS.
    private struct SimulationState: Codable {
        var recordedCalls: [Call]
        var mountedPaths: Set<String>
        var mountPathByVolume: [String: String]
        var onlineVolumes: Set<String>
        var containerReference: String
        var externalFilesystem: String
        var externalEncrypted: Bool
        var createdVolumeNames: [String: String]
        var nextDeviceNumber: Int
        var createdVolumeUUID: String?
        var createdUUIDByDevice: [String: String]?
        var mountCommandCount: Int
        var hidesContentsOnUnmount: Bool
        var stashedContents: [URL]
        var underlyingDirectories: [String: URL]
        var detachedVolumes: [String: URL]
    }

    func saveSimulationState(to url: URL) throws {
        lock.lock()
        let state = SimulationState(recordedCalls: recordedCalls, mountedPaths: mountedPaths,
            mountPathByVolume: mountPathByVolume, onlineVolumes: onlineVolumes, containerReference: containerReference,
            externalFilesystem: externalFilesystem, externalEncrypted: externalEncrypted,
            createdVolumeNames: createdVolumeNames, nextDeviceNumber: nextDeviceNumber, createdVolumeUUID: createdVolumeUUID,
            createdUUIDByDevice: createdUUIDByDevice,
            mountCommandCount: mountCommandCount, hidesContentsOnUnmount: hidesContentsOnUnmount,
            stashedContents: stashedContents, underlyingDirectories: underlyingDirectories, detachedVolumes: detachedVolumes)
        lock.unlock()
        try DurableFileIO.write(PropertyListEncoder().encode(state), to: url)
    }

    static func reopenSimulationState(from url: URL) throws -> FakeDiskCommandRunner {
        let state = try PropertyListDecoder().decode(SimulationState.self, from: Data(contentsOf: url))
        let runner = FakeDiskCommandRunner(containerReference: state.containerReference,
            externalFilesystem: state.externalFilesystem, externalEncrypted: state.externalEncrypted,
            onlineVolumes: state.onlineVolumes, createdVolumeUUID: state.createdVolumeUUID)
        runner.recordedCalls = state.recordedCalls
        runner.mountedPaths = state.mountedPaths
        runner.mountPathByVolume = state.mountPathByVolume
        runner.createdVolumeNames = state.createdVolumeNames
        runner.nextDeviceNumber = state.nextDeviceNumber
        runner.createdUUIDByDevice = state.createdUUIDByDevice ?? [:]
        runner.mountCommandCount = state.mountCommandCount
        runner.hidesContentsOnUnmount = state.hidesContentsOnUnmount
        runner.stashedContents = state.stashedContents
        runner.underlyingDirectories = state.underlyingDirectories
        runner.detachedVolumes = state.detachedVolumes
        return runner
    }

    init(containerReference: String = "disk7", externalFilesystem: String = "apfs", externalEncrypted: Bool = false, onlineVolumes: Set<String> = [], createdVolumeUUID: String? = nil) {
        self.containerReference = containerReference
        self.externalFilesystem = externalFilesystem
        self.externalEncrypted = externalEncrypted
        self.onlineVolumes = onlineVolumes
        self.createdVolumeUUID = createdVolumeUUID
    }

    func makeMountPointLease(at url: URL) throws -> any MountPointLeasing {
        try FakeMountPointLease(at: url, runner: self)
    }

    func physicalUnderlyingPath(for url: URL) -> URL {
        lock.lock(); defer { lock.unlock() }
        return underlyingDirectories[Self.normalized(url.path)] ?? url
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    func commands(prefix: [String]) -> [[String]] {
        calls.map(\.arguments).filter { Array($0.prefix(prefix.count)) == prefix }
    }

    /// 默认的假卷把挂载点目录本身当作卷内容。打开后更接近真实卸载：卷里的文件随卷离开挂载点，
    /// 只留下原来的空目录。用于验证还原不会递归删除挂载点下的东西。
    func hideContentsOnUnmount() {
        lock.lock(); defer { lock.unlock() }
        hidesContentsOnUnmount = true
    }

    /// 被真实卸载带走的卷内容，测试结束时一起清理。
    var stashedVolumeContents: [URL] {
        lock.lock(); defer { lock.unlock() }
        return stashedContents
    }

    /// The synthetic directory representing an unmounted volume; no native disk access.
    func detachedContents(for volumeUUID: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return detachedVolumes[volumeUUID]
    }

    private func volumeUUID(for device: String) -> String {
        createdUUIDByDevice[device] ?? createdVolumeUUID ?? "VOLUME-UUID-\(device)"
    }

    /// Distinct virtual APFS volumes can coexist without borrowing each
    /// other's UUID or deletion device in location-lineage tests.
    func useUUIDForNextCreatedVolume(_ uuid: String) {
        lock.lock(); defer { lock.unlock() }
        nextCreatedUUID = uuid
    }

    func failWhen(prefix: [String]) {
        lock.lock(); defer { lock.unlock() }
        failingCommandPrefix = prefix
    }

    func clearFailure() {
        lock.lock(); defer { lock.unlock() }
        failingCommandPrefix = nil
    }

    func mutateBeforeCommand(_ arguments: [String], mutation: @escaping @Sendable () throws -> Void) {
        lock.lock(); defer { lock.unlock() }
        commandMutation = CommandMutation(arguments: arguments, mutation: mutation)
    }

    /// 目标路径被不相干的卷抢占，而 mount 命令仍报告成功。
    func substituteForeignVolume(afterMountCommands count: Int, volumeUUID: String) {
        lock.lock(); defer { lock.unlock() }
        onlineVolumes.insert(volumeUUID)
        substitutedMount = (count, volumeUUID)
    }

    /// 模拟 macOS 12 的 DiskArbitration：普通用户执行这些命令会被拒绝，管理员身份可以。
    func denyUnprivileged(prefix: [String]) {
        lock.lock(); defer { lock.unlock() }
        privilegeDeniedPrefixes.append(prefix)
    }

    /// 供 `DiskUtility.administratorRunner` 使用：记录提权调用并按正常逻辑执行。
    func runAsAdministrator(executable: String, arguments: [String]) throws -> ShellCommandResult {
        lock.lock(); defer { lock.unlock() }
        recordedCalls.append(Call(arguments: ["sudo"] + arguments))
        return execute(arguments)
    }

    func mountedUUID(at url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return mountPathByVolume.first { Self.normalized($0.value) == Self.normalized(url.path) }?.key
    }

    /// 模拟 macOS 开机/插盘时把卷自动挂到 /Volumes 下。
    func markVolumeMounted(_ volume: String, at path: String) {
        lock.lock(); defer { lock.unlock() }
        mountPathByVolume[volume] = path
        mountedPaths.insert(Self.normalized(path))
    }

    /// Model a pre-existing mounted root without moving its contents. Future
    /// unmount/mount calls preserve the volume inode and reveal this empty root.
    func modelUnderlyingDirectory(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let path = Self.normalized(url.path)
        guard mountedPaths.contains(path), underlyingDirectories[path] == nil else { throw CocoaError(.fileWriteUnknown) }
        let underlying = url.deletingLastPathComponent().appendingPathComponent(".fake-underlying-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: underlying, withIntermediateDirectories: false)
        underlyingDirectories[path] = underlying
    }

    func markOnline(_ volume: String) {
        lock.lock(); defer { lock.unlock() }
        onlineVolumes.insert(volume)
        if let device = createdUUIDByDevice.first(where: { $0.value == volume })?.key { onlineVolumes.insert(device) }
    }

    func markOffline(_ volume: String) {
        lock.lock(); defer { lock.unlock() }
        onlineVolumes.remove(volume)
        if let device = createdUUIDByDevice.first(where: { $0.value == volume })?.key { onlineVolumes.remove(device) }
    }

    func simulateForeignAutomount(volume: String, at path: String, afterMountCommands: Int, repeating: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        foreignAutomount = ForeignAutomount(volume: volume, path: path, after: afterMountCommands, repeating: repeating)
    }

    func isMounted(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mountedPaths.contains(Self.normalized(url.path))
    }

    /// 临时目录会以 /var 与 /private/var 两种写法出现，统一按解析后的路径比较。
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        try runSynchronously(arguments: arguments)
    }

    private func runSynchronously(arguments: [String]) throws -> ShellCommandResult {
        lock.lock(); defer { lock.unlock() }
        recordedCalls.append(Call(arguments: arguments))
        if let failingCommandPrefix, Array(arguments.prefix(failingCommandPrefix.count)) == failingCommandPrefix {
            return failure("forced failure for \(arguments.joined(separator: " "))")
        }
        if privilegeDeniedPrefixes.contains(where: { Array(arguments.prefix($0.count)) == $0 }) {
            return failure("Volume on disk7s9 failed to mount\nPerhaps the operation is not allowed by the invoking user (kDAReturnNotPrivileged)")
        }
        if let pending = commandMutation, pending.arguments == arguments {
            commandMutation = nil
            try pending.mutation()
        }
        return execute(arguments)
    }

    /// 调用方必须已持有 lock。
    private func execute(_ arguments: [String]) -> ShellCommandResult {
        let command = arguments.first ?? ""
        let subcommand = arguments.dropFirst().first ?? ""
        switch command {
        case "info":
            let target = arguments.last ?? ""
            if target.hasPrefix("/") {
                return success(plist: [
                    "DeviceIdentifier": "disk7s1",
                    "VolumeUUID": mountPathByVolume.first { Self.normalized($0.value) == Self.normalized(target) }?.key ?? "EXTERNAL-UUID",
                    "VolumeName": "hano",
                    "FilesystemType": externalFilesystem,
                    "Encrypted": externalEncrypted,
                    "APFSContainerReference": containerReference,
                    "MountPoint": target
                ])
            }
            guard onlineVolumes.contains(target) else { return failure("Could not find disk: \(target)") }
            let device = target.hasPrefix("disk") ? target
                : createdUUIDByDevice.first(where: { $0.value == target })?.key ?? "disk7s\(nextDeviceNumber)"
            var plist: [String: Any] = [
                "DeviceIdentifier": device,
                "VolumeUUID": target.hasPrefix("disk") ? volumeUUID(for: target) : target,
                "VolumeName": "AppPortsTest",
                "FilesystemType": "apfs",
                "APFSContainerReference": containerReference
            ]
            if let mountPath = mountPathByVolume[target.hasPrefix("disk") ? volumeUUID(for: target) : target] {
                plist["MountPoint"] = mountPath
            }
            return success(plist: plist)
        case "apfs" where subcommand == "list":
            let volumes = createdVolumeNames.map { device, name in
                ["APFSVolumeUUID": volumeUUID(for: device), "DeviceIdentifier": device, "Name": name]
            }
            return success(plist: ["Containers": [["ContainerReference": containerReference, "APFSContainerUUID": "TEST-CONTAINER-UUID", "Volumes": volumes]]])
        case "apfs" where subcommand == "addVolume":
            while createdVolumeNames["disk7s\(nextDeviceNumber)"] != nil { nextDeviceNumber += 1 }
            let device = "disk7s\(nextDeviceNumber)"
            createdUUIDByDevice[device] = nextCreatedUUID ?? createdVolumeUUID ?? "VOLUME-UUID-\(device)"
            nextCreatedUUID = nil
            onlineVolumes.insert(device)
            onlineVolumes.insert(volumeUUID(for: device))
            createdVolumeNames[device] = arguments.dropFirst(4).first ?? "AppPortsTest"
            return success(text: "Will export new APFS Volume from APFS Container Reference \(containerReference)\nCreated new APFS Volume \(device)\n")
        case "apfs" where subcommand == "deleteVolume":
            let target = arguments.last ?? ""
            let volume = target.hasPrefix("disk") ? volumeUUID(for: target) : target
            let device = createdVolumeNames.keys.first { $0 == target || volumeUUID(for: $0) == volume } ?? target
            let identifiers = Set([target, volume, device])
            // Deleting the synthetic volume also destroys its detached payload;
            // a later volume reusing this fixture UUID must start empty.
            do {
                for identifier in identifiers {
                    if let contents = detachedVolumes[identifier] {
                        try FileManager.default.removeItem(at: contents)
                        detachedVolumes.removeValue(forKey: identifier)
                    }
                }
            } catch { return failure(error.localizedDescription) }
            for identifier in identifiers {
                onlineVolumes.remove(identifier)
                createdVolumeNames.removeValue(forKey: identifier)
                createdUUIDByDevice.removeValue(forKey: identifier)
            }
            return success(text: "Removed APFS Volume \(target)\n")
        case "mount":
            guard [5, 7].contains(arguments.count), arguments[1] == "nobrowse", arguments[2] == "-mountPoint" else { return failure("bad mount arguments") }
            if arguments.count == 7, (arguments[4] != "-mountOptions" || !["owners", "noowners"].contains(arguments[5])) { return failure("bad ownership arguments") }
            let volume = arguments.last!
            guard onlineVolumes.contains(volume) else { return failure("Volume \(volume) not found") }
            mountCommandCount += 1
            if let substitute = substitutedMount, mountCommandCount == substitute.after {
                let path = arguments[3]
                do { try overlay(volume: substitute.volumeUUID, at: URL(fileURLWithPath: path)) }
                catch { return failure(error.localizedDescription) }
                mountPathByVolume[substitute.volumeUUID] = path
                mountedPaths.insert(Self.normalized(path))
                try? Data("unrelated data".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("foreign.txt"))
                return success(text: "Volume mounted\n")
            }
            if let plan = foreignAutomount, plan.volume == volume, mountCommandCount >= plan.after {
                mountPathByVolume[volume] = plan.path
                mountedPaths.insert(Self.normalized(plan.path))
                if !plan.repeating { foreignAutomount = nil }
                return success(text: "Volume \(volume) on \(plan.path) mounted\n")
            }
            // 卷已挂载时 diskutil 忽略挂载点参数并报告成功，挂载点不会真的出现。
            if let existing = mountPathByVolume[volume] {
                return success(text: "Volume \(volume) on \(existing) mounted\n")
            }
            do { try overlay(volume: volume, at: URL(fileURLWithPath: arguments[3])) }
            catch { return failure(error.localizedDescription) }
            mountPathByVolume[volume] = arguments[3]
            mountedPaths.insert(Self.normalized(arguments[3]))
            return success(text: "Volume mounted\n")
        case "-u":
            // /sbin/mount -u -o <选项> <挂载点>：只改标志，挂载关系不变。
            return success(text: "")
        case "unmount":
            let target = arguments.last ?? ""
            let targetVolume = target.hasPrefix("disk") ? volumeUUID(for: target) : target
            let path = Self.normalized(mountPathByVolume[targetVolume] ?? target)
            let volume = mountPathByVolume.first(where: { Self.normalized($0.value) == path })?.key
            guard mountedPaths.contains(path) else { return failure("\(path) was not mounted") }
            do {
                if let volume, let underlying = underlyingDirectories[path] {
                    let visible = URL(fileURLWithPath: path)
                    let detached = visible.deletingLastPathComponent().appendingPathComponent(".fake-volume-\(UUID())")
                    try FileManager.default.moveItem(at: visible, to: detached)
                    try FileManager.default.moveItem(at: underlying, to: visible)
                    detachedVolumes[volume] = detached
                    underlyingDirectories.removeValue(forKey: path)
                } else if hidesContentsOnUnmount {
                    stashContents(of: URL(fileURLWithPath: path))
                }
            } catch { return failure(error.localizedDescription) }
            if let volume { mountPathByVolume.removeValue(forKey: volume) }
            mountedPaths.remove(path)
            return success(text: "Volume unmounted\n")
        default:
            return failure("unsupported command \(arguments.joined(separator: " "))")
        }
    }

    /// Virtual overlay: move the local directory aside and place a distinct synthetic
    /// volume directory at the visible root. The lease tracks the hidden local object.
    /// No native mounts occur; every materialized path comes from a synthetic fixture.
    private func overlay(volume: String, at mountPoint: URL) throws {
        let key = Self.normalized(mountPoint.path)
        let underlying = mountPoint.deletingLastPathComponent().appendingPathComponent(".fake-underlying-\(UUID())")
        try FileManager.default.moveItem(at: mountPoint, to: underlying)
        let contents: URL
        if let previous = detachedVolumes.removeValue(forKey: volume) { contents = previous }
        else {
            contents = mountPoint.deletingLastPathComponent().appendingPathComponent(".fake-volume-\(UUID())")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
        }
        do { try DataTreeRelocator.move(contents, to: mountPoint) }
        catch { try? FileManager.default.moveItem(at: underlying, to: mountPoint); throw error }
        underlyingDirectories[key] = underlying
    }

    /// 调用方必须已持有 lock。
    private func stashContents(of mountPoint: URL) {
        let stash = FileManager.default.temporaryDirectory.appendingPathComponent("FakeVolumeContents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stash, withIntermediateDirectories: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)) ?? []
        for entry in entries {
            try? FileManager.default.moveItem(at: mountPoint.appendingPathComponent(entry), to: stash.appendingPathComponent(entry))
        }
        stashedContents.append(stash)
    }

    private func success(text: String) -> ShellCommandResult {
        ShellCommandResult(status: 0, standardOutput: Data(text.utf8), standardError: Data(), timedOut: false)
    }

    private func success(plist: [String: Any]) -> ShellCommandResult {
        let data = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
        return ShellCommandResult(status: 0, standardOutput: data, standardError: Data(), timedOut: false)
    }

    private func failure(_ message: String) -> ShellCommandResult {
        ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data(message.utf8), timedOut: false)
    }
}

@Suite("Container volume migration", .serialized)
struct ContainerVolumeMigratorTests {
    @Test("Cold remount upgrades legacy guards while paused or offline, including retained migrations",
          arguments: [false, true], [false, true])
    func upgradeLegacyOfflineGuard(paused: Bool, retainedMigration: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "LegacyGuard")
        let runner = FakeDiskCommandRunner(onlineVolumes: ["VOLUME-UUID-disk7s9"])
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        let migrator = workspace.makeMigrator(runner: runner)
        let record: ContainerMountRecord
        if retainedMigration {
            let moved = try await migrator.migrate(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
                appName: "Chat", bundleIdentifier: "com.example.chat", progressHandler: nil)
            record = moved.record
            try await migrator.unmount(record: record)
            runner.markOffline(record.volumeUUID)
            try #require(try !workspace.store.transfers().isEmpty)
        } else {
            try FileManager.default.removeItem(at: source.appendingPathComponent("payload.txt"))
            record = makeRecord(mountPoint: source, uuid: "OFFLINE", volumeName: "AppPorts-offline", workspace: workspace)
            try workspace.store.upsert(record)
        }
        try workspace.store.setManuallyUnmounted(paused, record: record)
        try #require(chmod(source.path, 0) == 0)
        let identity = try DataPathIdentity.capture(source)
        let ledger = try Data(contentsOf: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        let mounts = runner.commands(prefix: ["mount"])
        let unmounts = runner.commands(prefix: ["unmount"])
        let outcomes = await migrator.remountAvailableRecords()
        #expect(outcomes.count == 1)
        if paused {
            guard case .requiresIntervention = outcomes.first?.state else { Issue.record("Pause must remain active"); return }
        } else { #expect(outcomes.first?.state == .unavailable) }
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int == 0o500)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty)
        #expect(try DataPathIdentity.capture(source) == identity)
        #expect(try Data(contentsOf: workspace.rootURL.appendingPathComponent("container-mounts.plist")) == ledger)
        #expect(runner.commands(prefix: ["mount"]) == mounts)
        #expect(runner.commands(prefix: ["unmount"]) == unmounts)
    }

    @Test("Legacy guard upgrade preserves unexpected local contents and permissions")
    func legacyGuardUpgradeRejectsLocalContent() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "NonemptyLegacyGuard")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        try workspace.store.setManuallyUnmounted(true, record: record)
        try #require(chmod(source.path, 0) == 0)
        let runner = FakeDiskCommandRunner()
        let outcomes = await workspace.makeMigrator(runner: runner).remountAvailableRecords()
        guard case .failed = outcomes.first?.state else { Issue.record("A nonempty legacy guard must remain blocked"); return }
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int == 0)
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        try #require(chmod(source.path, 0o700) == 0)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("Manual unmount survives a cold store, isolates other volumes, and explicit mount resumes")
    func manualUnmountPersistsAndResumes() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "ManualPause")
        let other = try workspace.makeContainerDirectory(named: "OtherVolume")
        for url in [source, other] { try FileManager.default.removeItem(at: url.appendingPathComponent("payload.txt")) }
        let record = workspace.record(mountPoint: source, volumeUUID: "PAUSED-UUID")
        let otherRecord = workspace.record(mountPoint: other, volumeUUID: "OTHER-UUID")
        try workspace.store.upsert(record)
        try workspace.store.upsert(otherRecord)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID, otherRecord.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        try await workspace.makeMigrator(runner: runner).unmount(record: record)
        #expect(!runner.isMounted(source))
        let reopened = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        #expect(try reopened.isManuallyUnmounted(record))
        let cold = workspace.makeMigrator(runner: runner, storeOverride: reopened)
        let outcomes = await cold.remountAvailableRecords()
        #expect(outcomes.contains { $0.record == record && $0.state == .requiresIntervention(ManualMountPauseError.paused.localizedDescription) })
        #expect(!runner.isMounted(source))
        #expect(runner.isMounted(other))
        await #expect(throws: ManualMountPauseError.self) { try await cold.mount(record: record) }
        runner.failWhen(prefix: ["mount"])
        await #expect(throws: (any Error).self) { try await cold.mount(record: record, resumingManualPause: true) }
        #expect(try reopened.isManuallyUnmounted(record))
        runner.clearFailure()
        try await cold.mount(record: record, resumingManualPause: true)
        #expect(runner.isMounted(source))
        #expect(try !reopened.isManuallyUnmounted(record))
    }

    @Test("Pause save failure prevents unmount; an unmount failure retains saved intent", arguments: [true, false])
    func manualUnmountFailurePreservesIntent(saveFails: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "PauseFailure")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        let store = saveFails ? ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"),
            writeData: { _, _ in throw CocoaError(.fileWriteUnknown) }) : workspace.store
        if !saveFails { runner.failWhen(prefix: ["unmount"]) }
        await #expect(throws: (any Error).self) { try await workspace.makeMigrator(runner: runner, storeOverride: store).unmount(record: record) }
        #expect(runner.isMounted(source))
        #expect(try workspace.store.isManuallyUnmounted(record) == !saveFails)
        if saveFails { #expect(runner.commands(prefix: ["unmount"]).isEmpty) }
    }

    @Test("Cold automatic recovery leaves a manually paused restore untouched")
    func manualPauseBlocksColdRestoreRecovery() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "PausedRestore")
        try FileManager.default.removeItem(at: source.appendingPathComponent("payload.txt"))
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        try seedUnstartedRestore(unstartedRestore(workspace, record), store: workspace.store)
        try workspace.store.setManuallyUnmounted(true, record: record)
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        let before = try Data(contentsOf: file)
        let reopened = ContainerMountStore(fileURL: file)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        let migrator = workspace.makeMigrator(runner: runner, storeOverride: reopened)
        #expect(await migrator.performAutomaticMaintenance() == [])
        let outcomes = await migrator.remountAvailableRecords()
        #expect(outcomes.map(\.state) == [.requiresIntervention(ManualMountPauseError.paused.localizedDescription)])
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty)
    }

    @Test("Explicit retry reports a manual pause without changing recovery or cleanup intent")
    @MainActor
    func explicitPausedRetryIsNotReportedAsComplete() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "PausedExplicitRetry")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        let pending = unstartedRestore(workspace, record)
        try seedUnstartedRestore(pending, store: workspace.store)
        try workspace.store.setManuallyUnmounted(true, record: record)
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        let before = try Data(contentsOf: file)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        let migrator = workspace.makeMigrator(runner: runner)
        #expect(await migrator.performAutomaticMaintenance(only: pending.operationID, ignoresRetryBackoff: true)
            == [ManualMountPauseError.retryPaused.localizedDescription])
        #expect(try Data(contentsOf: file) == before)
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(await migrator.performAutomaticMaintenance() == [])

        // Exercise the real retry-result handoff to task history, not just the warning string.
        let history = MigrationTaskHistoryStore(fileURL: workspace.rootURL.appendingPathComponent("retry-history.json"))
        let lockURL = workspace.rootURL.appendingPathComponent("retry-operation.lock")
        let center = MigrationTaskCenter(historyStore: history, operationState: AppOperationState(),
            makeOperationLock: { OperationLock(fileURL: lockURL) })
        center.submit(title: "Paused retry", category: .appData,
            resources: MigrationResources(paths: [source])) { _ in
                let warnings = await migrator.performAutomaticMaintenance(only: pending.operationID, ignoresRetryBackoff: true)
                return warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
            }
        let job = try #require(center.detail)
        let worker = try #require(job.worker)
        await worker.value
        #expect(job.status == .attention)
        #expect(job.message == ManualMountPauseError.retryPaused.localizedDescription)
        #expect(history.load().first?.status == .attention)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("Resuming a still-mounted volume clears pause without unmounting or remounting")
    func resumeAutomaticMountingAfterFailedUnmount() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "FailedUnmountResume")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        runner.failWhen(prefix: ["unmount"])
        let migrator = workspace.makeMigrator(runner: runner)
        await #expect(throws: (any Error).self) { try await migrator.unmount(record: record) }
        #expect(try workspace.store.isManuallyUnmounted(record))
        let unmounts = runner.commands(prefix: ["unmount"])
        try await migrator.mount(record: record, resumingManualPause: true)
        #expect(try !workspace.store.isManuallyUnmounted(record))
        #expect(runner.isMounted(source))
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("Ownership recovery checks the local parent before detaching a usable data volume")
    func ownershipRecoveryChecksParentBeforeUnmount() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "PermissionBoundary")
        let record = workspace.record(mountPoint: source)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        try runner.modelUnderlyingDirectory(at: source)
        let parent = source.deletingLastPathComponent()
        // A traversable but unreadable local parent models the permission gap:
        // the mounted external root is readable, its local parent cannot open.
        try #require(chmod(parent.path, 0o100) == 0)
        defer { _ = chmod(parent.path, 0o700) }
        let current = UInt32(MNT_DONTBROWSE | MNT_NODEV | MNT_NOSUID)
        let mover = workspace.makeMigrator(runner: runner, mountFlags: { _ in current })

        await #expect(throws: (any Error).self) {
            try await mover.restoreOriginalMountOptions(mountPoint: source, volumeUUID: record.volumeUUID,
                originalFlags: current | UInt32(MNT_IGNORE_OWNERSHIP))
        }

        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.mountedUUID(at: source) == record.volumeUUID)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("payload".utf8))
    }

    @Test("A denied destination lease leaves a volume at its existing usable location")
    func deniedMountTargetDoesNotDetachSource() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let target = try workspace.makeContainerDirectory(named: "DeniedTarget")
        try FileManager.default.removeItem(at: target.appendingPathComponent("payload.txt"))
        let current = try workspace.makeContainerDirectory(named: "UsableSource")
        let record = workspace.record(mountPoint: target)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: current.path)
        let mover = workspace.makeMigrator(runner: runner, makeMountPointLease: { _ in throw POSIXError(.EPERM) })

        await #expect(throws: (any Error).self) {
            try await mover.mountVolume(record.volumeUUID, at: target, operationID: "denied-target",
                knownMountPoint: .mounted(at: current))
        }

        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.mountedUUID(at: current) == record.volumeUUID)
        #expect(try Data(contentsOf: current.appendingPathComponent("payload.txt")) == Data("payload".utf8))
    }

    @Test("Parent access lost after copying stops ordinary restore before detaching its source and can retry")
    func restoreChecksParentAgainAfterCopy() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "LatePermissionFailure")
        let parent = source.deletingLastPathComponent()
        defer { _ = chmod(parent.path, 0o700) }
        // Recovery verifies the native filesystem UUID even with a simulated
        // disk runner. Use this fixture's real namespace, never bypass that check.
        let fixtureVolumeUUID = try #require(DiskUtility.mountedVolumeUUID(at: source))
        let runner = FakeDiskCommandRunner(createdVolumeUUID: fixtureVolumeUUID)
        let mover = workspace.makeMigrator(runner: runner)
        let migration = try await mover.migrateAndComplete(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        try Data("latest application write".utf8).write(to: source.appendingPathComponent("payload.txt"))
        let unmounts = runner.commands(prefix: ["unmount"])

        await #expect(throws: (any Error).self) {
            try await mover.restore(record: migration.record, estimatedTotalBytes: 0) { progress in
                if progress.currentFile == "正在切换本地入口...".localized {
                    #expect(chmod(parent.path, 0o100) == 0)
                }
            }
        }

        #expect(runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(runner.mountedUUID(at: source) == migration.record.volumeUUID)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("latest application write".utf8))
        #expect(try workspace.store.recordsStrict() == [migration.record])
        #expect(chmod(parent.path, 0o700) == 0)
        #expect(try await mover.restoreAndComplete(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil) == nil)
        #expect(!runner.isMounted(source))
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("latest application write".utf8))
        #expect(try workspace.store.transfers().isEmpty)
    }

    @Test("A partial restore reconnects its current source without treating its own journal as an overlap")
    func partialRestoreReconnectPreservesNewData() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "InterruptedCopy")
        var record = workspace.record(mountPoint: source)
        record.ownershipPolicy = .owners
        try workspace.store.upsert(record)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        try runner.modelUnderlyingDirectory(at: source)
        var pending = unstartedRestore(workspace, record)
        pending.phase = .copying
        pending.sourceIdentity = try DataPathIdentity.capture(source, volumeUUID: record.volumeUUID)
        pending.sourceBaseline = try PropertyListEncoder().encode(TreeCopySession.snapshot(at: source))
        pending.recoveryMountRecord = record
        pending.originalSourceMountFlags = UInt32(MNT_DONTBROWSE)
        let staging = URL(fileURLWithPath: try #require(pending.stagingPath))
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("pay".utf8).write(to: staging.appendingPathComponent("payload.txt"))
        pending.destinationIdentity = try DataPathIdentity.capture(staging)
        pending.preparationPath = staging.path
        pending.preparationParentIdentity = try DataPathIdentity.capture(staging.deletingLastPathComponent())
        try seedUnstartedRestore(pending, store: workspace.store)
        try Data("latest active data".utf8).write(to: source.appendingPathComponent("payload.txt"))
        _ = try await runner.run(executable: "/usr/sbin/diskutil", arguments: ["unmount", source.path], timeout: 5)
        let cold = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        let mover = workspace.makeMigrator(runner: runner, storeOverride: cold)

        let outcomes = await mover.remountAvailableRecords()

        #expect(outcomes.map(\.state) == [.mounted])
        #expect(runner.mountedUUID(at: source) == record.volumeUUID)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("latest active data".utf8))
        #expect(try Data(contentsOf: staging.appendingPathComponent("payload.txt")) == Data("pay".utf8))
        #expect(try cold.transfer(operationID: pending.operationID)?.rollbackCompletedAt != nil)
        _ = try await runner.run(executable: "/usr/sbin/diskutil", arguments: ["unmount", source.path], timeout: 5)
        #expect(await mover.remountAvailableRecords().map(\.state) == [.mounted])
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("latest active data".utf8))
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("Legacy remount explicitly ignores ownership; modern remount requires owners", arguments: [false, true])
    func remountOwnershipPolicy(modern: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["OWNERSHIP-UUID"])
        let source = try workspace.makeContainerDirectory(named: "Policy")
        try FileManager.default.removeItem(at: source.appendingPathComponent("payload.txt"))
        var record = workspace.record(mountPoint: source, volumeUUID: "OWNERSHIP-UUID")
        record.ownershipPolicy = modern ? .owners : nil
        try workspace.store.upsert(record)
        let migrator = workspace.makeMigrator(runner: runner)
        try await migrator.mount(record: record)
        let options = ["-mountOptions", modern ? "owners" : "noowners"]
        #expect(runner.commands(prefix: ["mount"]) == [["mount", "nobrowse", "-mountPoint", source.path] + options + [record.volumeUUID]])

        let noowners = workspace.makeMigrator(runner: runner, mountFlags: { _ in UInt32(MNT_IGNORE_OWNERSHIP) })
        if modern {
            await #expect(throws: (any Error).self) { try await noowners.mount(record: record) }
        } else {
            try await noowners.mount(record: record)
        }
        #expect(runner.commands(prefix: ["-u"]).isEmpty)
    }

    @Test("A cold remount recovers an unstarted restore without discarding its history", arguments: [false, true])
    func remountAfterUnstartedRestore(intervention: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Interrupted")
        try FileManager.default.removeItem(at: source.appendingPathComponent("payload.txt"))
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        let pending = unstartedRestore(workspace, record)
        try seedUnstartedRestore(pending, store: workspace.store)
        if intervention { try workspace.store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: "Old overlap failure") }
        let saved = try workspace.store.transfers()
        let cold = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        let outcomes = await workspace.makeMigrator(runner: runner, storeOverride: cold).remountAvailableRecords()
        #expect(outcomes.map(\.state) == [.mounted])
        #expect(runner.isMounted(source))
        #expect(try cold.transfers() == saved)
        #expect(try cold.remountIntervention(forVolumeUUID: record.volumeUUID) == nil)
    }

    @Test("A mounted-volume intervention is never cleared by an unstarted restore")
    func remountPreservesMountedIntervention() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Conflict")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        try seedUnstartedRestore(unstartedRestore(workspace, record), store: workspace.store)
        try workspace.store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: "Underlying directory changed during mount")
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        let outcomes = await workspace.makeMigrator(runner: runner).remountAvailableRecords()
        #expect(outcomes.map(\.state) == [.requiresIntervention("Underlying directory changed during mount")])
        #expect(try workspace.store.remountIntervention(forVolumeUUID: record.volumeUUID) != nil)
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
    }

    @Test("Remount rejects restore intents that have saved identity or nonstandard paths", arguments: ["identity", "path"])
    func remountRefusesAdvancedRestore(kind: String) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Interrupted")
        try FileManager.default.removeItem(at: source.appendingPathComponent("payload.txt"))
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        var pending = unstartedRestore(workspace, record)
        if kind == "identity" { pending.recoveryMountPointIdentity = try DataPathIdentity.capture(workspace.rootURL) }
        if kind == "path" { pending.stagingPath = workspace.rootURL.appendingPathComponent("unexpected-staging").path }
        try seedUnstartedRestore(pending, store: workspace.store)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        let saved = try workspace.store.transfers()
        let outcomes = await workspace.makeMigrator(runner: runner).remountAvailableRecords()
        guard case .failed = outcomes.first?.state else { Issue.record("Must not relax advanced restore intent"); return }
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(try workspace.store.transfers() == saved)
    }

    @Test("Automatic recovery preserves conflicting restore artifacts", arguments: ["staging", "recovery", "symlink", "local"])
    func remountRefusesRestoreArtifacts(kind: String) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Interrupted")
        try FileManager.default.removeItem(at: source.appendingPathComponent("payload.txt"))
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        let pending = unstartedRestore(workspace, record)
        try seedUnstartedRestore(pending, store: workspace.store)
        try workspace.store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: "Old overlap failure")
        let path = kind == "local" ? source.appendingPathComponent("new-local-data").path :
            (kind == "recovery" ? pending.backupPath! : pending.stagingPath!)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        if kind == "symlink" { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "absent-target") }
        else { try Data("keep".utf8).write(to: URL(fileURLWithPath: path)) }
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        let saved = try workspace.store.transfers()
        let outcomes = await workspace.makeMigrator(runner: runner).remountAvailableRecords()
        guard case .failed = outcomes.first?.state else { Issue.record("Must keep conflicting data blocked"); return }
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(try workspace.store.transfers() == saved)
        if kind != "symlink" { #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("keep".utf8)) }
    }

    @Test("Verified older migration keeps its owners policy after transfer cleanup and stale writes")
    func ownershipSurvivesTransferCleanup() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let migrator = workspace.makeMigrator(runner: runner)
        let source = try workspace.makeContainerDirectory(named: "Policy")
        let result = try await migrator.migrate(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Chat", bundleIdentifier: "com.example.chat", progressHandler: nil)
        #expect(result.record.ownershipPolicy == nil)
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        var document = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        var mounts = try #require(document["mounts"] as? [[String: Any]])
        mounts[0].removeValue(forKey: "ownershipPolicy")
        document["mounts"] = mounts
        var transfers = try #require(document["transfers"] as? [[String: Any]])
        // A real schema-3 writer predates recovery records and copy-creation
        // evidence. Keep its opaque verified baseline, as the old format did.
        let newerFields = ["recoveryMountRecord", "sourceBaseline", "preparationPath", "preparationParentIdentity",
                           "stagingParentIdentity", "stagingIdentity", "volumeCreationContainerUUID", "volumeCreationName",
                           "originalSourceMountFlags", "preparationRemovalBaseline", "preparationRemovalParentIdentity",
                           "candidateActivationAttempted", "candidateRemovalMountPointIdentity"]
        for index in transfers.indices {
            for field in newerFields { transfers[index].removeValue(forKey: field) }
        }
        document["transfers"] = transfers
        document["schemaVersion"] = 3
        let legacyBytes = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        try legacyBytes.write(to: file)
        let old = try #require(try workspace.store.recordsStrict().first)
        #expect(old.ownershipPolicy == nil)
        #expect(try Data(contentsOf: file) == legacyBytes)
        let noowners = workspace.makeMigrator(runner: runner, mountFlags: { _ in UInt32(MNT_IGNORE_OWNERSHIP) })
        try await noowners.mount(record: old)
        let transfer = try #require(try workspace.store.transfers().first)
        try workspace.store.requestCleanup(operationID: transfer.operationID)
        try workspace.store.finishTransfer(operationID: transfer.operationID, deletionConfirmed: true)
        try workspace.store.upsert(old)
        let reopened = ContainerMountStore(fileURL: file)
        let current = try #require(try reopened.recordsStrict().first)
        #expect(current.ownershipPolicy == .owners)
        #expect(try reopened.transfers().isEmpty)
        let saved = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        #expect(saved["schemaVersion"] as? Int == 4)
        await #expect(throws: (any Error).self) { try await noowners.mount(record: current) }
    }

    @Test("Saved mount recovery records and activation evidence persist as schema 12 and cannot change or disappear", arguments: [false, true])
    func recoveryMountRecordIsDurableAndImmutable(removesRecord: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "RecoveryRecord")
        let result = try await workspace.makeMigrator(runner: runner).migrate(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Chat", bundleIdentifier: "com.example.chat", progressHandler: nil)
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        let saved = try Data(contentsOf: file)
        let document = try #require(try PropertyListSerialization.propertyList(from: saved, format: nil) as? [String: Any])
        #expect(document["schemaVersion"] as? Int == 12)
        let reopened = ContainerMountStore(fileURL: file)
        let original = try #require(try reopened.transfers().first)
        var recovery = try #require(original.recoveryMountRecord)
        #expect(recovery == result.record)
        #expect(original.baseline != nil)
        #expect(try Data(contentsOf: file) == saved)

        var changed = original
        if removesRecord {
            changed.recoveryMountRecord = nil
        } else {
            recovery.ownershipPolicy = .owners
            changed.recoveryMountRecord = recovery
        }
        #expect(throws: ContainerMountStore.StoreError.self) { try reopened.updateTransfer(changed) }

        #expect(try reopened.transfer(operationID: original.operationID) == original)
        #expect(try Data(contentsOf: file) == saved)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("Migration creates a volume, copies data, mounts it in place, and records it")
    func migrationHappyPath() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let migrator = workspace.makeMigrator(runner: runner)
        let source = try workspace.makeContainerDirectory(named: "xwechat_files")
        let item = workspace.item(for: source)

        let result = try await migrator.migrate(
            item: item,
            externalRootURL: workspace.externalRootURL,
            appName: "WeChat",
            bundleIdentifier: "test.appports.synthetic.wechat",
            progressHandler: nil
        )
        let record = result.record
        #expect(result.cleanupWarning == nil)

        #expect(record.mountPointPath == source.path)
        #expect(record.volumeUUID == "VOLUME-UUID-disk7s9")
        #expect(record.dataDirType == DataDirType.containers.rawValue)
        #expect(record.volumeName.hasPrefix("AppPorts-test.appports.synthetic.wechat-xwechat_files-"))
        // plist 日期只有秒级精度，按标识比较而不是整条记录相等。
        #expect(workspace.store.records().map(\.id) == [record.id])
        #expect(workspace.store.records().first?.volumeUUID == record.volumeUUID)
        #expect(runner.isMounted(source))
        #expect(runner.commands(prefix: ["apfs", "addVolume"]) == [["apfs", "addVolume", "disk7", "APFS", record.volumeName, "-nomount"]])
        let mounts = runner.commands(prefix: ["mount"])
        #expect(mounts.count == 2)
        #expect(mounts.last == ["mount", "nobrowse", "-mountPoint", source.path, "-mountOptions", "noowners", record.volumeUUID])
        #expect(record.ownershipPolicy == nil)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        let retained = try #require(try workspace.store.transfers().first)
        #expect(retained.phase == .awaitingUserVerification)
        let backup = URL(fileURLWithPath: try #require(retained.backupPath))
        #expect(try String(contentsOf: backup.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(workspace.agentSyncCount == 1)
    }

    @Test("A non-APFS external drive is rejected before any volume is created")
    func rejectsNonAPFSExternalDrive() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(externalFilesystem: "exfat")
        let migrator = workspace.makeMigrator(runner: runner)
        let source = try workspace.makeContainerDirectory(named: "Payload")

        await #expect(throws: ContainerVolumeMigrator.MigrationError.self) {
            try await migrator.migrate(
                item: workspace.item(for: source),
                externalRootURL: workspace.externalRootURL,
                appName: "Chat",
                bundleIdentifier: nil,
                progressHandler: nil
            )
        }
        #expect(runner.commands(prefix: ["apfs"]).isEmpty)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(workspace.store.records().isEmpty)
    }

    @Test("An encrypted destination never silently creates an unencrypted data volume")
    func refusesEncryptionDowngrade() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(externalEncrypted: true)
        let source = try workspace.makeContainerDirectory(named: "PrivateData")
        do {
            _ = try await workspace.makeMigrator(runner: runner).migrate(
                item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
                appName: "Chat", bundleIdentifier: "com.example.chat", progressHandler: nil)
            Issue.record("Encrypted destinations require an explicit supported encryption flow")
        } catch ContainerVolumeMigrator.MigrationError.encryptedDestination {}
        #expect(runner.commands(prefix: ["apfs", "addVolume"]).isEmpty)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("An unrelated volume at the recorded path is never mounted, unmounted, restored or deleted",
          arguments: ["mount", "unmount", "restore", "remount"])
    func refusesForeignVolume(operation: String) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["EXPECTED-UUID", "OTHER-UUID"])
        let source = try workspace.makeContainerDirectory(named: "OtherVolume")
        runner.markVolumeMounted("OTHER-UUID", at: source.path)
        let record = ContainerMountRecord(appName: "Chat", bundleIdentifier: "com.example.chat",
            dataDirType: DataDirType.containers.rawValue, mountPointPath: source.path,
            volumeUUID: "EXPECTED-UUID", volumeName: "AppPorts-test", externalRootPath: workspace.externalRootURL.path)
        try workspace.store.upsert(record)
        let migrator = workspace.makeMigrator(runner: runner)
        if operation == "remount" {
            let outcomes = await migrator.remountAvailableRecords()
            guard case .failed = outcomes.first?.state else {
                Issue.record("A different mounted volume must be reported as failed")
                return
            }
        } else {
            do {
                switch operation {
                case "mount": try await migrator.mount(record: record)
                case "unmount": try await migrator.unmount(record: record)
                default: try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
                }
                Issue.record("The unrelated volume must not be touched")
            } catch ContainerVolumeMigrator.MigrationError.unexpectedMountedVolume {}
        }
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(workspace.store.records().count == 1)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("A corrupt record file survives attempted writes and removals")
    func preservesCorruptRecordFile() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        let corrupt = Data("not a property list".utf8)
        try corrupt.write(to: file)
        let record = ContainerMountRecord(appName: "Chat", bundleIdentifier: nil,
            dataDirType: DataDirType.containers.rawValue, mountPointPath: "/example",
            volumeUUID: "UUID", volumeName: "AppPorts-test", externalRootPath: workspace.externalRootURL.path)
        #expect(throws: ContainerMountStore.StoreError.self) { try workspace.store.upsert(record) }
        #expect(throws: ContainerMountStore.StoreError.self) { try workspace.store.remove(mountPointPath: record.mountPointPath) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test("Final mount failure retains the original and volume for explicit recovery")
    func rollsBackWhenFinalMountFails() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "Payload")
        runner.failWhen(prefix: ["mount", "nobrowse", "-mountPoint", source.path])
        await #expect(throws: ContainerVolumeMigrator.MigrationError.self) {
            try await workspace.makeMigrator(runner: runner).migrate(item: workspace.item(for: source),
                externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        }
        let recovery = try #require(try workspace.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(recovery.backupPath))
        #expect(recovery.phase == .needsRecovery)
        #expect(recovery.createdVolumeUUID == "VOLUME-UUID-disk7s9")
        #expect(try String(contentsOf: backup.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(workspace.store.records().isEmpty)
        #expect(!runner.isMounted(source))
        #expect(workspace.agentSyncCount == 0)
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        let ledger = try Data(contentsOf: file)
        let calls = runner.calls
        let detached = try #require(runner.detachedContents(for: "VOLUME-UUID-disk7s9"))
        let backupSnapshot = try TreeCopySession.snapshot(at: backup)
        let volumeSnapshot = try TreeCopySession.snapshot(at: detached)
        let sourceIdentity = try DataPathIdentity.capture(source)
        for _ in 0..<2 {
            let coldStore = ContainerMountStore(fileURL: file)
            let coldMigrator = workspace.makeMigrator(runner: runner, storeOverride: coldStore)
            #expect(await coldMigrator.remountAvailableRecords().isEmpty)
            #expect(try coldStore.unfinishedTransfers() == [recovery])
            #expect(try coldStore.recordsStrict().isEmpty)
            #expect(try Data(contentsOf: file) == ledger)
            #expect(runner.calls == calls)
            #expect(try DataPathIdentity.capture(source) == sourceIdentity)
            // Failed final mounts leave a readable, non-writable placeholder.
            #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int == 0o500)
            #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeDirectory)
            #expect(try TreeCopySession.snapshot(at: backup) == backupSnapshot)
            #expect(try TreeCopySession.snapshot(at: detached) == volumeSnapshot)
            #expect(try String(contentsOf: detached.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
            #expect(!runner.isMounted(source))
            #expect(workspace.agentSyncCount == 0)
        }
    }

    @Test("Online restore preflight failures leave ledger and payload unchanged", arguments: ["flags", "writer", "uuid"])
    func restorePreflightIsReadOnly(reason: String) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Preflight")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        let before = try Data(contentsOf: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(reason == "uuid" ? "OTHER-UUID" : record.volumeUUID, at: source.path)
        let migrator = workspace.makeMigrator(runner: runner,
            mountFlags: { _ in reason == "flags" ? nil : UInt32(MNT_DONTBROWSE) },
            safetyRunner: RestoreWriterProbe(busy: reason == "writer"))
        await #expect(throws: (any Error).self) { try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil) }
        #expect(try Data(contentsOf: workspace.rootURL.appendingPathComponent("container-mounts.plist")) == before)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("payload".utf8))
        #expect(runner.calls.isEmpty)
    }

    private struct RestoreWriterProbe: ShellCommandRunning {
        let busy: Bool
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            ShellCommandResult(status: busy ? 0 : 1, standardOutput: Data((busy ? "p2147483647\n" : "").utf8), standardError: Data(), timedOut: false)
        }
    }

    private func unstartedRestore(_ workspace: Workspace, _ record: ContainerMountRecord) -> DataTransferRecord {
        let id = UUID()
        return DataTransferRecord(operationID: id, mode: .mount, direction: .restore,
            appName: record.appName, bundleIdentifier: record.bundleIdentifier, dataDirType: record.dataDirType,
            originalPath: record.mountPointPath, activePath: record.mountPointPath, destinationPath: record.mountPointPath,
            backupPath: workspace.rootURL.appendingPathComponent("mounts/recovery-\(id.uuidString)").path,
            stagingPath: record.mountPointURL.deletingLastPathComponent().appendingPathComponent(".appports-restore-staging-\(id.uuidString)").path,
            sourceIdentity: DataPathIdentity(volumeUUID: record.volumeUUID), phase: .needsRecovery)
    }

    @Test("A failed offline mount can be retried after reloading its durable intent")
    func failedOfflineRestoreCanRetry() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "OfflineRetry")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        // Materialize a fake volume so unmount/remount keeps its payload, just as APFS does.
        try FileManager.default.removeItem(at: source.appendingPathComponent("payload.txt"))
        try await workspace.makeMigrator(runner: runner).mount(record: record)
        try Data("payload".utf8).write(to: source.appendingPathComponent("payload.txt"))
        try await workspace.makeMigrator(runner: runner).unmount(record: record)
        runner.failWhen(prefix: ["mount"])
        await #expect(throws: (any Error).self) {
            try await workspace.makeMigrator(runner: runner).restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let pending = try #require(try workspace.store.transfers().first)
        runner.clearFailure()
        let cold = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        _ = try await workspace.makeMigrator(runner: runner, storeOverride: cold)
            .restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        let completed = try #require(try cold.transfers().first)
        #expect(completed.operationID == pending.operationID)
        #expect(completed.phase == .awaitingUserVerification)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt")) == "payload")
    }

    @Test("An already mounted recovery volume survives a cold restore retry")
    func mountedOfflineRestoreCanRetry() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "MountedOfflineRetry")
        var record = workspace.record(mountPoint: source)
        record.ownershipPolicy = .owners
        try workspace.store.upsert(record)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        try FileManager.default.removeItem(at: source.appendingPathComponent("payload.txt"))
        try await workspace.makeMigrator(runner: runner).mount(record: record)
        try Data("payload".utf8).write(to: source.appendingPathComponent("payload.txt"))
        try await workspace.makeMigrator(runner: runner).unmount(record: record)
        // The mount succeeds, but its ownership postcheck fails before source identity is saved.
        let failing = workspace.makeMigrator(runner: runner,
            mountFlags: { _ in UInt32(MNT_IGNORE_OWNERSHIP) })
        await #expect(throws: (any Error).self) {
            try await failing.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let pending = try #require(try workspace.store.transfers().first)
        #expect(pending.isUnstartedMountRestore)
        let recovery = URL(fileURLWithPath: try #require(pending.backupPath))
        #expect(runner.isMounted(recovery))
        #expect(try String(contentsOf: recovery.appendingPathComponent("payload.txt")) == "payload")
        let mountCount = runner.commands(prefix: ["mount"]).count
        let cold = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        _ = try await workspace.makeMigrator(runner: runner, storeOverride: cold)
            .restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        let completed = try #require(try cold.transfers().first)
        #expect(completed.operationID == pending.operationID)
        #expect(completed.phase == .awaitingUserVerification)
        #expect(runner.commands(prefix: ["mount"]).count == mountCount)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt")) == "payload")
    }

    @Test("An unstarted restore reuses its operation ID without discarding evidence")
    func restoreResumesUnstartedIntent() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Retry")
        let record = workspace.record(mountPoint: source)
        let pending = unstartedRestore(workspace, record)
        try workspace.store.upsert(record)
        try seedUnstartedRestore(pending, store: workspace.store)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        _ = try await workspace.makeMigrator(runner: runner).restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        let completed = try #require(try workspace.store.transfers().first)
        #expect(try workspace.store.transfers().count == 1)
        #expect(completed.operationID == pending.operationID)
        #expect(completed.createdAt == pending.createdAt)
        #expect(completed.phase == .awaitingUserVerification)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("payload".utf8))
    }

    @Test("Unstarted restore refuses existing or substituted temporary paths", arguments: ["staging", "recovery", "symlink", "wrong-path"])
    func restoreRefusesPendingArtifacts(kind: String) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Retry")
        let record = workspace.record(mountPoint: source)
        let pending = unstartedRestore(workspace, record)
        try workspace.store.upsert(record)
        // For a wrong template, encode a separate intent with a syntactically valid path.
        let intent = kind == "wrong-path" ? DataTransferRecord(operationID: pending.operationID, mode: .mount, direction: .restore,
            appName: record.appName, bundleIdentifier: record.bundleIdentifier, dataDirType: record.dataDirType,
            originalPath: source.path, activePath: source.path, destinationPath: source.path,
            backupPath: pending.backupPath, stagingPath: source.deletingLastPathComponent().appendingPathComponent("unrelated-staging").path,
            sourceIdentity: pending.sourceIdentity, phase: .needsRecovery) : pending
        try seedUnstartedRestore(intent, store: workspace.store)
        if kind != "wrong-path" {
            let path = kind == "recovery" ? pending.backupPath! : pending.stagingPath!
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            if kind == "symlink" { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "absent-target") }
            else { try Data("keep".utf8).write(to: URL(fileURLWithPath: path)) }
        }
        let before = try Data(contentsOf: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        await #expect(throws: (any Error).self) { try await workspace.makeMigrator(runner: runner).restore(record: record, estimatedTotalBytes: 0, progressHandler: nil) }
        #expect(try Data(contentsOf: workspace.rootURL.appendingPathComponent("container-mounts.plist")) == before)
        #expect(runner.calls.isEmpty)
    }

    @Test("An unchanged mount keeps its original error without a redundant rollback", arguments: [false, true], [false, true])
    func restoreSkipsUnchangedOwnershipRollback(commandFails: Bool, fastUUIDAvailable: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Legacy")
        var record = workspace.record(mountPoint: source)
        record.ownershipPolicy = .owners
        try workspace.store.upsert(record)
        let flags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_NODEV | MNT_NOSUID | MNT_DONTBROWSE)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        if commandFails { runner.failWhen(prefix: ["-u"]) }
        let service = workspace.makeMigrator(runner: runner,
            mountedVolumeUUID: { fastUUIDAvailable ? runner.mountedUUID(at: $0) : nil }, mountFlags: { _ in flags })
        do {
            _ = try await service.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
            Issue.record("Restore must fail while flags still report noowners")
        } catch {
            if case ContainerVolumeMigrator.MigrationError.ownershipRollbackFailed = error {
                Issue.record("Unchanged options must not be reported as a failed rollback")
            }
            let failed = try #require(try workspace.store.transfers().first)
            #expect(failed.recoverableReason == error.localizedDescription)
            #expect(failed.isUnstartedMountRestore)
        }
        #expect(runner.commands(prefix: ["-u"]).map { $0[2] } == ["nobrowse,nodev,nosuid,owners"])
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try workspace.store.recordsStrict() == [record])
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("payload".utf8))
    }

    @Test("Cancelled ownership authorization keeps the original mount and can be retried", arguments: [false, true])
    func restoreOwnershipAuthorizationCancelled(originallyHidden: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Legacy")
        var record = workspace.record(mountPoint: source)
        record.ownershipPolicy = .owners
        try workspace.store.upsert(record)
        let flags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_NODEV | MNT_NOSUID) | (originallyHidden ? UInt32(MNT_DONTBROWSE) : 0)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        runner.denyUnprivileged(prefix: ["-u"])
        let service = workspace.makeMigrator(runner: runner, administratorRunner: { _, _ in
            throw DiskUtility.Failure.administratorPromptCancelled(command: "mount")
        }, mountFlags: { _ in flags })
        for _ in 0..<2 {
            do {
                _ = try await service.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
                Issue.record("Cancelled authorization must stop the restore")
            } catch DiskUtility.Failure.administratorPromptCancelled { }
        }
        let transfers = try workspace.store.transfers()
        try #require(transfers.count == 1)
        let pending = try #require(transfers.first)
        #expect(pending.isUnstartedMountRestore)
        #expect(runner.commands(prefix: ["-u"]).map { $0[2] } == Array(repeating: "nobrowse,nodev,nosuid,owners", count: 2))
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(try workspace.store.recordsStrict() == [record])
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("payload".utf8))
    }

    @Test("A legacy noowners restore skips ownership authorization, including a failed old intent", arguments: [false, true])
    func legacyRestoreKeepsNoowners(retry: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Legacy")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        let flags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_NODEV | MNT_NOSUID | MNT_DONTBROWSE)
        var operationID: UUID?
        if retry {
            var intent = unstartedRestore(workspace, record)
            intent.legacyRootOwnership = .init(uid: geteuid(), gid: getegid())
            intent.legacyMountFlags = flags
            try seedUnstartedRestore(intent, store: workspace.store)
            operationID = intent.operationID
        }
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        runner.denyUnprivileged(prefix: ["-u"])
        let migrator = workspace.makeMigrator(runner: runner, administratorRunner: { _, _ in
            Issue.record("A legacy restore requested administrator ownership authorization")
            throw DiskUtility.Failure.administratorPromptCancelled(command: "mount")
        }, mountFlags: { _ in flags })
        _ = try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        let completed = try #require(try workspace.store.transfers().first)
        #expect(completed.phase == .awaitingUserVerification)
        #expect(completed.legacyRootOwnership == nil && completed.legacyMountFlags == nil)
        #expect(completed.originalSourceMountFlags == flags)
        if let operationID { #expect(completed.operationID == operationID) }
        #expect(runner.commands(prefix: ["-u"]).isEmpty)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("payload".utf8))
    }

    @Test("A modern owners record restores its files after administrator authorization")
    func restoreUsesAdministratorForOwnership() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Legacy")
        var record = workspace.record(mountPoint: source)
        // The fixture is an ordinary directory, so it cannot exercise the
        // separate legacy root-owner projection that requires a real mount.
        record.ownershipPolicy = .owners
        try workspace.store.upsert(record)
        let flags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_NODEV | MNT_NOSUID | MNT_DONTBROWSE)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        runner.denyUnprivileged(prefix: ["-u"])
        let service = workspace.makeMigrator(runner: runner,
            administratorRunner: { try runner.runAsAdministrator(executable: $0, arguments: $1) },
            mountFlags: { _ in
                let options = runner.commands(prefix: ["sudo", "-u"]).last?[3].split(separator: ",") ?? []
                return options.contains("owners") ? flags & ~UInt32(MNT_IGNORE_OWNERSHIP) : flags
            })

        _ = try await service.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)

        #expect(!runner.isMounted(source))
        #expect(try workspace.store.recordsStrict().isEmpty)
        #expect(try workspace.store.transfers().first?.phase == .awaitingUserVerification)
        #expect(runner.commands(prefix: ["sudo", "-u"]) == [["sudo", "-u", "-o", "nobrowse,nodev,nosuid,owners", source.path]])
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("payload".utf8))
    }

    @Test("A saved strict source baseline keeps owners on retry even without a destination claim")
    func retryPreservesUnclaimedStrictBaseline() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Legacy")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        var pending = unstartedRestore(workspace, record)
        pending.sourceIdentity = try DataPathIdentity.capture(source, volumeUUID: record.volumeUUID)
        pending.preparationPath = pending.stagingPath
        pending.preparationParentIdentity = try DataPathIdentity.capture(source.deletingLastPathComponent())
        pending.sourceBaseline = try PropertyListEncoder().encode(TreeCopySession.snapshot(at: source,
            excludingRootEntries: ContainerVolumeMigrator.volumeSystemArtifacts))
        try seedUnstartedRestore(pending, store: workspace.store)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        let migrator = workspace.makeMigrator(runner: runner, mountFlags: { _ in
            UInt32(MNT_DONTBROWSE) | (runner.commands(prefix: ["-u"]).isEmpty ? UInt32(MNT_IGNORE_OWNERSHIP) : 0)
        })
        _ = try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        let completed = try #require(try workspace.store.transfer(operationID: pending.operationID))
        #expect(completed.sourceBaseline == pending.sourceBaseline)
        #expect(completed.phase == .awaitingUserVerification)
        #expect(runner.commands(prefix: ["-u"]).map { $0[2] } == ["nobrowse,owners"])
    }

    @Test("A failure after ownership changes restores current flags and reports actual rollback failure", arguments: [false, true], [false, true])
    func restoreRollsBackOwnershipUpdate(rollbackFails: Bool, fastUUIDAvailable: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Legacy")
        var record = workspace.record(mountPoint: source)
        record.ownershipPolicy = .owners
        try workspace.store.upsert(record)
        let flags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_NODEV | MNT_NOSUID | MNT_DONTBROWSE)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        // The forward update succeeds; a hardlink outside the selected tree
        // stops the copy before switching paths, so the owners change must be
        // reversed. Named pipes are supported and cannot trigger this failure.
        try #require(link(source.appendingPathComponent("payload.txt").path,
                          workspace.rootURL.appendingPathComponent("outside-hardlink").path) == 0)
        try runner.modelUnderlyingDirectory(at: source)
        if rollbackFails { runner.failWhen(prefix: ["mount", "nobrowse", "-mountPoint", source.path, "-mountOptions", "noowners"]) }
        let service = workspace.makeMigrator(runner: runner,
            mountedVolumeUUID: { fastUUIDAvailable ? runner.mountedUUID(at: $0) : nil }, mountFlags: { _ in
                let updates = runner.commands(prefix: ["-u"])
                let remounted = runner.commands(prefix: ["mount"]).last?.contains("noowners") == true
                return updates.isEmpty || (!rollbackFails && remounted) ? flags : flags & ~UInt32(MNT_IGNORE_OWNERSHIP)
            })
        do {
            _ = try await service.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
            Issue.record("The outside hardlink must stop the restore")
        } catch {
            if rollbackFails {
                guard case ContainerVolumeMigrator.MigrationError.ownershipRollbackFailed = error else {
                    Issue.record("Rollback failure was not surfaced: \(error)"); return
                }
            }
            let failed = try #require(try workspace.store.transfers().first)
            #expect(failed.recoverableReason == error.localizedDescription)
            #expect(failed.isUnstartedMountRestore)
            #expect(failed.originalSourceMountFlags == flags)
        }
        #expect(runner.commands(prefix: ["-u"]).map { $0[2] } == ["nobrowse,nodev,nosuid,owners"])
        #expect(runner.commands(prefix: ["unmount"]) == [["unmount", source.path]])
        var expectedMounts = [["mount", "nobrowse", "-mountPoint", source.path, "-mountOptions", "noowners", record.volumeUUID]]
        if rollbackFails {
            expectedMounts.append(["mount", "nobrowse", "-mountPoint", source.path, "-mountOptions", "owners", record.volumeUUID])
        }
        #expect(runner.commands(prefix: ["mount"]) == expectedMounts)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(runner.mountedUUID(at: source) == record.volumeUUID)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("payload".utf8))
    }

    @Test("Retry never rolls back stale ownership flags when this attempt did not change them")
    func restoreDoesNotReuseHistoricalFlags() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Legacy")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        var intent = unstartedRestore(workspace, record)
        intent.legacyRootOwnership = .init(uid: geteuid(), gid: getegid())
        intent.legacyMountFlags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_DONTBROWSE)
        try seedUnstartedRestore(intent, store: workspace.store)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        // The fake source is deliberately not a real mount, so strict root projection refuses it.
        await #expect(throws: (any Error).self) { try await workspace.makeMigrator(runner: runner).restore(record: record, estimatedTotalBytes: 0, progressHandler: nil) }
        #expect(runner.commands(prefix: ["-u"]).isEmpty)
        #expect(try workspace.store.transfer(operationID: intent.operationID)?.phase == .needsRecovery)
    }

    private func seedUnstartedRestore(_ intent: DataTransferRecord, store: ContainerMountStore) throws {
        var preparing = intent
        preparing.phase = .preparing
        try store.beginTransfer(preparing)
        var failed = intent
        failed.recoverableReason = "Synthetic pre-copy inspection failure"
        try store.updateTransfer(failed)
    }

    @Test("Restore copies the volume back, skips system artifacts, and retains its external source")
    func restoreRoundTrip() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["VOLUME-UUID-disk7s9"])
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        let migrator = workspace.makeMigrator(runner: runner)
        let mountPoint = try workspace.makeContainerDirectory(named: "Payload")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mountPoint.path)
        try FileManager.default.createDirectory(at: mountPoint.appendingPathComponent(".fseventsd"), withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: mountPoint.appendingPathComponent(ContainerVolumeMigrator.volumeMarkerFileName))
        try Data().write(to: mountPoint.appendingPathComponent(ContainerVolumeMigrator.neverIndexFileName))
        try FileManager.default.createDirectory(at: mountPoint.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: mountPoint.appendingPathComponent("nested/deep/file.bin"))
        runner.markVolumeMounted("VOLUME-UUID-disk7s9", at: mountPoint.path)
        let record = ContainerMountRecord(
            appName: "Chat",
            bundleIdentifier: "com.example.chat",
            dataDirType: DataDirType.containers.rawValue,
            mountPointPath: mountPoint.path,
            volumeUUID: "VOLUME-UUID-disk7s9",
            volumeName: "AppPorts-test",
            externalRootPath: workspace.externalRootURL.path
        )
        try workspace.store.upsert(record)

        let warning = try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        #expect(warning == nil)

        #expect(try String(contentsOf: mountPoint.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(try String(contentsOf: mountPoint.appendingPathComponent("nested/deep/file.bin"), encoding: .utf8) == "deep")
        #expect(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent(".fseventsd").path) == false)
        #expect(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent(ContainerVolumeMigrator.neverIndexFileName).path) == false)
        #expect(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent(ContainerVolumeMigrator.volumeMarkerFileName).path) == false)
        #expect(runner.commands(prefix: ["unmount"]) == [["unmount", mountPoint.path]])
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(workspace.store.records().isEmpty)
        #expect(workspace.agentSyncCount == 1)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: mountPoint.deletingLastPathComponent().path)
        #expect(siblings == ["Payload"])
        // 换回本地的目录沿用卷根（即迁移前原目录）的权限。
        #expect(try FileManager.default.attributesOfItem(atPath: mountPoint.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test("Interrupted migration never unmounts an unrelated volume and retains recoverable data", arguments: [1, 2])
    func rollbackNeverUnmountsForeignVolume(mountCommand: Int) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        runner.substituteForeignVolume(afterMountCommands: mountCommand, volumeUUID: "FOREIGN-UUID")
        let source = try workspace.makeContainerDirectory(named: "Payload")
        await #expect(throws: ContainerVolumeMigrator.MigrationError.self) {
            try await workspace.makeMigrator(runner: runner).migrate(item: workspace.item(for: source),
                externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        }
        let recovery = try #require(try workspace.store.transfers().first)
        #expect(recovery.phase == .needsRecovery)
        let mountCommands = runner.commands(prefix: ["mount"])
        try #require(mountCommands.indices.contains(mountCommand - 1))
        let foreignPath = URL(fileURLWithPath: mountCommands[mountCommand - 1][3])
        let original = mountCommand == 1 ? source : URL(fileURLWithPath: try #require(recovery.backupPath))
        #expect(try String(contentsOf: original.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(runner.isMounted(foreignPath))
        #expect(runner.mountedUUID(at: foreignPath) == "FOREIGN-UUID")
        #expect(!runner.commands(prefix: ["unmount"]).contains(["unmount", foreignPath.path]))
        #expect(try String(contentsOf: foreignPath.appendingPathComponent("foreign.txt"), encoding: .utf8) == "unrelated data")
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(workspace.store.records().isEmpty)
    }

    @Test("Successful migration retains its baseline and refuses cleanup after a late original write")
    func migrationReportsBackupCleanupFailure() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let migrator = workspace.makeMigrator(runner: runner)
        let result = try await migrator.migrate(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        #expect(result.cleanupWarning == nil)
        let retained = try #require(try workspace.store.transfers().first)
        #expect(retained.phase == .awaitingUserVerification)
        let backup = URL(fileURLWithPath: try #require(retained.backupPath))
        try Data("late original write".utf8).write(to: backup.appendingPathComponent("payload.txt"))
        await #expect(throws: (any Error).self) { try await migrator.cleanupRetainedTransfer(operationID: retained.operationID) }
        #expect(try String(contentsOf: backup.appendingPathComponent("payload.txt"), encoding: .utf8) == "late original write")
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(try workspace.store.transfer(operationID: retained.operationID)?.phase == .awaitingUserVerification)
        #expect(workspace.store.records().map(\.id) == [result.record.id])
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("The first cleanup checkpoint rechecks a moved or replaced active mount", arguments: [false, true])
    func cleanupCheckpointPreservesBackupWhenActiveMountChanges(replacesActivePath: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "Payload")
        _ = try await workspace.makeMigrator(runner: runner).migrate(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        let transfer = try #require(try workspace.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
        let backupSnapshot = try TreeCopySession.snapshot(at: backup)
        let displaced = workspace.rootURL.appendingPathComponent("displaced-active-volume")
        let writer = CleanupCheckpointMutationWriter {
            try FileManager.default.moveItem(at: source, to: displaced)
            if replacesActivePath {
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                try Data("unrelated active data".utf8).write(to: source.appendingPathComponent("foreign.txt"))
            }
        }
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"),
            writeData: { try writer.write($0, to: $1) })
        let migrator = workspace.makeMigrator(runner: runner, storeOverride: store)

        await #expect(throws: (any Error).self) {
            try await migrator.cleanupRetainedTransfer(operationID: transfer.operationID)
        }

        #expect(writer.didMutate)
        #expect(try TreeCopySession.snapshot(at: backup) == backupSnapshot)
        #expect(try String(contentsOf: displaced.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        if replacesActivePath {
            #expect(try String(contentsOf: source.appendingPathComponent("foreign.txt"), encoding: .utf8) == "unrelated active data")
        } else {
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
        let pending = try #require(try store.transfer(operationID: transfer.operationID))
        #expect(pending.phase == .cleanupRequested)
        #expect(pending.cleanupParentIdentity != nil)
        #expect(pending.recoverableReason?.isEmpty == false)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("The deletion checkpoint cannot authorize a retained file disappearing during that write")
    func initialCleanupRechecksBackupAfterCheckpoint() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "Payload")
        try Data("keep this retained file".utf8).write(to: source.appendingPathComponent("keep.txt"))
        _ = try await workspace.makeMigrator(runner: runner).migrate(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        let transfer = try #require(try workspace.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
        let backupIdentity = try DataPathIdentity.capture(backup)
        // The checkpoint now follows the final volume query and full scan.
        // There is no suspension between this write and per-object deletion.
        let writer = CleanupCheckpointMutationWriter {
            try FileManager.default.removeItem(at: backup.appendingPathComponent("payload.txt"))
        }
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"),
            writeData: { try writer.write($0, to: $1) })
        let migrator = workspace.makeMigrator(runner: runner, storeOverride: store, mountedVolumeUUID: { _ in nil })

        await #expect(throws: (any Error).self) {
            try await migrator.cleanupRetainedTransfer(operationID: transfer.operationID)
        }

        #expect(writer.didMutate)
        #expect(!FileManager.default.fileExists(atPath: backup.appendingPathComponent("payload.txt").path))
        #expect(try DataPathIdentity.capture(backup).matchesFilesystemObject(backupIdentity))
        #expect(try String(contentsOf: backup.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep this retained file")
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        let pending = try #require(try workspace.store.transfer(operationID: transfer.operationID))
        #expect(pending.phase == .cleanupRequested)
        #expect(pending.cleanupParentIdentity != nil)
        #expect(pending.recoverableReason?.isEmpty == false)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("Readonly source roots retain their mode through mount migration")
    func readonlyRootMigration() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "Readonly")
        #expect(chmod(source.path, 0o550) == 0)
        let result = try await workspace.makeMigrator(runner: runner).migrate(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        #expect(result.cleanupWarning == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int == 0o550)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(ContainerVolumeMigrator.readVolumeMarkerUUID(at: source) == result.record.volumeUUID)
        #expect(try workspace.store.transfers().first?.phase == .awaitingUserVerification)
    }

    @Test("A temporarily missing retained original does not disable explicit cleanup retry")
    func cleanupMissingBackupIsRetryable() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let migrator = workspace.makeMigrator(runner: runner)
        _ = try await migrator.migrate(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        let transfer = try #require(try workspace.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
        let moved = workspace.rootURL.appendingPathComponent("temporarily-moved")
        try FileManager.default.moveItem(at: backup, to: moved)
        await #expect(throws: (any Error).self) { try await migrator.cleanupRetainedTransfer(operationID: transfer.operationID) }
        #expect(try workspace.store.transfer(operationID: transfer.operationID)?.phase == .awaitingUserVerification)
        try FileManager.default.moveItem(at: moved, to: backup)
        try await migrator.cleanupRetainedTransfer(operationID: transfer.operationID)
        #expect(try workspace.store.transfer(operationID: transfer.operationID) == nil)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("Retryable cleanup does not block remount or restore after reconnect")
    func cleanupPendingStillAllowsRemountAndRestore() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        let record = try await migrator.migrate(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil).record
        let transfer = try #require(try workspace.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
        let moved = workspace.rootURL.appendingPathComponent("temporarily-moved")
        try FileManager.default.moveItem(at: backup, to: moved)
        await #expect(throws: (any Error).self) { try await migrator.cleanupRetainedTransfer(operationID: transfer.operationID) }
        #expect(try workspace.store.transfer(operationID: transfer.operationID)?.phase == .awaitingUserVerification)
        try FileManager.default.moveItem(at: moved, to: backup)
        try await migrator.unmount(record: record)
        try await migrator.mount(record: record, resumingManualPause: true)
        #expect(runner.isMounted(source))
        _ = try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        #expect(!runner.isMounted(source))
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        let restore = try #require(try workspace.store.transfers().first { $0.direction == .restore })
        try await migrator.cleanupRetainedTransfer(operationID: restore.operationID)
        let proof = try #require(try workspace.store.transfer(operationID: restore.operationID))
        #expect(proof.retainedCopyRemovedAt != nil && proof.baseline == nil)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        try await migrator.cleanupRetainedTransfer(operationID: transfer.operationID)
        #expect(try workspace.store.transfers().isEmpty)
    }

    @Test("An offline retained APFS volume does not turn completed restore into recovery")
    func offlineCleanupPreflightPreservesRetention() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["VOLUME-UUID-disk7s9"])
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let record = workspace.record(mountPoint: source)
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        try workspace.store.upsert(record)
        let migrator = workspace.makeMigrator(runner: runner)
        _ = try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        let transfer = try #require(try workspace.store.transfers().first)
        let mountsBefore = runner.commands(prefix: ["mount"])
        runner.failWhen(prefix: ["info", "-plist", record.volumeUUID])
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) { try await migrator.cleanupRetainedTransfer(operationID: transfer.operationID) }
            #expect(try workspace.store.transfer(operationID: transfer.operationID)?.phase == .awaitingUserVerification)
        }
        #expect(runner.commands(prefix: ["mount"]) == mountsBefore)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("Restore retains its source normally and reopening never remounts or deletes it")
    func restoreRetainsVolumeWithoutAutomaticCleanup() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["VOLUME-UUID-disk7s9"])
        runner.hideContentsOnUnmount()
        defer { runner.stashedVolumeContents.forEach { try? FileManager.default.removeItem(at: $0) } }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let record = workspace.record(mountPoint: source)
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        try workspace.store.upsert(record)
        let migrator = workspace.makeMigrator(runner: runner)
        #expect(try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil) == nil)
        let reopened = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        #expect(try reopened.recordsStrict().isEmpty)
        let retained = try #require(try reopened.transfers().first)
        #expect(retained.direction == .restore)
        #expect(retained.phase == .awaitingUserVerification)
        #expect(retained.sourceIdentity.volumeUUID == record.volumeUUID)
        #expect(await migrator.remountAvailableRecords().isEmpty)
        try Data("new local data".utf8).write(to: source.appendingPathComponent("payload.txt"))
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "new local data")
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("Restored-volume deletion failure can retry after reopening without copying local data again")
    func restoreReportsVolumeCleanupFailure() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        // A real fixture UUID lets the strict copier verify the synthetic volume's
        // identity. All disk commands still execute only inside the fake runner.
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        let result = try await migrator.migrate(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        let migration = try #require(try workspace.store.transfers().first)
        try await migrator.cleanupRetainedTransfer(operationID: migration.operationID)
        #expect(try workspace.store.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(migration.backupPath)))
        _ = try await migrator.restore(record: result.record, estimatedTotalBytes: 0, progressHandler: nil)
        let restore = try #require(try workspace.store.transfers().first)
        #expect(restore.direction == .restore)
        #expect(restore.phase == .awaitingUserVerification)
        // New local writes must not be mistaken for damage to the old baseline.
        try Data("new local data".utf8).write(to: source.appendingPathComponent("payload.txt"))
        runner.failWhen(prefix: ["apfs", "deleteVolume"])
        await #expect(throws: (any Error).self) {
            try await migrator.cleanupRetainedTransfer(operationID: restore.operationID)
        }
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]) == [["apfs", "deleteVolume", "disk7s9"]])
        let recovery = try #require(try workspace.store.transfer(operationID: restore.operationID))
        #expect(recovery.phase == .cleanupRequested)
        #expect(recovery.cleanupParentIdentity != nil)
        #expect(recovery.cleanupVolumeContainerUUID != nil)
        #expect(recovery.baseline == restore.baseline)
        #expect(recovery.sourceIdentity == restore.sourceIdentity)
        #expect(recovery.destinationIdentity == restore.destinationIdentity)
        #expect(recovery.recoverableReason?.isEmpty == false)
        let detached = try #require(runner.detachedContents(for: uuid))
        #expect(try String(contentsOf: detached.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        let activeSnapshot = try TreeCopySession.snapshot(at: source)
        runner.clearFailure()
        for _ in 0..<2 {
            let coldStore = ContainerMountStore(fileURL: file)
            let coldMigrator = workspace.makeMigrator(runner: runner, storeOverride: coldStore)
            #expect(await coldMigrator.remountAvailableRecords().isEmpty)
            try await coldMigrator.cleanupRetainedTransfer(operationID: restore.operationID)
            #expect(try coldStore.unfinishedTransfers().isEmpty)
            #expect(try coldStore.recordsStrict().isEmpty)
            #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == 2)
            #expect(try TreeCopySession.snapshot(at: source) == activeSnapshot)
            #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "new local data")
            #expect(!runner.isMounted(source))
        }
    }

    @Test("Cleanup retry never unmounts or deletes an external volume that is mounted again")
    func cleanupRefusesReusedVolume() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["VOLUME-UUID-disk7s9"])
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let record = workspace.record(mountPoint: source)
        let cleanup = ContainerCleanupRecord(kind: .restoredVolume, mountRecord: record, localPath: source.path)
        try workspace.store.beginRestore(cleanup)
        let otherPath = workspace.rootURL.appendingPathComponent("AnotherMount")
        runner.markVolumeMounted(record.volumeUUID, at: otherPath.path)
        let warning = ContainerVolumeMigrator.CleanupWarning(cleanup: cleanup, details: "previous failure")

        let result = await workspace.makeMigrator(runner: runner).retryCleanup(warning)

        #expect(result == nil)
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try workspace.store.pendingCleanups().isEmpty)
        let preserved = try #require(try workspace.store.preservedMaterials().first)
        #expect(preserved.volumeUUID == record.volumeUUID)
        #expect(runner.mountedUUID(at: otherPath) == record.volumeUUID)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("A record write failure before restore switching leaves the original mount intact")
    func restoreStopsBeforeSwitchWhenRecordsCannotBeSaved() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let writer = FailingRecordWriter(failingWrite: 2)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("guarded-mounts.plist"), writeData: { try writer.write($0, to: $1) })
        let runner = FakeDiskCommandRunner(onlineVolumes: ["VOLUME-UUID-disk7s9"])
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let record = workspace.record(mountPoint: source)
        try store.upsert(record)
        runner.markVolumeMounted(record.volumeUUID, at: source.path)

        do {
            try await workspace.makeMigrator(runner: runner, storeOverride: store).restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
            Issue.record("A failed write must prevent switching to local data")
        } catch is CocoaError { }
        #expect(try store.transfers().isEmpty)
        #expect(runner.isMounted(source))
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(store.records().map(\.id) == [record.id])
        #expect(try store.pendingCleanups().isEmpty)
    }

    @Test("An interrupted restore intent survives reopening without deleting or remounting", arguments: [false, true])
    func cleanupRecordFailureDoesNotRepeatDeletion(reopensStore: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let writer = FailingSwitchWriter()
        let file = workspace.rootURL.appendingPathComponent("guarded-mounts.plist")
        let store = ContainerMountStore(fileURL: file, writeData: { try writer.write($0, to: $1) })
        let runner = FakeDiskCommandRunner(onlineVolumes: ["VOLUME-UUID-disk7s9"])
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let record = workspace.record(mountPoint: source)
        try store.upsert(record)
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        await #expect(throws: (any Error).self) {
            try await workspace.makeMigrator(runner: runner, storeOverride: store).restore(record: record,
                estimatedTotalBytes: 0, progressHandler: nil)
        }
        let inspected = reopensStore ? ContainerMountStore(fileURL: file) : store
        let recovery = try #require(try inspected.unfinishedTransfers().first)
        #expect(recovery.phase == .needsRecovery)
        let staging = URL(fileURLWithPath: try #require(recovery.stagingPath))
        #expect(try String(contentsOf: staging.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(try inspected.recordsStrict() == [record])
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("Explicitly forgetting cleanup metadata preserves all data when the external drive is offline")
    func discardCleanupRecordDoesNotTouchCopies() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let cleanup = ContainerCleanupRecord(kind: .restoredVolume, mountRecord: workspace.record(mountPoint: source), localPath: source.path)
        try workspace.store.beginRestore(cleanup)
        let migrator = workspace.makeMigrator(runner: runner)

        try await migrator.discardCleanupRecord(cleanup)

        #expect(runner.calls.isEmpty)
        #expect(try workspace.store.pendingCleanups().isEmpty)
        #expect(workspace.store.records().isEmpty)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("An incomplete local restore cannot lose its recovery record")
    func refusesToDiscardIncompleteRestore() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let staging = try workspace.makeContainerDirectory(named: ".appports-restore-staging-test")
        let cleanup = ContainerCleanupRecord(
            kind: .restoredVolume, mountRecord: workspace.record(mountPoint: source),
            localPath: source.path, restoreStagingPath: staging.path
        )
        try workspace.store.beginRestore(cleanup)
        let migrator = workspace.makeMigrator(runner: runner)

        await #expect(throws: ContainerVolumeMigrator.MigrationError.self) {
            try await migrator.discardCleanupRecord(cleanup)
        }

        #expect(runner.calls.isEmpty)
        #expect(try workspace.store.pendingCleanups().count == 1)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(try String(contentsOf: staging.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("Legacy mount-record arrays are retained when cleanup records are introduced")
    func preservesLegacyRecordsOnSchemaUpgrade() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let record = workspace.record(mountPoint: workspace.rootURL.appendingPathComponent("Payload"))
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        try PropertyListEncoder().encode([record]).write(to: file)
        #expect(workspace.store.records().map(\.id) == [record.id])
        let cleanup = ContainerCleanupRecord(kind: .migrationBackup, mountRecord: record, localPath: "/fixture/backup")
        try workspace.store.recordMigration(record, cleanup: cleanup)
        let reopened = ContainerMountStore(fileURL: file)
        #expect(reopened.records().map(\.id) == [record.id])
        #expect(try reopened.pendingCleanups().map(\.id) == [cleanup.id])
    }

    @Test("Restore never deletes files that are still under the mount point after unmounting")
    func restoreKeepsUnexpectedContentAtMountPoint() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        // 默认的假卷卸载后文件仍留在挂载点：相当于卷没真正离开，或底下意外有本地文件。
        let runner = FakeDiskCommandRunner(onlineVolumes: ["VOLUME-UUID-disk7s9"])
        let migrator = workspace.makeMigrator(runner: runner)
        let mountPoint = try workspace.makeContainerDirectory(named: "Payload")
        runner.markVolumeMounted("VOLUME-UUID-disk7s9", at: mountPoint.path)
        let record = workspace.record(mountPoint: mountPoint)
        try workspace.store.upsert(record)

        do {
            try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
            Issue.record("Restore must stop when the mount point is not empty after unmounting")
        } catch ContainerVolumeMigrator.MigrationError.mountPointNotEmpty {
            let recovery = try #require(try workspace.store.transfers().first)
            let staging = URL(fileURLWithPath: try #require(recovery.stagingPath))
            #expect(try String(contentsOf: staging.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
            #expect(recovery.phase == .needsRecovery)
        }
        #expect(try String(contentsOf: mountPoint.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(workspace.store.records().isEmpty)
    }

    @Test("Migration stops before creating a volume when the external drive lacks space")
    func migrationRefusesInsufficientExternalSpace() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let gigabyte: Int64 = 1_000_000_000
        let migrator = workspace.makeMigrator(runner: runner, availableCapacity: { _ in gigabyte })
        let source = try workspace.makeContainerDirectory(named: "Payload")
        var item = workspace.item(for: source)
        item.sizeBytes = 5 * gigabyte

        do {
            _ = try await migrator.migrate(item: item, externalRootURL: workspace.externalRootURL, appName: "Chat", bundleIdentifier: nil, progressHandler: nil)
            Issue.record("Migration must stop when the destination lacks space")
        } catch ContainerVolumeMigrator.MigrationError.insufficientSpace(let required, let available) {
            #expect(required == ContainerVolumeMigrator.requiredFreeBytes(forDataBytes: item.sizeBytes))
            #expect(available == gigabyte)
        }
        #expect(runner.commands(prefix: ["apfs"]).isEmpty)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(workspace.store.records().isEmpty)
    }

    @Test("Restore stops before copying when this Mac lacks space, and the volume stays mounted")
    func restoreRefusesInsufficientLocalSpace() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["VOLUME-UUID-disk7s9"])
        let gigabyte: Int64 = 1_000_000_000
        let migrator = workspace.makeMigrator(runner: runner, availableCapacity: { _ in gigabyte })
        let mountPoint = try workspace.makeContainerDirectory(named: "Payload")
        runner.markVolumeMounted("VOLUME-UUID-disk7s9", at: mountPoint.path)
        let record = workspace.record(mountPoint: mountPoint)
        try workspace.store.upsert(record)

        do {
            try await migrator.restore(record: record, estimatedTotalBytes: 5 * gigabyte, progressHandler: nil)
            Issue.record("Restore must stop when this Mac lacks space")
        } catch ContainerVolumeMigrator.MigrationError.insufficientSpace {}
        #expect(runner.isMounted(mountPoint))
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(workspace.store.records().map(\.id) == [record.id])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: mountPoint.deletingLastPathComponent().path)
        #expect(siblings == ["Payload"])
    }

    @Test("Required free space adds a margin for file system metadata")
    func requiredFreeSpaceHasMargin() {
        let megabyte: Int64 = 1024 * 1024
        #expect(ContainerVolumeMigrator.requiredFreeBytes(forDataBytes: 0) == 256 * megabyte)
        #expect(ContainerVolumeMigrator.requiredFreeBytes(forDataBytes: 100 * megabyte) == 356 * megabyte)
        #expect(ContainerVolumeMigrator.requiredFreeBytes(forDataBytes: 20_000 * megabyte) == 21_000 * megabyte)
    }

    @Test("Remount only touches records whose volume is online and not yet mounted")
    func remountsAvailableRecords() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["ONLINE-UUID"])
        let migrator = workspace.makeMigrator(runner: runner)
        let online = try workspace.makeContainerDirectory(named: "Online")
        let offline = try workspace.makeContainerDirectory(named: "Offline")
        let mounted = try workspace.makeContainerDirectory(named: "Mounted")
        for url in [online, offline, mounted] {
            try FileManager.default.removeItem(at: url.appendingPathComponent("payload.txt"))
        }
        runner.markVolumeMounted("MOUNTED-UUID", at: mounted.path)
        for (url, uuid) in [(online, "ONLINE-UUID"), (offline, "OFFLINE-UUID"), (mounted, "MOUNTED-UUID")] {
            try workspace.store.upsert(ContainerMountRecord(
                appName: "Chat", bundleIdentifier: nil, dataDirType: DataDirType.containers.rawValue,
                mountPointPath: url.path, volumeUUID: uuid, volumeName: uuid, externalRootPath: workspace.externalRootURL.path
            ))
        }

        let notifications = Counter()
        let observer = NotificationCenter.default.addObserver(forName: .appPortsRecordsDidChange, object: nil, queue: nil) { note in
            if let store = note.object as? ContainerMountStore, store === workspace.store {
                notifications.increment()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let outcomes = await migrator.remountAvailableRecords()
        let states = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.record.volumeUUID, $0.state) })

        #expect(states["ONLINE-UUID"] == .mounted)
        #expect(states["OFFLINE-UUID"] == .unavailable)
        #expect(states["MOUNTED-UUID"] == .alreadyMounted)
        #expect(runner.commands(prefix: ["mount"]) == [["mount", "nobrowse", "-mountPoint", online.path, "-mountOptions", "noowners", "ONLINE-UUID"]])
        // 每个记录只查一次 diskutil（在线 + 挂载点合并）；离线的那个查一次就放弃。
        #expect(runner.commands(prefix: ["info"]).count == 2)
        #expect(runner.commands(prefix: ["info"]).allSatisfy { $0.last != "MOUNTED-UUID" })
        #expect(runner.isMounted(online))
        #expect(notifications.value == 1)

        // The minute-by-minute backstop must not refresh the UI again when
        // mounts and offline volumes remain unchanged.
        _ = await migrator.remountAvailableRecords()
        #expect(notifications.value == 1)
    }

    @Test("Observing a legacy live mount never rewrites its flags")
    func hidesLegacyBrowsableMountInPlace() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let legacyFlags = UInt32(MNT_NODEV | MNT_NOSUID | MNT_IGNORE_OWNERSHIP | MNT_JOURNALED)
        let migrator = workspace.makeMigrator(runner: runner, mountFlags: { _ in legacyFlags })
        let mounted = try workspace.makeContainerDirectory(named: "Mounted")
        runner.markVolumeMounted("MOUNTED-UUID", at: mounted.path)
        try workspace.store.upsert(workspace.record(mountPoint: mounted, volumeUUID: "MOUNTED-UUID"))

        let outcomes = await migrator.remountAvailableRecords()

        #expect(outcomes.map(\.state) == [.alreadyMounted])
        #expect(runner.commands(prefix: ["-u"]).isEmpty)
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
    }

    @Test("A volume already hidden from Finder is left alone")
    func leavesHiddenMountAlone() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        let migrator = workspace.makeMigrator(runner: runner)
        let mounted = try workspace.makeContainerDirectory(named: "Mounted")
        runner.markVolumeMounted("MOUNTED-UUID", at: mounted.path)
        try workspace.store.upsert(workspace.record(mountPoint: mounted, volumeUUID: "MOUNTED-UUID"))

        _ = await migrator.remountAvailableRecords()

        #expect(runner.commands(prefix: ["-u"]).isEmpty)
    }

    @Test("系统抢先自动挂载时：把卷从 /Volumes 卸下来，再挂到容器路径")
    func reclaimsVolumeFromForeignAutomount() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["RACE-UUID"])
        let migrator = workspace.makeMigrator(runner: runner)
        let mountPoint = try workspace.makeContainerDirectory(named: "Race")
        try FileManager.default.removeItem(at: mountPoint.appendingPathComponent("payload.txt"))
        try workspace.store.upsert(makeRecord(mountPoint: mountPoint, uuid: "RACE-UUID", workspace: workspace))
        // 第一条 mount 命令期间，系统把卷挂到了 /Volumes：命令返回成功，挂载点却是空的。
        runner.simulateForeignAutomount(volume: "RACE-UUID", at: "/Volumes/AppPorts-auto", afterMountCommands: 1)

        let outcomes = await migrator.remountAvailableRecords()

        #expect(outcomes.first?.state == .mounted)
        #expect(runner.isMounted(mountPoint))
        #expect(runner.commands(prefix: ["unmount"]) == [["unmount", "/Volumes/AppPorts-auto"]])
        #expect(runner.commands(prefix: ["mount"]) == [
            ["mount", "nobrowse", "-mountPoint", mountPoint.path, "-mountOptions", "noowners", "RACE-UUID"],
            ["mount", "nobrowse", "-mountPoint", mountPoint.path, "-mountOptions", "noowners", "RACE-UUID"]
        ])
    }

    @Test("重试也拿不回挂载点时才报失败，且不会无限重试")
    func failsAfterMountAttempts() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["RACE-UUID"])
        let migrator = workspace.makeMigrator(runner: runner)
        let mountPoint = try workspace.makeContainerDirectory(named: "Race")
        try FileManager.default.removeItem(at: mountPoint.appendingPathComponent("payload.txt"))
        try workspace.store.upsert(makeRecord(mountPoint: mountPoint, uuid: "RACE-UUID", workspace: workspace))
        runner.simulateForeignAutomount(volume: "RACE-UUID", at: "/Volumes/AppPorts-auto", afterMountCommands: 0, repeating: true)

        let outcomes = await migrator.remountAvailableRecords()

        guard case .failed(let message)? = outcomes.first?.state else {
            Issue.record("期望失败状态，实际 \(String(describing: outcomes.first?.state))")
            return
        }
        let expectedMessage = String(format: "挂载后校验失败，该路径不是挂载点：%@".localized, mountPoint.path)
        #expect(message == expectedMessage)
        #expect(runner.commands(prefix: ["mount"]).count == ContainerVolumeMigrator.maximumMountAttempts)
        #expect(runner.isMounted(mountPoint) == false)
    }

    @Test("卷被系统挂在 /Volumes 时，靠 statfs + 卷根标记直接切换，不查 diskutil")
    func skipsDiskutilWhenVolumeSitsOnAutoMountPoint() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["AUTO-UUID"])
        let autoMountPoint = "/Volumes/AppPorts-auto-000001"
        let migrator = workspace.makeMigrator(runner: runner, volumeUUIDMarker: { url in
            url.path == autoMountPoint ? "AUTO-UUID" : nil
        })
        let mountPoint = try workspace.makeContainerDirectory(named: "Auto")
        try FileManager.default.removeItem(at: mountPoint.appendingPathComponent("payload.txt"))
        try workspace.store.upsert(makeRecord(mountPoint: mountPoint, uuid: "AUTO-UUID", volumeName: "AppPorts-auto-000001", workspace: workspace))
        // 系统在开机/插盘时抢先把它挂到了 /Volumes
        runner.markVolumeMounted("AUTO-UUID", at: autoMountPoint)

        let outcomes = await migrator.remountAvailableRecords()

        #expect(outcomes.first?.state == .mounted)
        #expect(runner.isMounted(mountPoint))
        // 关键：一次 diskutil 查询都不该发出去（开机时那次查询实测要 9 秒）
        #expect(runner.commands(prefix: ["info"]).isEmpty)
        #expect(runner.commands(prefix: ["unmount"]) == [["unmount", autoMountPoint]])
        #expect(runner.commands(prefix: ["mount"]) == [["mount", "nobrowse", "-mountPoint", mountPoint.path, "-mountOptions", "noowners", "AUTO-UUID"]])
    }

    @Test("自动挂载点上不是我们的卷时退回 diskutil 查询")
    func fallsBackWhenAutoMountMarkerDoesNotMatch() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["AUTO-UUID"])
        let autoMountPoint = "/Volumes/SomebodyElse"
        // 卷根标记里的 UUID 对不上（或没有标记）：不能拿它当自己的卷去卸载
        let migrator = workspace.makeMigrator(runner: runner, volumeUUIDMarker: { _ in "OTHER-UUID" })
        let mountPoint = try workspace.makeContainerDirectory(named: "NotOurs")
        try FileManager.default.removeItem(at: mountPoint.appendingPathComponent("payload.txt"))
        try workspace.store.upsert(makeRecord(mountPoint: mountPoint, uuid: "AUTO-UUID", volumeName: "SomebodyElse", workspace: workspace))
        runner.markVolumeMounted("AUTO-UUID", at: autoMountPoint)

        let outcomes = await migrator.remountAvailableRecords()

        #expect(outcomes.first?.state == .mounted)
        #expect(runner.isMounted(mountPoint))
        // 退回常规路径：查一次 diskutil 才知道它挂在哪
        #expect(runner.commands(prefix: ["info"]).count == 1)
        #expect(runner.commands(prefix: ["unmount"]) == [["unmount", autoMountPoint]])
    }

    @Test("卷根本没挂上时走 diskutil 查询，不会误判")
    func fallsBackWhenVolumeIsNotMountedAnywhere() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["FREE-UUID"])
        let migrator = workspace.makeMigrator(runner: runner, volumeUUIDMarker: { _ in "FREE-UUID" })
        let mountPoint = try workspace.makeContainerDirectory(named: "Free")
        try FileManager.default.removeItem(at: mountPoint.appendingPathComponent("payload.txt"))
        try workspace.store.upsert(makeRecord(mountPoint: mountPoint, uuid: "FREE-UUID", volumeName: "AppPorts-free", workspace: workspace))

        let outcomes = await migrator.remountAvailableRecords()

        #expect(outcomes.first?.state == .mounted)
        #expect(runner.commands(prefix: ["info"]).count == 1)
        #expect(runner.commands(prefix: ["mount"]) == [["mount", "nobrowse", "-mountPoint", mountPoint.path, "-mountOptions", "noowners", "FREE-UUID"]])
    }

    private func makeRecord(
        mountPoint: URL,
        uuid: String,
        volumeName: String = "AppPorts-test",
        workspace: Workspace
    ) -> ContainerMountRecord {
        ContainerMountRecord(
            appName: "Chat",
            bundleIdentifier: "com.example.chat",
            dataDirType: DataDirType.containers.rawValue,
            mountPointPath: mountPoint.path,
            volumeUUID: uuid,
            volumeName: volumeName,
            externalRootPath: workspace.externalRootURL.path
        )
    }

    @Test("The never-index marker is written once and a stale Spotlight index is cleared with it")
    func writesNeverIndexMarkerOnce() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("never-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".Spotlight-V100/Store-V2"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try ContainerVolumeMigrator.writeNeverIndexMarker(at: root))
        let marker = root.appendingPathComponent(ContainerVolumeMigrator.neverIndexFileName)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: marker).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".Spotlight-V100").path) == false)

        // 第二次调用不重写、也不碰现场：标记存在就说明这个卷早就处理过了。
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".Spotlight-V100"), withIntermediateDirectories: true)
        #expect(try ContainerVolumeMigrator.writeNeverIndexMarker(at: root) == false)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".Spotlight-V100").path))
        #expect(try Data(contentsOf: marker).isEmpty)
    }

    @Test("A never-index marker already on the volume is never rewritten over")
    func keepsExistingNeverIndexMarkerContent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("never-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(ContainerVolumeMigrator.neverIndexFileName)
        try Data("keep".utf8).write(to: marker)

        #expect(try ContainerVolumeMigrator.writeNeverIndexMarker(at: root) == false)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    }

    @Test("When DiskArbitration denies the user (macOS 12), mounts are retried with administrator privileges")
    func retriesMountWithAdministratorPrivileges() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        runner.denyUnprivileged(prefix: ["mount"])
        let migrator = workspace.makeMigrator(runner: runner, administratorRunner: { try runner.runAsAdministrator(executable: $0, arguments: $1) })
        let source = try workspace.makeContainerDirectory(named: "Payload")

        let result = try await migrator.migrate(
            item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL,
            appName: "Chat",
            bundleIdentifier: nil,
            progressHandler: nil
        )
        let record = result.record

        #expect(runner.isMounted(source))
        let elevatedMounts = runner.commands(prefix: ["sudo", "mount"])
        #expect(elevatedMounts.count == 2)
        #expect(elevatedMounts.last == ["sudo", "mount", "nobrowse", "-mountPoint", source.path, "-mountOptions", "noowners", record.volumeUUID])
        #expect(workspace.store.records().map(\.id) == [record.id])
    }

    @Test("Without a way to prompt (login agent), a privileged mount fails cleanly and keeps the data")
    func privilegeFailureWithoutPromptIsReported() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner()
        runner.denyUnprivileged(prefix: ["mount"])
        let migrator = workspace.makeMigrator(runner: runner, administratorRunner: nil)
        let source = try workspace.makeContainerDirectory(named: "Payload")

        do {
            _ = try await migrator.migrate(
                item: workspace.item(for: source),
                externalRootURL: workspace.externalRootURL,
                appName: "Chat",
                bundleIdentifier: nil,
                progressHandler: nil
            )
            Issue.record("A privileged mount without a prompt must fail")
        } catch ContainerVolumeMigrator.MigrationError.mountFailed(let mountPoint, let message) {
            let mountArguments = ["mount", "nobrowse", "-mountPoint", mountPoint.path,
                                  "-mountOptions", "noowners", "VOLUME-UUID-disk7s9"]
            #expect(runner.commands(prefix: ["mount"]) == [mountArguments])
            let expectedMessage = String(
                format: "此系统版本要求管理员权限才能执行磁盘命令，当前环境无法弹出授权框（%@）".localized,
                "diskutil " + mountArguments.joined(separator: " ")
            )
            #expect(message == expectedMessage)
        }
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(workspace.store.records().isEmpty)
    }

    @Test("Mounting refuses a mount point that already contains data")
    func refusesNonEmptyMountPoint() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["ONLINE-UUID"])
        let migrator = workspace.makeMigrator(runner: runner)
        let mountPoint = try workspace.makeContainerDirectory(named: "Occupied")
        let record = ContainerMountRecord(
            appName: "Chat", bundleIdentifier: nil, dataDirType: DataDirType.containers.rawValue,
            mountPointPath: mountPoint.path, volumeUUID: "ONLINE-UUID", volumeName: "ONLINE-UUID", externalRootPath: workspace.externalRootURL.path
        )
        try workspace.store.upsert(record)

        do {
            try await migrator.mount(record: record)
            Issue.record("A mount point with local data must not be covered by a volume")
        } catch ContainerVolumeMigrator.MigrationError.mountPointNotEmpty {
            // Expected: the local data stays reachable.
        }
        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(try String(contentsOf: mountPoint.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("A volume macOS auto-mounted under /Volumes is moved to the container path on mount")
    func relocatesVolumeAutoMountedUnderVolumes() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["AUTO-UUID"])
        let migrator = workspace.makeMigrator(runner: runner)
        let mountPoint = try workspace.makeContainerDirectory(named: "Payload")
        try FileManager.default.removeItem(at: mountPoint.appendingPathComponent("payload.txt"))
        let systemMountPoint = "/Volumes/AppPorts-com.example.chat-Payload-937e9e"
        runner.markVolumeMounted("AUTO-UUID", at: systemMountPoint)
        let record = ContainerMountRecord(
            appName: "Chat", bundleIdentifier: nil, dataDirType: DataDirType.containers.rawValue,
            mountPointPath: mountPoint.path, volumeUUID: "AUTO-UUID", volumeName: "AUTO-UUID",
            externalRootPath: workspace.externalRootURL.path
        )
        try workspace.store.upsert(record)

        try await migrator.mount(record: record)

        // 必须先把卷从系统挂载点卸下来，再挂到容器路径。
        #expect(runner.commands(prefix: ["unmount"]) == [["unmount", systemMountPoint]])
        #expect(runner.commands(prefix: ["mount"]) == [["mount", "nobrowse", "-mountPoint", mountPoint.path, "-mountOptions", "noowners", "AUTO-UUID"]])
        // 在线检查和「当前挂在哪」共用同一次 diskutil：开机时一次查询要一秒上下，别退化成两次。
        #expect(runner.commands(prefix: ["info"]).count == 1)
        #expect(runner.isMounted(mountPoint))
        #expect(runner.isMounted(URL(fileURLWithPath: systemMountPoint)) == false)
    }

    @Test("A volume stuck on its system mount point fails safely, checking local data first", arguments: [false, true])
    func reportsFailureWhenSystemMountPointCannotBeDetached(localDataExists: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["AUTO-UUID"])
        let migrator = workspace.makeMigrator(runner: runner)
        let mountPoint = try workspace.makeContainerDirectory(named: "Payload")
        if !localDataExists { try FileManager.default.removeItem(at: mountPoint.appendingPathComponent("payload.txt")) }
        let systemMountPoint = "/Volumes/AppPorts-com.example.chat-Payload-937e9e"
        runner.markVolumeMounted("AUTO-UUID", at: systemMountPoint)
        runner.failWhen(prefix: ["unmount"])
        let record = ContainerMountRecord(
            appName: "Chat", bundleIdentifier: nil, dataDirType: DataDirType.containers.rawValue,
            mountPointPath: mountPoint.path, volumeUUID: "AUTO-UUID", volumeName: "AUTO-UUID",
            externalRootPath: workspace.externalRootURL.path
        )
        try workspace.store.upsert(record)

        do {
            try await migrator.mount(record: record)
            Issue.record("卸不掉系统挂载点时不能假装挂载成功")
        } catch ContainerVolumeMigrator.MigrationError.unmountFailed(let url, _) {
            #expect(!localDataExists)
            #expect(url.path == systemMountPoint)
        } catch ContainerVolumeMigrator.MigrationError.mountPointNotEmpty(let url) {
            #expect(localDataExists)
            #expect(url.path == mountPoint.path)
        }

        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.isMounted(mountPoint) == false)
        #expect(runner.isMounted(URL(fileURLWithPath: systemMountPoint)))
        #expect(runner.commands(prefix: ["unmount"]) == (localDataExists ? [] : [["unmount", systemMountPoint]]))
        // 容器路径上的本地数据必须原样保留。
        if localDataExists {
            #expect(try String(contentsOf: mountPoint.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        }
    }

    @Test("Volume names are filesystem safe and carry the application identity")
    func volumeNames() {
        let name = DiskUtility.makeVolumeName(bundleIdentifier: "test.appports.synthetic.wechat", appName: "WeChat", directoryName: "xwechat files/logs")
        #expect(name.hasPrefix("AppPorts-test.appports.synthetic.wechat-xwechat_files_logs-"))
        #expect(name.count <= 80)
        #expect(name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) })

        let fallback = DiskUtility.makeVolumeName(bundleIdentifier: nil, appName: "Chat", directoryName: "///")
        #expect(fallback.hasPrefix("AppPorts-Chat-data-"))
    }

    @Test("APFS deletion resolves the recorded UUID and confirms the device before deletion")
    func deleteAPFSVolumeConfirmsRecordedIdentity() async throws {
        let runner = VolumeDeletionRunner()
        let disk = DiskUtility(runner: runner, commandTimeout: 5, administratorRunner: nil)

        try await disk.deleteAPFSVolume(VolumeDeletionRunner.volumeUUID)

        #expect(runner.calls == [
            ["info", "-plist", VolumeDeletionRunner.volumeUUID],
            ["info", "-plist", "disk7s9"],
            ["apfs", "deleteVolume", "disk7s9"]
        ])
    }

    @Test("APFS deletion refuses unavailable or changed UUID/device mappings", arguments: VolumeDeletionFailure.allCases)
    func deleteAPFSVolumeRejectsUnprovenIdentity(scenario: VolumeDeletionFailure) async throws {
        let runner = VolumeDeletionRunner(failure: scenario)
        let disk = DiskUtility(runner: runner, commandTimeout: 5, administratorRunner: nil)

        await #expect(throws: (any Error).self) {
            try await disk.deleteAPFSVolume(VolumeDeletionRunner.volumeUUID)
        }

        var expectedQueries = [["info", "-plist", VolumeDeletionRunner.volumeUUID]]
        if scenario.reachesDeviceQuery { expectedQueries.append(["info", "-plist", "disk7s9"]) }
        #expect(runner.calls == expectedQueries)
        #expect(!runner.calls.contains { Array($0.prefix(2)) == ["apfs", "deleteVolume"] })
    }

    @Test("Completed mount workflows clean copies and support two cycles with application edits")
    func completedMountRoundTrips() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        for cycle in 1...2 {
            let migrated = try await migrator.migrateAndComplete(item: workspace.item(for: source),
                externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
            #expect(migrated.cleanupWarning == nil)
            #expect(try workspace.store.transfers().isEmpty)
            #expect(try workspace.store.recordsStrict().count == 1)
            #expect(runner.isMounted(source))
            try Data("external edit \(cycle)".utf8).write(to: source.appendingPathComponent("payload.txt"))
            let warning = try await migrator.restoreAndComplete(record: migrated.record, estimatedTotalBytes: 0, progressHandler: nil)
            #expect(warning == nil)
            #expect(try workspace.store.transfers().isEmpty)
            #expect(try workspace.store.recordsStrict().isEmpty)
            #expect(!runner.isMounted(source))
            #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "external edit \(cycle)")
            try Data("local edit \(cycle)".utf8).write(to: source.appendingPathComponent("payload.txt"))
        }
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == 2)
    }

    @Test("A new mount migration completes historical copies after restored local data is edited")
    func newMountMigrationCompletesHistoricalRestore() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        let old = try await migrator.migrate(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        _ = try await migrator.restore(record: old.record, estimatedTotalBytes: 0, progressHandler: nil)
        #expect(try workspace.store.transfers().count == 2)
        try Data("updated local content".utf8).write(to: source.appendingPathComponent("payload.txt"))
        let next = try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        #expect(next.cleanupWarning == nil)
        #expect(try workspace.store.transfers().isEmpty)
        #expect(runner.isMounted(source))
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "updated local content")
        #expect(try await migrator.restoreAndComplete(record: next.record, estimatedTotalBytes: 0, progressHandler: nil) == nil)
    }

    @Test("An offline restored volume does not block a new APFS destination, and its cleanup checks the current volume",
          arguments: [false, true])
    func remigrateMountWhileOldRestoreVolumeIsOffline(replaceActiveBeforeCleanup: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        // The first virtual volume must use its fixture's real filesystem UUID
        // for retained-content verification. The new active volume has a
        // distinct UUID; disk commands remain entirely inside FakeDisk.
        let oldUUID = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let nextUUID = UUID().uuidString
        let runner = FakeDiskCommandRunner(createdVolumeUUID: oldUUID)
        let migrator = workspace.makeMigrator(runner: runner)
        let old = try await migrator.migrateAndComplete(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        #expect(old.cleanupWarning == nil)
        _ = try await migrator.restore(record: old.record, estimatedTotalBytes: 0, progressHandler: nil)
        let oldRestore = try #require(try workspace.store.transfers().first)
        runner.markOffline(oldUUID)
        runner.useUUIDForNextCreatedVolume(nextUUID)
        try Data("latest local data".utf8).write(to: source.appendingPathComponent("payload.txt"))
        let nextRoot = workspace.externalRootURL.appendingPathComponent("DifferentDestination")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        let next = try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: nextRoot,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        #expect(next.cleanupWarning != nil)
        #expect(next.record.volumeUUID == nextUUID)
        #expect(runner.mountedUUID(at: source) == nextUUID)
        let nextTransfer = try #require(try workspace.store.transfer(operationID: next.operationID))
        #expect(nextTransfer.priorOperationID == oldRestore.operationID)
        #expect(nextTransfer.isDataSwitchComplete)
        #expect(nextTransfer.retainedCopyRemovedAt != nil)
        #expect(nextTransfer.baseline == nil && nextTransfer.sourceBaseline == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(nextTransfer.backupPath)))
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "latest local data")
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)

        let cold = workspace.makeMigrator(runner: runner,
            storeOverride: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist")))
        // Remount admission must recognize every completed predecessor rather
        // than treating the older restore's original root as foreign work.
        _ = try await runner.run(executable: "/usr/sbin/diskutil", arguments: ["unmount", source.path], timeout: 1)
        try await cold.mount(record: next.record)
        #expect(runner.mountedUUID(at: source) == nextUUID)
        runner.markOnline(oldUUID)
        let retryTime = Date()
        try workspace.store.recordCleanupRetry(.transfer(oldRestore.operationID), failed: true, now: retryTime)
        let postponed = try #require(try workspace.store.transfer(operationID: oldRestore.operationID))
        _ = await cold.performAutomaticMaintenance(now: { retryTime })
        #expect(try workspace.store.transfer(operationID: oldRestore.operationID)?.nextAutomaticRetryAt == postponed.nextAutomaticRetryAt)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty, "A due successor must not clean its postponed predecessor")
        if replaceActiveBeforeCleanup {
            let saved = source.deletingLastPathComponent().appendingPathComponent("SavedActiveData")
            try FileManager.default.moveItem(at: source, to: saved)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("foreign root".utf8).write(to: source.appendingPathComponent("payload.txt"))
            await #expect(throws: (any Error).self) {
                try await cold.cleanupRetainedLineage(operationID: next.operationID)
            }
            #expect(try workspace.store.transfers().count == 2)
            #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.moveItem(at: saved, to: source)
        }
        let exclusions = try PropertyListDecoder().decode(TreeCopySnapshot.self,
            from: #require(oldRestore.baseline)).excludedRootEntries
        let active = try TreeCopySession.snapshot(at: source, excludingRootEntries: exclusions)
        try await cold.cleanupRetainedLineage(operationID: next.operationID)
        #expect(try workspace.store.transfers().isEmpty)
        #expect(try workspace.store.recordsStrict() == [next.record])
        #expect(runner.mountedUUID(at: source) == nextUUID)
        #expect(try TreeCopySession.snapshot(at: source, excludingRootEntries: exclusions) == active)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]) == [["apfs", "deleteVolume", "disk7s9"]])
    }

    @Test("A restored dataset can switch migration modes while its older copy is offline",
          arguments: [DataTransferRecord.Mode.symlink, .mount])
    func remigrationCanChangeModesWithOfflineHistory(firstMode: DataTransferRecord.Mode) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        // Only one virtual APFS volume participates in each mixed-mode case.
        // Its UUID equals the disposable filesystem so real tree verification
        // runs while every disk command remains inside FakeDiskCommandRunner.
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        let home = workspace.rootURL.appendingPathComponent("Home")
        let mover = DataDirMover(homeDir: home, store: workspace.store,
            runner: SyntheticNoWritersRunner(), mountMigrator: migrator)
        let item = workspace.item(for: source)
        let firstDrive = workspace.externalRootURL.appendingPathComponent("FirstLocation")
        let secondDrive = workspace.externalRootURL.appendingPathComponent("SecondLocation")
        for drive in [firstDrive, secondDrive] {
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: false)
            try Data("unrelated".utf8).write(to: drive.appendingPathComponent("sentinel.txt"))
        }
        if firstMode == .symlink {
            #expect(try await mover.migrateAndComplete(item: item, to: firstDrive, progressHandler: nil).cleanupWarning == nil)
            try await mover.restore(item: item, progressHandler: nil)
        } else {
            let first = try await migrator.migrateAndComplete(item: item, externalRootURL: firstDrive,
                appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
            #expect(first.cleanupWarning == nil)
            _ = try await migrator.restore(record: first.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let oldRestore = try #require(try workspace.store.transfers().first)
        #expect(oldRestore.mode == firstMode && oldRestore.direction == .restore)
        let offlineFirst = workspace.rootURL.appendingPathComponent("OfflineFirstLocation")
        func setFirstOnline(_ online: Bool) throws {
            if firstMode == .mount {
                if online { runner.markOnline(uuid) } else { runner.markOffline(uuid) }
            } else {
                try FileManager.default.moveItem(at: online ? offlineFirst : firstDrive,
                    to: online ? firstDrive : offlineFirst)
            }
        }
        try setFirstOnline(false)
        try Data("current restored data".utf8).write(to: source.appendingPathComponent("payload.txt"))

        // Reusing the displayed path cannot borrow the old restore's identity.
        let recordsBeforeReplacement = try workspace.store.transfers()
        let createsBeforeReplacement = runner.commands(prefix: ["apfs", "addVolume"]).count
        let savedLocal = workspace.rootURL.appendingPathComponent("SavedRestoredData")
        try FileManager.default.moveItem(at: source, to: savedLocal)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("foreign local object".utf8).write(to: source.appendingPathComponent("payload.txt"))
        await #expect(throws: (any Error).self) {
            if firstMode == .symlink {
                _ = try await migrator.migrateAndComplete(item: item, externalRootURL: secondDrive,
                    appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
            } else {
                _ = try await mover.migrateAndComplete(item: item, to: secondDrive, progressHandler: nil)
            }
        }
        #expect(try workspace.store.transfers() == recordsBeforeReplacement)
        #expect(runner.commands(prefix: ["apfs", "addVolume"]).count == createsBeforeReplacement)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "foreign local object")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: savedLocal, to: source)

        let nextMount: ContainerMountRecord?
        if firstMode == .symlink {
            let next = try await migrator.migrateAndComplete(item: item, externalRootURL: secondDrive,
                appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
            #expect(next.cleanupWarning != nil)
            nextMount = next.record
        } else {
            #expect(try await mover.migrateAndComplete(item: item, to: secondDrive, progressHandler: nil).cleanupWarning != nil)
            nextMount = nil
        }
        let next = try #require(try workspace.store.transfers().first { $0.priorOperationID == oldRestore.operationID })
        #expect(next.mode != firstMode && next.direction == .migrate && next.isDataSwitchComplete)
        #expect(next.retainedCopyRemovedAt != nil && next.baseline == nil && next.sourceBaseline == nil)
        #expect(try TreeCopySession.retainedRemovalURL(at: URL(fileURLWithPath: #require(next.backupPath)),
            removalID: next.operationID) == nil)
        let migratedGroup = try #require(DataTransferGroup.groups(from: workspace.store.transfers()).first)
        #expect(migratedGroup.currentTransfer.operationID == next.operationID)
        #expect(migratedGroup.retainedCopies.map(\.id) == [oldRestore.operationID])
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "current restored data")
        try Data("written on the second location".utf8).write(to: source.appendingPathComponent("new-user-file.txt"))

        // Reconnecting A does not make it safe to clean while current B is
        // unavailable. Restore the exact B object before retrying any cleanup.
        try setFirstOnline(true)
        let offlineSecond = workspace.rootURL.appendingPathComponent("OfflineSecondLocation")
        if nextMount != nil {
            _ = try await runner.run(executable: "/usr/sbin/diskutil", arguments: ["unmount", source.path], timeout: 1)
            runner.markOffline(uuid)
        } else {
            try FileManager.default.moveItem(at: secondDrive, to: offlineSecond)
        }
        let deletesBeforeReconnect = runner.commands(prefix: ["apfs", "deleteVolume"]).count
        await #expect(throws: (any Error).self) {
            if nextMount != nil { try await migrator.cleanupRetainedLineage(operationID: next.operationID) }
            else { try await mover.cleanupRetainedLineage(operationID: next.operationID) }
        }
        #expect(try workspace.store.transfer(operationID: oldRestore.operationID)?.retainedCopyRemovedAt == nil)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == deletesBeforeReconnect)
        if let nextMount {
            #expect(FileManager.default.fileExists(atPath: firstDrive.appendingPathComponent("Payload").path))
            runner.markOnline(uuid)
            try await migrator.mount(record: nextMount)
        } else {
            #expect(runner.detachedContents(for: uuid) != nil)
            try FileManager.default.moveItem(at: offlineSecond, to: secondDrive)
        }

        try setFirstOnline(false)
        if let nextMount {
            #expect(try await migrator.restoreAndComplete(record: nextMount, estimatedTotalBytes: 0, progressHandler: nil) != nil)
        } else {
            #expect(try await mover.restoreAndComplete(item: item, progressHandler: nil).cleanupWarning != nil)
        }
        let terminal = try #require(try workspace.store.transfers().first { $0.priorOperationID == next.operationID })
        #expect(terminal.direction == .restore && terminal.retainedCopyRemovedAt != nil)
        #expect(!runner.isMounted(source))
        #expect(try workspace.store.recordsStrict().isEmpty && workspace.store.managedLinks().isEmpty)
        let restoredGroup = try #require(DataTransferGroup.groups(from: workspace.store.transfers()).first)
        #expect(restoredGroup.currentTransfer.operationID == terminal.operationID)
        #expect(restoredGroup.retainedCopies.map(\.id) == [oldRestore.operationID])
        #expect(try String(contentsOf: source.appendingPathComponent("new-user-file.txt"), encoding: .utf8) == "written on the second location")
        let restoredData = try TreeCopySession.snapshot(at: source)

        try setFirstOnline(true)
        let coldStore = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("container-mounts.plist"))
        let coldMount = workspace.makeMigrator(runner: runner, storeOverride: coldStore)
        let coldMover = DataDirMover(homeDir: home, store: coldStore, runner: SyntheticNoWritersRunner(), mountMigrator: coldMount)
        if nextMount != nil { try await coldMount.cleanupRetainedLineage(operationID: terminal.operationID) }
        else { try await coldMover.cleanupRetainedLineage(operationID: terminal.operationID) }
        #expect(try coldStore.transfers().isEmpty)
        #expect(try TreeCopySession.snapshot(at: source) == restoredData)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]) == [["apfs", "deleteVolume", "disk7s9"]])
        for drive in [firstDrive, secondDrive] {
            #expect(try String(contentsOf: drive.appendingPathComponent("sentinel.txt"), encoding: .utf8) == "unrelated")
            #expect(!FileManager.default.fileExists(atPath: drive.appendingPathComponent("Payload").path))
        }
    }

    @Test("A replaced local restore root cannot authorize migration to a new volume")
    func remigrationMountRejectsReplacedRestoredRoot() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let oldUUID = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: oldUUID)
        let migrator = workspace.makeMigrator(runner: runner)
        let old = try await migrator.migrateAndComplete(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        _ = try await migrator.restore(record: old.record, estimatedTotalBytes: 0, progressHandler: nil)
        runner.markOffline(oldUUID)
        let before = try workspace.store.transfers()
        try FileManager.default.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent("SavedRestoredData"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("unrelated replacement".utf8).write(to: source.appendingPathComponent("payload.txt"))
        let creationCount = runner.commands(prefix: ["apfs", "addVolume"]).count
        await #expect(throws: (any Error).self) {
            try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
                appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        }
        #expect(try workspace.store.transfers() == before)
        #expect(runner.commands(prefix: ["apfs", "addVolume"]).count == creationCount)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "unrelated replacement")
    }

    @Test("Volume deletion followed by a failed ledger save finishes after restart without deleting twice")
    func completedVolumeDeletionCanFinishRecord() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migration = try await workspace.makeMigrator(runner: runner).migrateAndComplete(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        #expect(migration.cleanupWarning == nil)
        let ledgerURL = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        let refusingStore = ContainerMountStore(fileURL: ledgerURL, writeData: { data, url in
            let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            if (document?["transfers"] as? [Any])?.isEmpty == true { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let warning = try await workspace.makeMigrator(runner: runner, storeOverride: refusingStore)
            .restoreAndComplete(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        #expect(warning?.transferOperationID != nil)
        let record = try #require(try workspace.store.transfers().first)
        #expect(record.isDataSwitchComplete)
        #expect(record.cleanupVolumeContainerUUID != nil)
        #expect(DataTransferGroup(transfer: record).canCleanup)
        let snapshot = try TreeCopySession.snapshot(at: source)
        let cold = workspace.makeMigrator(runner: runner, storeOverride: ContainerMountStore(fileURL: ledgerURL))
        // An unavailable inventory cannot pretend the old volume was deleted.
        runner.failWhen(prefix: ["apfs", "list"])
        await #expect(throws: (any Error).self) { try await cold.cleanupRetainedTransfer(operationID: record.operationID) }
        #expect(try workspace.store.transfers().count == 1)
        runner.clearFailure()
        try await cold.cleanupRetainedTransfer(operationID: record.operationID)
        #expect(try workspace.store.transfers().isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        #expect(try TreeCopySession.snapshot(at: source) == snapshot)
    }

    @Test("A deleted volume retries its parent sync after restart and cannot accept a replaced parent")
    func completedVolumeDeletionRetriesSynchronization() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migration = try await workspace.makeMigrator(runner: runner).migrateAndComplete(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        #expect(migration.cleanupWarning == nil)

        let syncAttempts = Counter()
        let failSync: @Sendable (URL) throws -> Void = { _ in
            syncAttempts.increment()
            throw POSIXError(.EIO)
        }
        let warning = try await workspace.makeMigrator(runner: runner, synchronizeCleanupParent: failSync)
            .restoreAndComplete(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        let operationID = try #require(warning?.transferOperationID)
        let retained = try #require(try workspace.store.transfer(operationID: operationID))
        #expect(retained.phase == .cleanupRequested && retained.retainedCopyRemovedAt == nil)
        #expect(retained.baseline != nil && retained.sourceBaseline != nil)
        #expect(retained.cleanupParentIdentity != nil && retained.cleanupVolumeContainerUUID != nil)
        #expect(DataTransferGroup(transfer: retained).canCleanup)
        #expect(syncAttempts.value == 1)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        let mountCount = runner.commands(prefix: ["mount"]).count
        try Data("new content after restore".utf8).write(to: source.appendingPathComponent("new-user-file.txt"))
        let currentData = try TreeCopySession.snapshot(at: source)

        let ledgerURL = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        let cold = workspace.makeMigrator(runner: runner, storeOverride: ContainerMountStore(fileURL: ledgerURL),
            synchronizeCleanupParent: failSync)
        // The inventory now confirms absence, but the original failed barrier
        // must be retried instead of dropping the full recovery record.
        await #expect(throws: (any Error).self) { try await cold.cleanupRetainedTransfer(operationID: operationID) }
        let pending = try #require(try workspace.store.transfer(operationID: operationID))
        #expect(pending.retainedCopyRemovedAt == nil && pending.baseline == retained.baseline)
        #expect(pending.sourceBaseline == retained.sourceBaseline && pending.cleanupParentIdentity == retained.cleanupParentIdentity)
        #expect(pending.cleanupVolumeContainerUUID == retained.cleanupVolumeContainerUUID)
        #expect(syncAttempts.value == 2)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        #expect(try TreeCopySession.snapshot(at: source) == currentData)

        // Parent identity was valid at entry. Replace it during the asynchronous
        // inventory check to verify the shared completion tail rechecks it.
        let parent = URL(fileURLWithPath: try #require(retained.backupPath)).deletingLastPathComponent().resolvingSymlinksInPath()
        let savedParent = workspace.rootURL.appendingPathComponent("SavedCleanupParent")
        runner.mutateBeforeCommand(["apfs", "list", "-plist"]) {
            try FileManager.default.moveItem(at: parent, to: savedParent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data("unrelated parent".utf8).write(to: parent.appendingPathComponent("sentinel.txt"))
        }
        await #expect(throws: (any Error).self) { try await cold.cleanupRetainedTransfer(operationID: operationID) }
        let afterReplacement = try #require(try workspace.store.transfer(operationID: operationID))
        #expect(afterReplacement.retainedCopyRemovedAt == nil && afterReplacement.baseline == retained.baseline)
        #expect(afterReplacement.cleanupParentIdentity == retained.cleanupParentIdentity)
        #expect(syncAttempts.value == 2)
        #expect(try String(contentsOf: parent.appendingPathComponent("sentinel.txt"), encoding: .utf8) == "unrelated parent")
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: savedParent, to: parent)

        let retry = workspace.makeMigrator(runner: runner, storeOverride: ContainerMountStore(fileURL: ledgerURL),
            synchronizeCleanupParent: { parent in
                syncAttempts.increment()
                try DurableFileIO.syncDirectory(at: parent)
            })
        try await retry.cleanupRetainedTransfer(operationID: operationID)
        try await retry.cleanupRetainedTransfer(operationID: operationID)
        #expect(try workspace.store.transfers().isEmpty)
        #expect(syncAttempts.value == 3)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        #expect(runner.commands(prefix: ["mount"]).count == mountCount)
        #expect(try TreeCopySession.snapshot(at: source) == currentData)
    }

    enum VolumeDeletionFailure: String, CaseIterable, Sendable {
        case missingVolume, queryFailure, initialUUIDMismatch, initialNonAPFS, emptyDevice
        case changedUUID, changedDevice, changedFilesystem, deviceQueryFailure

        var reachesDeviceQuery: Bool {
            switch self {
            case .changedUUID, .changedDevice, .changedFilesystem, .deviceQueryFailure: return true
            default: return false
            }
        }
    }

    @Test("A reentrant resume cannot roll back the migration that owns the path")
    func reentrantResumeDoesNotRecoverAnotherOperation() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "ReentrantResume")
        let runner = FakeDiskCommandRunner()
        let migrator = workspace.makeMigrator(runner: runner)
        let probes = ResumeProbeCount()
        let result = try await migrator.migrateAndComplete(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil) { progress in
                guard progress.currentFile == "正在切换本地入口...".localized else { return }
                await probes.record()
                do {
                    let pending = try #require(try workspace.store.transfers().first)
                    let commands = runner.calls
                    do {
                        _ = try await migrator.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
                        Issue.record("The already owned path must reject reentrant resume")
                    } catch {
                        guard case DataOperationSafety.Failure.occupied(let path) = error else {
                            Issue.record("Admission error unexpectedly triggered recovery: \(error)"); return
                        }
                        #expect(path == source.path)
                    }
                    #expect(try workspace.store.transfer(operationID: pending.operationID) == pending)
                    #expect(runner.calls == commands)
                } catch { Issue.record("Could not inspect the migration: \(error)") }
            }
        #expect(await probes.count == 1)
        #expect(result.cleanupWarning == nil)
        #expect(runner.isMounted(source))
        #expect(try workspace.store.transfers().isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    private actor ResumeProbeCount {
        var count = 0
        func record() { count += 1 }
    }

    /// Scripted diskutil replies only; this runner never invokes a disk command.
    @Test("Normal migration restores the original entry and removes its unused volume after final mount failure")
    func normalMigrationAutomaticallyRollsBack() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "AutomaticRollback")
        let original = try DataPathIdentity.capture(source)
        let runner = FakeDiskCommandRunner()
        runner.failWhen(prefix: ["mount", "nobrowse", "-mountPoint", source.path])
        let migrator = workspace.makeMigrator(runner: runner)
        await #expect(throws: ContainerVolumeMigrator.AutomaticRecoveryError.self) {
            try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
                appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        }
        #expect(try DataPathIdentity.capture(source).matchesFilesystemObject(original))
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(!runner.isMounted(source))
        #expect(try workspace.store.recordsStrict().isEmpty)
        #expect(try workspace.store.transfers().isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        runner.clearFailure()
        _ = try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        #expect(runner.isMounted(source))
    }

    @Test("Cancelling normal migration does not cancel its automatic rollback")
    func cancelledMigrationKeepsAutomaticRollbackAlive() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "CancelledCopy")
        let runner = FakeDiskCommandRunner()
        let migrator = workspace.makeMigrator(runner: runner)
        let task = Task {
            try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
                appName: "Synthetic", bundleIdentifier: nil) { progress in
                    if progress.copiedBytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(!runner.isMounted(source))
        #expect(try workspace.store.transfers().isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
    }

    @Test("An unmount failure restores the mount record and ordinary restore can be retried")
    func normalRestoreAutomaticallyRestoresItsMountRecord() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "RestoreRollback")
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        let migration = try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        runner.failWhen(prefix: ["unmount", source.path])
        await #expect(throws: ContainerVolumeMigrator.AutomaticRecoveryError.self) {
            try await migrator.restoreAndComplete(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        #expect(runner.mountedUUID(at: source) == uuid)
        #expect(try workspace.store.recordsStrict() == [migration.record])
        #expect(try workspace.store.transfers().isEmpty)
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        runner.clearFailure()
        #expect(try await migrator.restoreAndComplete(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil) == nil)
        #expect(!runner.isMounted(source))
        #expect(try workspace.store.recordsStrict().isEmpty)
    }

    @Test("An unavailable first transaction does not starve independent automatic recovery")
    func automaticMaintenanceContinuesAfterUnavailableData() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let first = try workspace.makeContainerDirectory(named: "Unavailable")
        let second = try workspace.makeContainerDirectory(named: "Recoverable")
        var attempts: [DataTransferRecord] = []
        for source in [first, second] {
            let attempt = DataTransferRecord(mode: .mount, direction: .migrate, sourceID: source.path,
                appName: "Synthetic", dataDirType: DataDirType.containers.rawValue,
                originalPath: source.path, activePath: source.path, destinationPath: source.path,
                sourceIdentity: try DataPathIdentity.capture(source))
            try workspace.store.beginTransfer(attempt)
            attempts.append(attempt)
        }
        // Model a disconnected/unavailable original without deleting its data.
        let saved = first.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: first, to: saved)
        await workspace.makeMigrator(runner: FakeDiskCommandRunner()).performAutomaticMaintenance()
        #expect(try workspace.store.transfer(operationID: attempts[0].operationID) != nil)
        #expect(try workspace.store.transfer(operationID: attempts[1].operationID) == nil)
        #expect(try String(contentsOf: saved.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(try String(contentsOf: second.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("Related legacy cleanup cannot prevent restoring live data or delete separate historical material")
    func legacyCleanupDoesNotBlockRestoringCurrentData() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "LegacyCleanup")
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        let migration = try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        let extra = source.deletingLastPathComponent().appendingPathComponent("OldRestoreStaging")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
        try Data("independent old material".utf8).write(to: extra.appendingPathComponent("keep"))
        try workspace.store.recordMigration(migration.record, cleanup: ContainerCleanupRecord(kind: .migrationBackup,
            mountRecord: migration.record, localPath: source.path, restoreStagingPath: extra.path))
        #expect(try await migrator.restoreAndComplete(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil) == nil)
        #expect(try workspace.store.pendingCleanups().isEmpty)
        #expect(try String(contentsOf: extra.appendingPathComponent("keep"), encoding: .utf8) == "independent old material")
        #expect(try workspace.store.recordsForInspection().preservedMaterials.first?.paths == [extra.path])
        #expect(!runner.isMounted(source))
    }

    @Test("A foreground migration reconciles an old completed restore without awaiting background maintenance")
    func legacyRestoreCleanupAllowsNextMigration() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "LegacyRestored")
        let legacy = workspace.record(mountPoint: source)
        let cleanup = ContainerCleanupRecord(kind: .restoredVolume, mountRecord: legacy, localPath: source.path)
        try workspace.store.beginRestore(cleanup)
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        let result = try await migrator.migrateAndComplete(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        #expect(result.cleanupWarning == nil)
        #expect(try workspace.store.pendingCleanups().isEmpty)
        #expect(try workspace.store.preservedMaterials().first?.volumeUUID == legacy.volumeUUID)
        #expect(runner.isMounted(source))
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("Reusing manifest parsing still reads changed journal bytes and rejects malformed contracts")
    func manifestParsingNeverCachesTheLedgerOrFilesystem() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "ManifestCache")
        let runner = FakeDiskCommandRunner()
        let result = try await workspace.makeMigrator(runner: runner).migrate(item: workspace.item(for: source),
            externalRootURL: workspace.externalRootURL, appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        let saved = try #require(try workspace.store.transfer(operationID: result.operationID))
        _ = try workspace.store.transfers() // warm all summaries for these exact bytes
        _ = try workspace.store.recordsForInspection()
        let ledger = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        var document = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: ledger), format: nil) as? [String: Any])
        var transfers = try #require(document["transfers"] as? [[String: Any]])
        let encodedBaseline = try #require(saved.sourceBaseline)
        var manifest = try #require(PropertyListSerialization.propertyList(from: encodedBaseline, format: nil) as? [String: Any])
        var entries = try #require(manifest["entries"] as? [[String: Any]])
        entries[0]["resourceFork"] = ["size": -1, "digest": Data(repeating: 0, count: 32)]
        manifest["entries"] = entries
        transfers[0]["sourceBaseline"] = try PropertyListSerialization.data(fromPropertyList: manifest, format: .binary, options: 0)
        document["transfers"] = transfers
        let changed = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        try changed.write(to: ledger)
        #expect(throws: ContainerMountStore.StoreError.self) { try workspace.store.transfers() }
        #expect(try workspace.store.recordsForInspection().validationError != nil)
        await #expect(throws: (any Error).self) {
            try await workspace.makeMigrator(runner: runner).cleanupRetainedTransfer(operationID: result.operationID)
        }
        #expect(try Data(contentsOf: ledger) == changed)
        let backup = URL(fileURLWithPath: try #require(saved.backupPath))
        #expect(try String(contentsOf: backup.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    @Test("Restore links a prior migration whose UUID differs only in case")
    func restoresCaseInsensitiveMigrationUUID() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "CaseInsensitiveUUID")
        let uuid = try #require(try DataPathIdentity.capture(source).volumeUUID)
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        let migration = try await migrator.migrate(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        var pending = try #require(try workspace.store.transfer(operationID: migration.operationID))
        pending.createdVolumeUUID = uuid.lowercased()
        try workspace.store.updateTransfer(pending)
        _ = try await migrator.restoreAndComplete(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        #expect(!runner.isMounted(source))
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
    }

    private final class VolumeDeletionRunner: ShellCommandRunning, @unchecked Sendable {
        static let volumeUUID = "ABCDEF01-2345-6789-ABCD-0123456789AB"
        private let lock = NSLock()
        private var recordedCalls: [[String]] = []
        private let failure: VolumeDeletionFailure?

        init(failure: VolumeDeletionFailure? = nil) { self.failure = failure }

        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recordedCalls }

        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            try reply(to: arguments)
        }

        private func reply(to arguments: [String]) throws -> ShellCommandResult {
            lock.lock(); defer { lock.unlock() }
            recordedCalls.append(arguments)
            if Array(arguments.prefix(2)) == ["apfs", "deleteVolume"] {
                return ShellCommandResult(status: 0, standardOutput: Data(), standardError: Data(), timedOut: false)
            }
            guard arguments == ["info", "-plist", Self.volumeUUID] || arguments == ["info", "-plist", "disk7s9"] else {
                throw CocoaError(.fileReadUnknown)
            }
            let firstQuery = arguments.last == Self.volumeUUID
            if firstQuery && failure == .queryFailure || !firstQuery && failure == .deviceQueryFailure {
                throw CocoaError(.fileReadNoPermission)
            }
            if firstQuery && failure == .missingVolume {
                return ShellCommandResult(status: 1, standardOutput: Data(),
                    standardError: Data("Could not find disk".utf8), timedOut: false)
            }
            var info: [String: Any] = [
                "DeviceIdentifier": "disk7s9",
                "VolumeUUID": Self.volumeUUID.lowercased(),
                "FilesystemType": "apfs"
            ]
            switch (firstQuery, failure) {
            case (true, .initialUUIDMismatch), (false, .changedUUID): info["VolumeUUID"] = "00000000-1111-2222-3333-444444444444"
            case (true, .initialNonAPFS), (false, .changedFilesystem): info["FilesystemType"] = "hfs"
            case (true, .emptyDevice): info["DeviceIdentifier"] = " \n"
            case (false, .changedDevice): info["DeviceIdentifier"] = "disk7s10"
            default: break
            }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            return ShellCommandResult(status: 0, standardOutput: data, standardError: Data(), timedOut: false)
        }
    }

    @Test("APFS round trips stay within the reduced content-read budget")
    func contentReadBudget() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "ReadBudget")
        let uuid = try #require(DiskUtility.mountedVolumeUUID(at: source))
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        let bytes = Double(try Data(contentsOf: source.appendingPathComponent("payload.txt")).count)
        let migration = DataTransferSession()
        let moved = try await DataTransferSession.$current.withValue(migration) {
            try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
                appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        }
        #expect(moved.cleanupWarning == nil)
        #expect(try #require(migration.measurements["hashReadBytes"]) <= 5 * bytes)
        let restore = DataTransferSession()
        let warning = try await DataTransferSession.$current.withValue(restore) {
            try await migrator.restoreAndComplete(record: moved.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        #expect(warning == nil)
        #expect(try #require(restore.measurements["hashReadBytes"]) <= 4 * bytes)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data("payload".utf8))
        #expect(try workspace.store.transfers().isEmpty)
    }

    @Test("APFS deferred readback rejects changes in the final switching callback",
          arguments: [DataTransferRecord.Direction.migrate, .restore], [false, true])
    func lateSwitchChanges(direction: DataTransferRecord.Direction, changeDestination: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "LateSwitch")
        let uuid = try #require(DiskUtility.mountedVolumeUUID(at: source))
        let runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
        let migrator = workspace.makeMigrator(runner: runner)
        var record: ContainerMountRecord?
        if direction == .restore {
            record = try await migrator.migrateAndComplete(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
                appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil).record
        }
        let progress: FileCopier.ProgressHandler = { value in
            guard value.currentFile == "正在切换本地入口...".localized else { return }
            do {
                let pending = try #require(try workspace.store.transfers().first)
                #expect(pending.baseline == nil)
                let changed = changeDestination ? URL(fileURLWithPath: try #require(pending.preparationPath)) : source
                try Data("late data".utf8).write(to: changed.appendingPathComponent("payload.txt"))
            } catch { Issue.record(error) }
        }
        await #expect(throws: (any Error).self) {
            if let record {
                try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: progress)
            } else {
                try await migrator.migrate(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
                    appName: "Synthetic", bundleIdentifier: nil, progressHandler: progress)
            }
        }
        let pending = try #require(try workspace.store.transfers().first)
        #expect(!pending.isDataSwitchComplete)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.txt")) == Data((changeDestination ? "payload" : "late data").utf8))
        #expect(runner.isMounted(source) == (direction == .restore))
    }

    private final class Workspace {
        let rootURL: URL
        let externalRootURL: URL
        let store: ContainerMountStore
        private let agentSyncCounter = Counter()

        var agentSyncCount: Int { agentSyncCounter.value }

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContainerVolumeMigratorTests-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            externalRootURL = rootURL.appendingPathComponent("External/AppPorts")
            try FileManager.default.createDirectory(at: externalRootURL, withIntermediateDirectories: true)
            store = ContainerMountStore(fileURL: rootURL.appendingPathComponent("container-mounts.plist"))
        }

        func makeMigrator(
            runner: FakeDiskCommandRunner,
            storeOverride: ContainerMountStore? = nil,
            administratorRunner: DiskUtility.AdministratorRunner? = nil,
            volumeUUIDMarker: (@Sendable (URL) -> String?)? = nil,
            mountedVolumeUUID: (@Sendable (URL) -> String?)? = nil,
            availableCapacity: @escaping @Sendable (URL) -> Int64? = { _ in nil },
            mountFlags: @escaping @Sendable (URL) -> UInt32? = { _ in UInt32(MNT_DONTBROWSE) },
            safetyRunner: any ShellCommandRunning = SyntheticNoWritersRunner(),
            makeMountPointLease: (@Sendable (URL) throws -> any MountPointLeasing)? = nil,
            removeMigrationBackup: @escaping @Sendable (URL) throws -> Void = { try FileCopier.removeCopy(at: $0) },
            synchronizeCleanupParent: @escaping @Sendable (URL) throws -> Void = { try DurableFileIO.syncDirectory(at: $0) }
        ) -> ContainerVolumeMigrator {
            let counter = agentSyncCounter
            let externalRoot = externalRootURL.path
            return ContainerVolumeMigrator(
                disk: DiskUtility(runner: runner, commandTimeout: 5, administratorRunner: administratorRunner),
                store: storeOverride ?? store,
                stagingMountRootURL: rootURL.appendingPathComponent("mounts"),
                isMountPoint: { runner.isMounted($0) },
                mountedVolumePath: { url in url.path.hasPrefix(externalRoot) ? "/Volumes/hano" : "/" },
                mountedVolumeUUID: mountedVolumeUUID ?? { runner.mountedUUID(at: $0) },
                // 默认不认任何卷根标记（走 diskutil 兜底）；测快路径的用例再显式注入。
                volumeUUIDMarker: volumeUUIDMarker ?? { _ in nil },
                synchronizeAgent: { _ in counter.increment() },
                availableCapacity: availableCapacity,
                mountFlags: mountFlags,
                homeDirectory: rootURL.appendingPathComponent("Home"),
                safetyRunner: safetyRunner,
                makeMountPointLease: makeMountPointLease ?? { try runner.makeMountPointLease(at: $0) },
                removeMigrationBackup: removeMigrationBackup,
                synchronizeCleanupParent: synchronizeCleanupParent
            )
        }

        func makeContainerDirectory(named name: String) throws -> URL {
            let url = rootURL.appendingPathComponent("Home/Library/Containers/com.example.chat/Data/Documents/\(name)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: url.appendingPathComponent("payload.txt"))
            return url
        }

        func record(mountPoint: URL, volumeUUID: String = "VOLUME-UUID-disk7s9") -> ContainerMountRecord {
            ContainerMountRecord(
                appName: "Chat",
                bundleIdentifier: "com.example.chat",
                dataDirType: DataDirType.containers.rawValue,
                mountPointPath: mountPoint.path,
                volumeUUID: volumeUUID,
                volumeName: "AppPorts-test",
                externalRootPath: externalRootURL.path
            )
        }

        func item(for url: URL) -> DataDirItem {
            DataDirItem(name: url.lastPathComponent, path: url, type: .containers, priority: .critical, description: "fixture")
        }

        func cleanup() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["-R", "u+rwx", rootURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    private final class CleanupCheckpointMutationWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var mutated = false
        private let mutation: @Sendable () throws -> Void

        init(mutation: @escaping @Sendable () throws -> Void) { self.mutation = mutation }

        var didMutate: Bool { lock.lock(); defer { lock.unlock() }; return mutated }

        func write(_ data: Data, to url: URL) throws {
            lock.lock(); defer { lock.unlock() }
            let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let transfers = object?["transfers"] as? [[String: Any]] ?? []
            try data.write(to: url, options: .atomic)
            if !mutated, transfers.contains(where: { $0["cleanupParentIdentity"] != nil }) {
                try mutation()
                mutated = true
            }
        }
    }

    private final class FailingSwitchWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func write(_ data: Data, to url: URL) throws {
            lock.lock(); defer { lock.unlock() }
            let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let transfers = object?["transfers"] as? [[String: Any]] ?? []
            if !failed, transfers.contains(where: { $0["phase"] as? String == "switching" && $0["direction"] as? String == "restore" }) {
                failed = true
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
    }

    private final class FailingRecordWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let failingWrite: Int

        init(failingWrite: Int) { self.failingWrite = failingWrite }

        func write(_ data: Data, to url: URL) throws {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if count == failingWrite { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
    }
}
