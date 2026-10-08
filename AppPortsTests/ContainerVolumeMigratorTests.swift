import Darwin
import Foundation
import Testing
@testable import AppPorts

/// 记录 diskutil 调用并按脚本返回结果；挂载状态用一张共享表模拟。
final class FakeDiskCommandRunner: ShellCommandRunning, @unchecked Sendable {
    struct Call: Equatable {
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
    private var mountCommandCount = 0
    private var foreignAutomount: ForeignAutomount?
    private var hidesContentsOnUnmount = false
    private var stashedContents: [URL] = []
    private var underlyingDirectories: [String: URL] = [:]
    private var detachedVolumes: [String: URL] = [:]
    private var substitutedMount: (after: Int, volumeUUID: String)?

    /// 模拟开机/插盘时系统抢先把卷挂到别处：第 `after` 次 mount 命令照样返回成功，
    /// 但卷实际落在 `path` 上（真实行为：卷已挂载时 diskutil 忽略 -mountPoint 参数）。
    private struct ForeignAutomount {
        let volume: String
        let path: String
        let after: Int
        let repeating: Bool
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
        createdVolumeUUID ?? "VOLUME-UUID-\(device)"
    }

    func failWhen(prefix: [String]) {
        lock.lock(); defer { lock.unlock() }
        failingCommandPrefix = prefix
    }

