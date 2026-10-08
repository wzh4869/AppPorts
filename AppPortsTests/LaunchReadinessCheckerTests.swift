//
//  LaunchReadinessCheckerTests.swift
//  AppPorts
//
//  欢迎屏「启动状态检查」：权限与外部存储格式的判定逻辑。
//

import Foundation
import Darwin
import Testing
@testable import AppPorts

@Suite("Launch readiness check")
struct LaunchReadinessCheckerTests {

    // MARK: 检查项映射

    @Test("三项都满足时全部通过")
    func allSatisfied() {
        let items = LaunchReadinessChecker.items(
            fullDiskAccessState: .granted,
            hasAppManagementPermission: true,
            externalDriveState: .apfs
        )

        #expect(items.map(\.id) == [
            LaunchReadinessChecker.ItemID.fullDiskAccess,
            LaunchReadinessChecker.ItemID.appManagement,
            LaunchReadinessChecker.ItemID.externalDrive
        ])
        #expect(items.allSatisfy { $0.level == .ok })
        #expect(items.allSatisfy { $0.action == nil })
    }

    @Test("缺少完全磁盘访问权限时报失败并给出设置入口")
    func missingFullDiskAccess() throws {
        let items = LaunchReadinessChecker.items(
            fullDiskAccessState: .denied,
            hasAppManagementPermission: true,
            externalDriveState: .apfs
        )

        let item = try #require(items.first { $0.id == LaunchReadinessChecker.ItemID.fullDiskAccess })
        #expect(item.level == .failed)
        #expect(item.action == .fullDiskAccess)
        #expect(item.title == "完全磁盘访问权限".localized)
    }

    @Test("检查不确定时提醒核对，不误报已授权或权限被拒绝")
    func unknownFullDiskAccess() throws {
        let items = LaunchReadinessChecker.items(
            fullDiskAccessState: .unknown,
            hasAppManagementPermission: true,
            externalDriveState: .apfs
        )
        let item = try #require(items.first { $0.id == LaunchReadinessChecker.ItemID.fullDiskAccess })
        #expect(item.level == .warning)
        #expect(item.action == .fullDiskAccess)
    }

    @Test("缺少 App 管理权限时报失败并给出设置入口")
    func missingAppManagement() {
        let items = LaunchReadinessChecker.items(
            fullDiskAccessState: .granted,
            hasAppManagementPermission: false,
            externalDriveState: .apfs
        )

        let item = items.first { $0.id == LaunchReadinessChecker.ItemID.appManagement }
        #expect(item?.level == .failed)
        #expect(item?.action == .appManagement)
    }

    // MARK: 外部存储

    @Test("没选外部存储只是提醒，不拦截")
    func externalDriveNotSelected() {
        let item = driveItem(state: .notSelected)
        #expect(item?.level == .warning)
        #expect(item?.action == nil)
    }

    @Test("外部存储读不到时提示连接后重新检查")
    func externalDriveUnavailable() {
        let item = driveItem(state: .unavailable(path: "/Volumes/Missing"))
        #expect(item?.level == .warning)
        #expect(item?.detail.contains("/Volumes/Missing") == true)
    }

    @Test("APFS 外部存储通过")
    func externalDriveAPFS() {
        let item = driveItem(state: .apfs)
        #expect(item?.level == .ok)
        #expect(item?.action == nil)
    }

    @Test("非 APFS 外部存储说明只影响沙盒应用数据，不把用户引向经典模式")
    func externalDriveNotAPFS() {
        let item = driveItem(state: .notAPFS(filesystem: "ExFAT"))
        #expect(item?.level == .warning)
        // 经典模式会重签沙盒应用，在 macOS 27 上可能让应用打不开，不能作为默认退路推荐。
        #expect(item?.detail == String(
            format: "当前格式：%@。应用和普通数据目录可以照常迁移到这里。只有沙盒应用的数据（如聊天记录）需要 APFS 格式；这部分留在本机也不影响使用，不需要为此改动这块盘。".localized,
            "ExFAT"
        ))
    }

    @Test("加密的 APFS 外部存储提醒沙盒应用数据会留在本机")
    func externalDriveEncryptedAPFS() {
        let item = driveItem(state: .encryptedAPFS)
        #expect(item?.level == .warning)
        #expect(item?.action == nil)
        #expect(item?.detail == "格式为 APFS（已加密）。应用和普通数据目录可以迁移到这里；沙盒应用的数据（如聊天记录）不会迁移到加密的外部存储，会继续留在本机。".localized)
    }

    @Test("读不出文件系统类型时用「未知格式」兜底")
    func externalDriveUnknownFormat() {
        let item = driveItem(state: .notAPFS(filesystem: nil))
        #expect(item?.level == .warning)
        #expect(item?.detail.contains("%@") == false)
    }

    @Test("文件系统类型转成常见写法")
    func filesystemDisplayNames() {
        #expect(LaunchReadinessChecker.filesystemDisplayName("hfs") == "HFS+")
        #expect(LaunchReadinessChecker.filesystemDisplayName("exfat") == "ExFAT")
        #expect(LaunchReadinessChecker.filesystemDisplayName("apfs") == "APFS")
        #expect(LaunchReadinessChecker.filesystemDisplayName("msdos") == "FAT32")
        #expect(LaunchReadinessChecker.filesystemDisplayName("ntfs") == "NTFS")
        #expect(LaunchReadinessChecker.filesystemDisplayName("  ") == nil)
        #expect(LaunchReadinessChecker.filesystemDisplayName(nil) == nil)
    }

    // MARK: 探针装配

    @Test("check() 会用保存的外部路径去查格式")
    func checkUsesSavedPath() async {
        let recorder = PathRecorder()
        let checker = LaunchReadinessChecker(probe: LaunchReadinessChecker.Probe(
            fullDiskAccessState: { .granted },
            hasAppManagementPermission: { true },
            externalDrivePath: { "/Volumes/TestDrive" },
            externalDriveState: { path in
                await recorder.record(path)
                return .notAPFS(filesystem: "exfat")
            }
        ))

        let items = await checker.check()
        let probedPaths = await recorder.paths
        #expect(probedPaths == ["/Volumes/TestDrive"])
        #expect(items.first { $0.id == LaunchReadinessChecker.ItemID.externalDrive }?.level == .warning)
    }

    @Test("没保存外部路径时不调用 diskutil")
    func checkSkipsDiskutilWithoutSavedPath() async {
        let recorder = PathRecorder()
        let checker = LaunchReadinessChecker(probe: LaunchReadinessChecker.Probe(
            fullDiskAccessState: { .granted },
            hasAppManagementPermission: { true },
            externalDrivePath: { nil },
            externalDriveState: { path in
                await recorder.record(path)
                return .apfs
            }
        ))

        let items = await checker.check()
        let probedPaths = await recorder.paths
        #expect(probedPaths.isEmpty)
        #expect(items.first { $0.id == LaunchReadinessChecker.ItemID.externalDrive }?.level == .warning)
    }

    @Test("空字符串的外部路径按「未选择」处理")
    func checkTreatsEmptyPathAsNotSelected() async {
        let checker = LaunchReadinessChecker(probe: LaunchReadinessChecker.Probe(
            fullDiskAccessState: { .granted },
            hasAppManagementPermission: { true },
            externalDrivePath: { "" },
            externalDriveState: { _ in .apfs }
        ))

        let items = await checker.check()
        #expect(items.first { $0.id == LaunchReadinessChecker.ItemID.externalDrive }?.level == .warning)
    }

    // MARK: 外部存储格式探测

    @Test("APFS 卷判定为 .apfs")
    func detectsAPFSVolume() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.cleanup() }
        let fake = FakeDiskCommandRunner(externalFilesystem: "apfs")

        let state = await LaunchReadinessChecker.externalDriveState(
            atPath: workspace.root.path,
            disk: DiskUtility(runner: fake)
        )
        #expect(state == .apfs)
    }

    @Test("加密的 APFS 卷判定为 .encryptedAPFS")
    func detectsEncryptedAPFSVolume() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.cleanup() }
        let fake = FakeDiskCommandRunner(externalFilesystem: "apfs", externalEncrypted: true)

        let state = await LaunchReadinessChecker.externalDriveState(
            atPath: workspace.root.path,
            disk: DiskUtility(runner: fake)
        )
        #expect(state == .encryptedAPFS)
    }

    @Test("非 APFS 卷带回实际格式")
    func detectsNonAPFSVolume() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.cleanup() }
        let fake = FakeDiskCommandRunner(externalFilesystem: "exfat")

        let state = await LaunchReadinessChecker.externalDriveState(
            atPath: workspace.root.path,
            disk: DiskUtility(runner: fake)
        )
        #expect(state == .notAPFS(filesystem: "exfat"))
    }

    @Test("路径不存在时判定为不可用，不问 diskutil")
    func missingPathIsUnavailable() async {
        let fake = FakeDiskCommandRunner()

        let state = await LaunchReadinessChecker.externalDriveState(
            atPath: "/Volumes/AppPorts-Not-Connected",
            disk: DiskUtility(runner: fake)
        )
        #expect(state == .unavailable(path: "/Volumes/AppPorts-Not-Connected"))
        #expect(fake.calls.isEmpty)
    }

    // MARK: 完全磁盘访问权限探针

    @Test("能打开受保护文件时判定为已授权")
    func fullDiskAccessProbeReadsFile() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.cleanup() }
        let readable = workspace.root.appendingPathComponent("readable.db")
        try Data("x".utf8).write(to: readable)

        #expect(LaunchReadinessChecker.fullDiskAccessState(candidatePaths: [readable.path]) == .granted)
    }

    @Test("打不开受保护文件时判定为未授权")
    func fullDiskAccessProbeRejectsUnreadableFile() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.cleanup() }
        let unreadable = workspace.root.appendingPathComponent("unreadable.db")
        try Data("x".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        #expect(LaunchReadinessChecker.fullDiskAccessState(candidatePaths: [unreadable.path]) == .denied)
    }

    @Test("候选文件都不存在时不能断言未授权")
    func fullDiskAccessProbeWithoutCandidates() {
        let missing = "/tmp/appports-missing-\(UUID().uuidString)/TCC.db"
        #expect(LaunchReadinessChecker.fullDiskAccessState(candidatePaths: [missing]) == .unknown)
    }

    @Test("默认候选路径覆盖用户与系统 TCC 数据库")
    func defaultProbePaths() {
        let paths = LaunchReadinessChecker.fullDiskAccessProbePaths(homeDirectory: "/Users/example")
        #expect(paths.contains("/Users/example/Library/Application Support/com.apple.TCC/TCC.db"))
        #expect(!paths.contains("/Users/example/Library/Messages/chat.db"))
        #expect(paths.contains("/Library/Application Support/com.apple.TCC/TCC.db"))
    }

    @Test("直接检查打开结果，正确区分权限拒绝和无法确认", arguments: [
        (EPERM, LaunchReadinessChecker.FullDiskAccessState.denied),
        (EACCES, .denied),
        (ENOENT, .unknown),
        (EIO, .unknown)
    ])
    func protectedFileErrors(error: Int32, expected: LaunchReadinessChecker.FullDiskAccessState) {
        // 路径无需真的存在；不能用 fileExists 把拒绝访问误认为缺少检查文件。
        let state = LaunchReadinessChecker.fullDiskAccessState(
            candidatePaths: ["/unavailable/TCC.db"], openProbe: { _ in error }
        )
        #expect(state == expected)
    }

    @Test("一个候选文件可打开即可通过，全部失败时保留权限拒绝")
    func multipleProbeCandidates() {
        let results: [String: Int32] = ["missing": ENOENT, "denied": EPERM, "readable": 0]
        #expect(LaunchReadinessChecker.fullDiskAccessState(
            candidatePaths: ["missing", "denied", "readable"], openProbe: { results[$0]! }
        ) == .granted)
        #expect(LaunchReadinessChecker.fullDiskAccessState(
            candidatePaths: ["missing", "denied"], openProbe: { results[$0]! }
        ) == .denied)
    }

    @Test("重新检查会重新打开文件，不复用之前的授权结果")
    func accessProbeIsNotCached() {
        let path = "/probe/\(UUID().uuidString)/TCC.db"
        #expect(LaunchReadinessChecker.fullDiskAccessState(candidatePaths: [path], openProbe: { _ in EPERM }) == .denied)
        #expect(LaunchReadinessChecker.fullDiskAccessState(candidatePaths: [path], openProbe: { _ in 0 }) == .granted)
        #expect(LaunchReadinessChecker.fullDiskAccessState(candidatePaths: [path], openProbe: { _ in EACCES }) == .denied)
    }

    @Test("目录或指向普通文件的链接不能冒充受保护数据库")
    func invalidProbeTargets() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.cleanup() }
        let file = workspace.root.appendingPathComponent("readable.db")
        let link = workspace.root.appendingPathComponent("TCC.db")
        try Data("x".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(LaunchReadinessChecker.fullDiskAccessState(candidatePaths: [workspace.root.path]) == .unknown)
        #expect(LaunchReadinessChecker.fullDiskAccessState(candidatePaths: [link.path]) == .unknown)
    }

    @Test("同名同版本的不同构建保留各自的应用路径与构建号")
    func runningApplicationIdentity() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.cleanup() }
        var identities: [LaunchReadinessChecker.RunningApplication] = []
        for (directory, build) in [("Installed", "20"), ("Preview", "21")] {
            let url = workspace.root.appendingPathComponent(directory).appendingPathComponent("AppPorts.app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "test.AppPorts", "CFBundlePackageType": "APPL",
                        "CFBundleShortVersionString": "1.9.0", "CFBundleVersion": build]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let bundle = try #require(Bundle(url: url))
            let identity = LaunchReadinessChecker.RunningApplication(bundle: bundle)
            #expect(identity.url == url.resolvingSymlinksInPath().standardizedFileURL)
            #expect(identity.version == "1.9.0")
            #expect(identity.build == build)
            identities.append(identity)
        }
        #expect(identities[0] != identities[1])
        #expect(LaunchReadinessChecker.RunningApplication().url == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL)
    }

    // MARK: 系统设置入口

    @Test("检查项自带对应系统设置面板")
    func settingsURLs() {
        #expect(LaunchReadinessChecker.Item.Action.fullDiskAccess.settingsURLs.count == 1)
        #expect(LaunchReadinessChecker.Item.Action.fullDiskAccess.settingsURLs[0].absoluteString.contains("Privacy_AllFiles"))

        let appManagement = LaunchReadinessChecker.Item.Action.appManagement.settingsURLs
        #expect(appManagement.count == 2)
        #expect(appManagement[0].absoluteString.contains("Privacy_AppManagement"))
    }

    // MARK: 辅助

    private func driveItem(state: LaunchReadinessChecker.ExternalDriveState) -> LaunchReadinessChecker.Item? {
        LaunchReadinessChecker.items(
            fullDiskAccessState: .granted,
            hasAppManagementPermission: true,
            externalDriveState: state
        ).first { $0.id == LaunchReadinessChecker.ItemID.externalDrive }
    }

    private actor PathRecorder {
        private(set) var paths: [String] = []

        func record(_ path: String) {
            paths.append(path)
        }
    }

    private struct TemporaryWorkspace {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("appports-readiness-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
