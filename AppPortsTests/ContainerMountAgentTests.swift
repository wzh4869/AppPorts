import XCTest
import Testing
@testable import AppPorts

/// 登录代理的 LaunchAgent 定义。
///
/// 这里守的是一个实测过的时序问题：只靠 `RunAtLoad`，代理要等到登录后约
/// 55 秒才跑，而登录项里的微信在登录后约 43 秒就被拉起，挂载永远慢一步
/// —— 表现就是「开机后打开微信，聊天记录不见了」。
/// `WatchPaths` 让代理在系统把外置卷挂上 `/Volumes` 时立刻再跑一次，实测能提前约 20 秒。
final class ContainerMountAgentTests: XCTestCase {

    func testDisabledAgentIsEnabledBeforeRegistrationAndVerifiedAfterwards() throws {
        var commands: [String] = []
        var enabled = false
        var registered = false
        let changed = try ContainerMountAgentInstaller.configureAgent(definitionMatches: true, writeDefinition: {
            commands.append("write")
        }, run: { arguments in
            let command = arguments[0]
            commands.append(command)
            switch command {
            case "enable": enabled = true; return 0
            case "print": return registered ? 0 : 113
            case "bootstrap": registered = enabled; return registered ? 0 : 5
            default: return 0
            }
        })
        XCTAssertTrue(changed)
        XCTAssertEqual(commands, ["enable", "print", "bootout", "write", "bootstrap", "print"])
    }

    func testUnchangedRegisteredAgentDoesNotRestart() throws {
        var commands: [String] = []
        let changed = try ContainerMountAgentInstaller.configureAgent(definitionMatches: true,
            writeDefinition: { XCTFail("An unchanged registered agent must not be rewritten") },
            run: { commands.append($0[0]); return 0 })
        XCTAssertFalse(changed)
        XCTAssertEqual(commands, ["enable", "print"])
    }

    func testEnableFailurePreservesExistingRegistrationAndDefinition() {
        var commands: [String] = []
        XCTAssertThrowsError(try ContainerMountAgentInstaller.configureAgent(definitionMatches: false,
            writeDefinition: { XCTFail("Enable failure must leave the definition alone") },
            run: { commands.append($0[0]); return 5 }))
        XCTAssertEqual(commands, ["enable"])
    }

    func testLegacyLoadSuccessWithoutRegistrationIsNotReportedAsInstalled() {
        var commands: [String] = []
        XCTAssertThrowsError(try ContainerMountAgentInstaller.configureAgent(definitionMatches: false,
            writeDefinition: { commands.append("write") }, run: {
                commands.append($0[0])
                return ["bootstrap", "print"].contains($0[0]) ? 5 : 0
            }))
        XCTAssertEqual(commands, ["enable", "bootout", "write", "bootstrap", "load", "print"])
    }

    func testLegacyAgentIsAssociatedWithAppPortsInSystemSettings() {
        let payload = ContainerMountAgentInstaller.launchAgentPayload(executablePath: "/Applications/AppPorts.app/Contents/MacOS/AppPorts")
        XCTAssertEqual(payload["AssociatedBundleIdentifiers"] as? [String], ["com.shimoko.AppPorts"])
    }