    func clearFailure() {
        lock.lock(); defer { lock.unlock() }
        failingCommandPrefix = nil
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

    func markOnline(_ volume: String) {
        lock.lock(); defer { lock.unlock() }
        onlineVolumes.insert(volume)
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
            let device = target.hasPrefix("disk") ? target : "disk7s\(nextDeviceNumber)"
            var plist: [String: Any] = [
                "DeviceIdentifier": device,
                "VolumeUUID": target.hasPrefix("disk") ? volumeUUID(for: target) : target,
                "VolumeName": "AppPortsTest",
                "FilesystemType": "apfs",
                "APFSContainerReference": containerReference
            ]
            if let mountPath = mountPathByVolume[target] {
                plist["MountPoint"] = mountPath
            }
            return success(plist: plist)
        case "apfs" where subcommand == "list":
            let volumes = createdVolumeNames.map { device, name in
                ["APFSVolumeUUID": volumeUUID(for: device), "DeviceIdentifier": device, "Name": name]
            }
            return success(plist: ["Containers": [["ContainerReference": containerReference, "APFSContainerUUID": "TEST-CONTAINER-UUID", "Volumes": volumes]]])
        case "-A":
            let device = "disk7s\(nextDeviceNumber)"
            onlineVolumes.insert(device)
            onlineVolumes.insert(volumeUUID(for: device))
            createdVolumeNames[device] = arguments.dropFirst(7).first ?? "AppPortsTest"
            return success(text: "Will export new APFS Volume from APFS Container Reference \(containerReference)\nCreated new APFS Volume \(device)\n")
        case "apfs" where subcommand == "deleteVolume":
            let target = arguments.last ?? ""
            onlineVolumes.remove(target)
            onlineVolumes.remove(volumeUUID(for: target))
            createdVolumeNames.removeValue(forKey: target)
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
            let path = Self.normalized(arguments.last ?? "")
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
        guard case .requiresIntervention = outcomes.first?.state else { Issue.record("Must not relax advanced restore intent"); return }
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
        guard case .requiresIntervention = outcomes.first?.state else { Issue.record("Must keep conflicting data blocked"); return }
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
        #expect(result.record.ownershipPolicy == .owners)
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        var document = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        var mounts = try #require(document["mounts"] as? [[String: Any]])
        mounts[0].removeValue(forKey: "ownershipPolicy")
        document["mounts"] = mounts
        document["schemaVersion"] = 3
        let legacyBytes = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        try legacyBytes.write(to: file)
        let old = try #require(try workspace.store.recordsStrict().first)
        #expect(old.ownershipPolicy == nil)
        #expect(try Data(contentsOf: file) == legacyBytes)
        let noowners = workspace.makeMigrator(runner: runner, mountFlags: { _ in UInt32(MNT_IGNORE_OWNERSHIP) })
        await #expect(throws: (any Error).self) { try await noowners.mount(record: old) }
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
        #expect(runner.commands(prefix: ["-A"]) == [["-A", "-w", "-U", String(getuid()), "-G", String(getgid()), "-v", record.volumeName, "disk7"]])
        let mounts = runner.commands(prefix: ["mount"])
        #expect(mounts.count == 2)
        #expect(mounts.last == ["mount", "nobrowse", "-mountPoint", source.path, "-mountOptions", "owners", record.volumeUUID])
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
        #expect(runner.commands(prefix: ["-A"]).isEmpty)
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
            guard case .requiresIntervention = outcomes.first?.state else {
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
            // Failed final mounts leave a sealed placeholder. Reading inside it
            // would require changing the very permissions reentry must preserve.
            #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int == 0)
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
        let record = workspace.record(mountPoint: source)
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

    @Test("Failed ownership update restores current flags and reports rollback failure", arguments: [false, true], [false, true])
    func restoreRollsBackOwnershipUpdate(rollbackFails: Bool, fastUUIDAvailable: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try workspace.makeContainerDirectory(named: "Legacy")
        let record = workspace.record(mountPoint: source)
        try workspace.store.upsert(record)
        let flags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_NODEV | MNT_NOSUID | MNT_DONTBROWSE)
        let runner = FakeDiskCommandRunner(onlineVolumes: [record.volumeUUID])
        runner.markVolumeMounted(record.volumeUUID, at: source.path)
        if rollbackFails { runner.failWhen(prefix: ["-u"]) }
        let service = workspace.makeMigrator(runner: runner,
            mountedVolumeUUID: { fastUUIDAvailable ? runner.mountedUUID(at: $0) : nil }, mountFlags: { _ in flags })
        do {
            _ = try await service.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
            Issue.record("Restore must fail while flags still report noowners")
        } catch {
            if rollbackFails {
                guard case ContainerVolumeMigrator.MigrationError.ownershipRollbackFailed = error else {
                    Issue.record("Rollback failure was not surfaced: \(error)"); return
                }
            }
            let failed = try #require(try workspace.store.transfers().first)
            #expect(failed.recoverableReason == error.localizedDescription)
            #expect(failed.isUnstartedMountRestore)
            #expect(failed.legacyMountFlags == flags)
        }
        #expect(runner.commands(prefix: ["-u"]).map { $0[2] } == ["nobrowse,nodev,nosuid,owners", "nobrowse,nodev,nosuid,noowners"])
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
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
        let foreignPath = URL(fileURLWithPath: runner.commands(prefix: ["mount"])[mountCommand - 1][3])
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
        #expect(try workspace.store.transfer(operationID: retained.operationID)?.phase == .cleanupRequested)
        #expect(workspace.store.records().map(\.id) == [result.record.id])
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
        #expect(try workspace.store.transfer(operationID: transfer.operationID)?.phase == .cleanupRequested)
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
        let runner = FakeDiskCommandRunner()
        let source = try workspace.makeContainerDirectory(named: "Payload")
        let migrator = workspace.makeMigrator(runner: runner)
        let record = try await migrator.migrate(item: workspace.item(for: source), externalRootURL: workspace.externalRootURL,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil).record
        let transfer = try #require(try workspace.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
        let moved = workspace.rootURL.appendingPathComponent("temporarily-moved")
        try FileManager.default.moveItem(at: backup, to: moved)
        await #expect(throws: (any Error).self) { try await migrator.cleanupRetainedTransfer(operationID: transfer.operationID) }
        #expect(try workspace.store.transfer(operationID: transfer.operationID)?.phase == .cleanupRequested)
        try FileManager.default.moveItem(at: moved, to: backup)
        try await migrator.unmount(record: record)
        try await migrator.mount(record: record)
        #expect(runner.isMounted(source))
        _ = try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        #expect(!runner.isMounted(source))
        #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        let restore = try #require(try workspace.store.transfers().first { $0.direction == .restore })
        await #expect(throws: (any Error).self) { try await migrator.cleanupRetainedTransfer(operationID: restore.operationID) }
        #expect(try workspace.store.transfer(operationID: restore.operationID)?.phase == .awaitingUserVerification)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        try await migrator.cleanupRetainedTransfer(operationID: transfer.operationID)
        #expect(try workspace.store.transfer(operationID: transfer.operationID) == nil)
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

    @Test("Explicit restored-volume deletion failure preserves both copies across two cold opens")
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
        #expect(recovery.phase == .needsRecovery)
        #expect(recovery.baseline == restore.baseline)
        #expect(recovery.sourceIdentity == restore.sourceIdentity)
        #expect(recovery.destinationIdentity == restore.destinationIdentity)
        #expect(recovery.recoverableReason?.isEmpty == false)
        let detached = try #require(runner.detachedContents(for: uuid))
        #expect(try String(contentsOf: detached.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
        let file = workspace.rootURL.appendingPathComponent("container-mounts.plist")
        let ledger = try Data(contentsOf: file)
        let calls = runner.calls
        let activeSnapshot = try TreeCopySession.snapshot(at: source)
        let retainedSnapshot = try TreeCopySession.snapshot(at: detached)
        for _ in 0..<2 {
            let coldStore = ContainerMountStore(fileURL: file)
            let coldMigrator = workspace.makeMigrator(runner: runner, storeOverride: coldStore)
            #expect(await coldMigrator.remountAvailableRecords().isEmpty)
            await #expect(throws: (any Error).self) {
                try await coldMigrator.cleanupRetainedTransfer(operationID: restore.operationID)
            }
            #expect(try coldStore.unfinishedTransfers() == [recovery])
            #expect(try coldStore.recordsStrict().isEmpty)
            #expect(try Data(contentsOf: file) == ledger)
            #expect(runner.calls == calls)
            #expect(try TreeCopySession.snapshot(at: source) == activeSnapshot)
            #expect(try TreeCopySession.snapshot(at: detached) == retainedSnapshot)
            #expect(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8) == "new local data")
            #expect(!runner.isMounted(source))
            #expect(!runner.isMounted(URL(fileURLWithPath: try #require(recovery.backupPath))))
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

        #expect(result != nil)
        #expect(runner.commands(prefix: ["unmount"]).isEmpty)
        #expect(runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try workspace.store.pendingCleanups().count == 1)
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

        guard case .requiresIntervention(let message)? = outcomes.first?.state else {
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
        #expect(elevatedMounts.last == ["sudo", "mount", "nobrowse", "-mountPoint", source.path, "-mountOptions", "owners", record.volumeUUID])
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
                                  "-mountOptions", "owners", "VOLUME-UUID-disk7s9"]
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

    @Test("A volume stuck on its system mount point fails loudly and leaves the container path alone")
    func reportsFailureWhenSystemMountPointCannotBeDetached() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let runner = FakeDiskCommandRunner(onlineVolumes: ["AUTO-UUID"])
        let migrator = workspace.makeMigrator(runner: runner)
        let mountPoint = try workspace.makeContainerDirectory(named: "Payload")
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
            #expect(url.path == systemMountPoint)
        }

        #expect(runner.commands(prefix: ["mount"]).isEmpty)
        #expect(runner.isMounted(mountPoint) == false)
        // 容器路径上的本地数据必须原样保留。
        #expect(try String(contentsOf: mountPoint.appendingPathComponent("payload.txt"), encoding: .utf8) == "payload")
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
            removeMigrationBackup: @escaping @Sendable (URL) throws -> Void = { try FileCopier.removeCopy(at: $0) }
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
                makeMountPointLease: { try runner.makeMountPointLease(at: $0) },
                removeMigrationBackup: removeMigrationBackup
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