    func testReplacingSignedAppAtSamePathRefreshesAgentRegistration() throws {
        let path = "/Applications/AppPorts.app/Contents/MacOS/AppPorts"
        let old = ContainerMountAgentInstaller.launchAgentPayload(executablePath: path, signatureIdentity: "old-cdhash")
        let updated = ContainerMountAgentInstaller.launchAgentPayload(executablePath: path, signatureIdentity: "new-cdhash")
        XCTAssertNotEqual(try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0),
                          try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0))
        XCTAssertEqual(old["ProgramArguments"] as? [String], updated["ProgramArguments"] as? [String])
        XCTAssertEqual(old["WatchPaths"] as? [String], updated["WatchPaths"] as? [String])
    }

    func testLaunchAgentWatchesVolumesSoItRunsBeforeSelfStartingApps() {
        let payload = ContainerMountAgentInstaller.launchAgentPayload(
            executablePath: "/Applications/AppPorts.app/Contents/MacOS/AppPorts"
        )

        XCTAssertEqual(
            payload["WatchPaths"] as? [String], ["/Volumes"],
            "缺少 /Volumes 监听，代理会晚于登录项里的微信启动，开机后微信读不到数据"
        )
        XCTAssertEqual(payload["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(payload["Label"] as? String, ContainerMountAgentInstaller.label)
        XCTAssertEqual(payload["LimitLoadToSessionType"] as? [String], ["Aqua"])
    }

    /// 登录项里的应用约 3 秒就被拉起，而纯 `RunAtLoad` 的传统代理要等 20 秒（实测）。
    /// `KeepAlive.SuccessfulExit=false` 让任务始终算"需要运行"，从而不再被 on-demand-only 排队。
    func testLaunchAgentIsNeededAtLoginInsteadOfWaitingInTheOnDemandQueue() {
        let payload = ContainerMountAgentInstaller.launchAgentPayload(executablePath: "/tmp/AppPorts")

        XCTAssertEqual(
            payload["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false],
            "少了 KeepAlive 会被 launchd 排在登录项之后 20 秒，开机立刻打开应用仍可能读到空目录"
        )
        XCTAssertNil(
            payload["ProcessType"],
            "ProcessType=Background 等于告诉 launchd 这个任务不急，会让它被推迟到登录之后"
        )
    }

    func testLaunchAgentRunsTheAppBinaryInAgentMode() {
        let executablePath = "/Applications/AppPorts.app/Contents/MacOS/AppPorts"
        let payload = ContainerMountAgentInstaller.launchAgentPayload(executablePath: executablePath)

        XCTAssertEqual(
            payload["ProgramArguments"] as? [String],
            [executablePath, ContainerMountAgentInstaller.launchArgument]
        )
    }

    func testLaunchAgentPayloadIsSerializableToAPlist() throws {
        let payload = ContainerMountAgentInstaller.launchAgentPayload(executablePath: "/tmp/AppPorts")
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let restored = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]

        XCTAssertEqual(restored?["WatchPaths"] as? [String], ["/Volumes"])
    }

    /// `WatchPaths` 在 launchd 里是按 FSEvents 路径前缀匹配的（`stream = com.apple.fsevents.matching`，
    /// 见 `launchctl print`），所以外置盘上任何一次写入都会把代理叫起来，绝大多数是空跑。
    /// 空跑必须只留一行：实测重启后 5 分钟被叫起来 4 次，每次都逐条写详单的话一天能刷掉近 1 MB。
    func testAgentLogsOneLinePerNoOpRunInsteadOfPerRecordDetail() throws {
        let root = try repositoryRootURL()
        let source = try String(
            contentsOf: root.appendingPathComponent("AppPorts/Services/ContainerMountAgentInstaller.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("outcomes.allSatisfy({ $0.state == .alreadyMounted })"),
            "空跑（所有挂载点都已在位）没有单独分支，会被逐条写进日志"
        )
        XCTAssertTrue(
            source.contains("个挂载点都已在位，无操作"),
            "空跑时缺少那一行汇总日志"
        )
        XCTAssertTrue(
            source.contains(#"AppLogger.shared.log("容器卷自动挂载代理启动")"#),
            "启动行是开机时序自查脚本的判定依据，必须始终留下一行"
        )
    }

    // MARK: - 代理运行哪一份 AppPorts

    private let home = URL(fileURLWithPath: "/Users/tester")
    private let installed = "/Applications/AppPorts.app/Contents/MacOS/AppPorts"
    private let desktopBuild = "/Users/tester/Desktop/test/AppPorts.app/Contents/MacOS/AppPorts"
    private let derivedDataBuild = "/tmp/AppPortsDerived/Build/Products/Debug/AppPorts.app/Contents/MacOS/AppPorts"
    private let translocated = "/private/var/folders/xy/abc/T/AppTranslocation/0F1E2D3C/d/AppPorts.app/Contents/MacOS/AppPorts"

    private func choose(running: String, recorded: String?, existing: Set<String>) -> String? {
        ContainerMountAgentInstaller.agentExecutablePath(
            running: URL(fileURLWithPath: running),
            recorded: recorded,
            fileExists: { existing.contains($0) },
            homeDirectory: home,
            resolveSymlinks: { $0 }
        )
    }

    /// 首次安装：没有记录，就用当前这份仍可执行的稳定安装。
    func testAgentUsesRunningCopyOnFirstInstall() {
        XCTAssertEqual(choose(running: installed, recorded: nil, existing: [installed]), installed)
    }

    /// 从 Xcode 或临时目录跑的调试构建不能把代理抢走：记录的那份还在就保留。
    func testAgentKeepsRecordedCopyWhileADevelopmentBuildRuns() {
        XCTAssertEqual(
            choose(running: derivedDataBuild, recorded: desktopBuild, existing: [derivedDataBuild, desktopBuild]),
            desktopBuild
        )
    }

    /// 记录的那份被移动或删除了：可改用当前稳定安装，不能改用随时会被清理的构建输出。
    func testAgentFollowsTheAppWhenTheRecordedCopyIsGone() {
        XCTAssertEqual(choose(running: installed, recorded: desktopBuild, existing: [installed]), installed)
        XCTAssertNil(
            choose(running: derivedDataBuild, recorded: desktopBuild, existing: [derivedDataBuild]),
            "旧记录失效时必须提示安装，不能把 DerivedData 构建持久化到登录代理"
        )
    }

    /// 用户把正式版装进「应用程序」后打开：代理改指向它，不再用桌面上的测试包。
    func testAgentPrefersTheCopyInstalledInApplications() {
        XCTAssertEqual(choose(running: installed, recorded: desktopBuild, existing: [installed, desktopBuild]), installed)
        let userApplications = "/Users/tester/Applications/AppPorts.app/Contents/MacOS/AppPorts"
        XCTAssertEqual(
            choose(running: userApplications, recorded: desktopBuild, existing: [userApplications, desktopBuild]),
            userApplications
        )
        // 两份都在「应用程序」里时保持原样，不来回切换。
        XCTAssertEqual(choose(running: userApplications, recorded: installed, existing: [userApplications, installed]), installed)
    }

    /// 从下载文件夹或安装包里直接打开的临时转移路径，退出即消失，绝不能写进代理。
    func testAgentNeverPointsAtATranslocatedCopy() {
        XCTAssertTrue(ContainerMountAgentInstaller.isTranslocated(URL(fileURLWithPath: translocated)))
        XCTAssertFalse(ContainerMountAgentInstaller.isTranslocated(URL(fileURLWithPath: installed)))
        XCTAssertEqual(choose(running: translocated, recorded: installed, existing: [translocated, installed]), installed)
        XCTAssertNil(choose(running: translocated, recorded: nil, existing: [translocated]))
        XCTAssertNil(choose(running: translocated, recorded: desktopBuild, existing: [translocated]))
    }

    func testRecordedExecutableIsReadBackFromTheInstalledDefinition() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ContainerMountAgentInstaller.launchAgentPayload(executablePath: desktopBuild),
            format: .xml,
            options: 0
        )
        XCTAssertEqual(ContainerMountAgentInstaller.recordedExecutablePath(inAgentPlist: data), desktopBuild)
        XCTAssertNil(ContainerMountAgentInstaller.recordedExecutablePath(inAgentPlist: Data("not a plist".utf8)))
    }

    /// 旧版可能已把临时路径写进代理；即使它暂时仍可执行，也不能继续沿用。
    func testAgentReplacesAnExistingTranslocatedRecordWithTheRunningStableCopy() {
        XCTAssertEqual(
            choose(running: installed, recorded: translocated, existing: [installed, translocated]),
            installed
        )
        XCTAssertEqual(
            choose(running: desktopBuild, recorded: translocated, existing: [desktopBuild, translocated]),
            desktopBuild
        )
    }

    func testAgentRejectsTranslocatedRecordsEvenWhenTheyStillExist() {
        XCTAssertNil(choose(running: translocated, recorded: translocated, existing: [translocated]))
        let otherTranslocated = translocated.replacingOccurrences(of: "0F1E2D3C", with: "ANOTHER-UUID")
        XCTAssertNil(
            choose(running: translocated, recorded: otherTranslocated, existing: [translocated, otherTranslocated])
        )
    }

    private func repositoryRootURL() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@Suite("Container mount agent executable paths")
struct ContainerMountAgentExecutablePathTests {
    private static let installed = "/Applications/AppPorts.app/Contents/MacOS/AppPorts"
    private static let stableRecorded = "/Users/tester/Applications/AppPorts.app/Contents/MacOS/AppPorts"

    // 同一组路径要分别验证首次安装、保留记录、替换记录和记录失效后的回退。
    private static let temporaryExecutables = [
        "/tmp/AppPorts.app/Contents/MacOS/AppPorts",
        "/private/tmp/AppPorts.app/Contents/MacOS/AppPorts",
        "/var/tmp/AppPorts.app/Contents/MacOS/AppPorts",
        "/private/var/tmp/AppPorts.app/Contents/MacOS/AppPorts",
        "/var/folders/xy/cache/T/AppPorts.app/Contents/MacOS/AppPorts",
        "/private/var/folders/xy/cache/T/AppPorts.app/Contents/MacOS/AppPorts",
        "/Volumes/Staging/AppTranslocation/UUID/d/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Library/Developer/Xcode/DerivedData/AppPorts-abc/Build/Products/Debug/AppPorts.app/Contents/MacOS/AppPorts",
        "/Volumes/Development/DerivedData/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Developer/AppPorts/Build/Products/Release/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Developer/AppPorts/build/Debug/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Developer/AppPorts/build/Release/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Developer/AppPorts/build/Debug-macosx/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Developer/AppPorts/build/Release-macosx/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Developer/AppPorts/.build/arm64-apple-macosx/debug/AppPorts",
        "/Applications/../tmp/AppPorts.app/Contents/MacOS/AppPorts"
    ]

    @Test(arguments: ContainerMountAgentExecutablePathTests.temporaryExecutables)
    func temporaryExecutablesCannotBecomeTheFirstAgentPath(_ path: String) {
        #expect(ContainerMountAgentInstaller.isTemporaryLocation(URL(fileURLWithPath: path), resolveSymlinks: { $0 }))
        #expect(ContainerMountAgentInstaller.agentExecutablePath(
            running: URL(fileURLWithPath: path),
            recorded: nil,
            fileExists: { _ in true },
            resolveSymlinks: { $0 }
        ) == nil)
    }

    @Test(arguments: ContainerMountAgentExecutablePathTests.temporaryExecutables)
    func temporaryRunningCopyKeepsAStableRecordedExecutable(_ path: String) {
        #expect(choose(running: path, recorded: Self.stableRecorded, existing: [path, Self.stableRecorded])
            == Self.stableRecorded)
    }

    @Test(arguments: ContainerMountAgentExecutablePathTests.temporaryExecutables)
    func stableRunningCopyReplacesATemporaryRecord(_ path: String) {
        #expect(choose(running: Self.installed, recorded: path, existing: [Self.installed, path])
            == Self.installed)
    }

    @Test(arguments: ContainerMountAgentExecutablePathTests.temporaryExecutables)
    func missingRunningCopyCannotFallBackToATemporaryRecord(_ path: String) {
        #expect(choose(running: Self.installed, recorded: path, existing: [path]) == nil)
    }

    @Test(arguments: [
        "/Applications/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Applications/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Desktop/AppPorts.app/Contents/MacOS/AppPorts",
        "/Volumes/External/Applications/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Apps/build-tools/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Apps/DerivedData Viewer/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/Apps/Build/Programs/AppPorts.app/Contents/MacOS/AppPorts",
        "/Users/tester/tmp/AppPorts.app/Contents/MacOS/AppPorts",
        "/tmp-backup/AppPorts.app/Contents/MacOS/AppPorts"
    ])
    func stableInstallationsAndSimilarDirectoryNamesRemainUsable(_ path: String) {
        #expect(!ContainerMountAgentInstaller.isTemporaryLocation(URL(fileURLWithPath: path), resolveSymlinks: { $0 }))
        #expect(choose(running: path, recorded: nil, existing: [path]) == path)
    }

    @Test(arguments: [
        ("/Applications/AppPorts.app/Contents/MacOS/AppPorts", "/tmp/AppPorts.app/Contents/MacOS/AppPorts"),
        ("/Applications/AppPorts.app/Contents/MacOS/AppPorts", "/Users/tester/Build/Products/Debug/AppPorts.app/Contents/MacOS/AppPorts"),
        ("/tmp/AppPorts.app/Contents/MacOS/AppPorts", "/Applications/AppPorts.app/Contents/MacOS/AppPorts")
    ])
    func aSymlinkCannotHideATemporaryLocation(_ path: String, resolved: String) {
        #expect(ContainerMountAgentInstaller.isTemporaryLocation(
            URL(fileURLWithPath: path),
            resolveSymlinks: { _ in URL(fileURLWithPath: resolved) }
        ))
        #expect(ContainerMountAgentInstaller.agentExecutablePath(
            running: URL(fileURLWithPath: path),
            recorded: nil,
            fileExists: { _ in true },
            resolveSymlinks: { _ in URL(fileURLWithPath: resolved) }
        ) == nil)
    }

    @Test
    func aRecordedSymlinkToATemporaryBuildIsReplaced() {
        #expect(ContainerMountAgentInstaller.agentExecutablePath(
            running: URL(fileURLWithPath: Self.stableRecorded),
            recorded: Self.installed,
            fileExists: { _ in true },
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            resolveSymlinks: { url in
                url.path == Self.installed ? URL(fileURLWithPath: "/tmp/AppPorts.app/Contents/MacOS/AppPorts") : url
            }
        ) == Self.stableRecorded)
    }

    @Test
    func anUnavailableRunningExecutableIsNotPersisted() {
        #expect(choose(running: Self.installed, recorded: nil, existing: []) == nil)
        #expect(choose(running: Self.installed, recorded: Self.stableRecorded, existing: [Self.stableRecorded])
            == Self.stableRecorded)
    }

    @Test(arguments: ["", "Applications/AppPorts.app/Contents/MacOS/AppPorts", "../AppPorts.app/Contents/MacOS/AppPorts"])
    func relativeRecordedPathsAreNotStableFallbacks(_ path: String) {
        #expect(ContainerMountAgentInstaller.agentExecutablePath(
            running: URL(fileURLWithPath: "/tmp/AppPorts.app/Contents/MacOS/AppPorts"),
            recorded: path,
            fileExists: { _ in true },
            resolveSymlinks: { $0 }
        ) == nil)
    }

    private func choose(running: String, recorded: String?, existing: Set<String>) -> String? {
        let normalizedExisting = Set(existing.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return ContainerMountAgentInstaller.agentExecutablePath(
            running: URL(fileURLWithPath: running),
            recorded: recorded,
            fileExists: { normalizedExisting.contains($0) },
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            resolveSymlinks: { $0 }
        )
    }
}
