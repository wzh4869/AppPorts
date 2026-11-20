//
//  LegacyPermissionResetterTests.swift
//  AppPortsTests
//
//  证书变更后旧版 TCC 权限记录自动清理与手动兜底清理的单元测试。
//

import Foundation
import Testing
@testable import AppPorts

@Suite("Legacy permission resetter")
struct LegacyPermissionResetterTests {

    private final class InMemoryStore: @unchecked Sendable {
        private let lock = NSLock()
        var handledIdentity: String?
        var pendingPrompt: LegacyPermissionResetter.ResetPrompt?

        var store: LegacyPermissionResetter.Store {
            LegacyPermissionResetter.Store(
                readHandledIdentity: { self.withLock { self.handledIdentity } },
                writeHandledIdentity: { value in self.withLock { self.handledIdentity = value } },
                readPendingPrompt: { self.withLock { self.pendingPrompt } },
                writePendingPrompt: { value in self.withLock { self.pendingPrompt = value } }
            )
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        var nonPrivilegedCalls: [([String], String, URL?)] = []
        var administratorCalls: [(String, String)] = []

        func recordNonPrivileged(_ services: [String], _ bundleID: String, _ url: URL?) {
            lock.lock()
            defer { lock.unlock() }
            nonPrivilegedCalls.append((services, bundleID, url))
        }

        func recordAdministrator(_ service: String, _ bundleID: String) {
            lock.lock()
            defer { lock.unlock() }
            administratorCalls.append((service, bundleID))
        }
    }

    private func makeResetter(
        hasCompletedWelcome: Bool = true,
        isAllowedLocation: Bool = true,
        bundleIdentifier: String? = LegacyPermissionResetter.expectedBundleIdentifier,
        bundleURL: URL = URL(fileURLWithPath: "/Applications/AppPorts.app"),
        signingIdentity: String? = "cert:new-cert-sha256",
        fullDiskAccessState: LaunchReadinessChecker.FullDiskAccessState = .granted,
        appManagementState: AppManagementPermission.State = .granted,
        nonPrivilegedResults: [String: Bool] = [
            "SystemPolicyAppBundles": true,
            "SystemPolicyAllFiles": true
        ],
        administratorResult: Result<Bool, Error> = .success(true),
        store: InMemoryStore = InMemoryStore(),
        recorder: CallRecorder = CallRecorder()
    ) -> LegacyPermissionResetter {
        LegacyPermissionResetter(dependencies: .init(
            hasCompletedWelcome: { hasCompletedWelcome },
            isAllowedLocation: { isAllowedLocation },
            bundleIdentifier: { bundleIdentifier },
            bundleURL: { bundleURL },
            signingIdentity: { signingIdentity },
            fullDiskAccessState: { fullDiskAccessState },
            appManagementState: { appManagementState },
            resetTCC: { services, bundleID, relaunchURL in
                recorder.recordNonPrivileged(services, bundleID, relaunchURL)
                return Dictionary(uniqueKeysWithValues: services.map { ($0, nonPrivilegedResults[$0] ?? false) })
            },
            resetTCCWithAdministrator: { service, bundleID in
                recorder.recordAdministrator(service, bundleID)
                return try administratorResult.get()
            },
            store: store.store
        ))
    }

    // MARK: - 启动触发边界

    @Test("全新用户未完成欢迎引导时不自动重置也不弹窗")
    func skipsBrandNewUsers() async {
        let store = InMemoryStore()
        let recorder = CallRecorder()
        let resetter = makeResetter(
            hasCompletedWelcome: false,
            fullDiskAccessState: .denied,
            appManagementState: .denied,
            store: store,
            recorder: recorder
        )

        let prompt = await resetter.evaluateAndResetOnLaunchIfNeeded()
        #expect(prompt == nil)
        #expect(recorder.nonPrivilegedCalls.isEmpty)
        #expect(store.handledIdentity == nil)
    }

    @Test("应用不在应用程序目录或 Bundle ID 不匹配时不自动重置")
    func skipsDisallowedLocationOrWrongBundleID() async {
        let recorder = CallRecorder()
        let wrongLocation = makeResetter(
            isAllowedLocation: false,
            appManagementState: .denied,
            recorder: recorder
        )
        #expect(await wrongLocation.evaluateAndResetOnLaunchIfNeeded() == nil)

        let wrongBundle = makeResetter(
            bundleIdentifier: "com.example.Other",
            appManagementState: .denied,
            recorder: recorder
        )
        #expect(await wrongBundle.evaluateAndResetOnLaunchIfNeeded() == nil)

        let unsigned = makeResetter(
            signingIdentity: nil,
            appManagementState: .denied,
            recorder: recorder
        )
        #expect(await unsigned.evaluateAndResetOnLaunchIfNeeded() == nil)
        #expect(recorder.nonPrivilegedCalls.isEmpty)
    }

    @Test("两项权限均已就绪时仅静默记录签名指纹，不调用 tccutil 也不弹窗")
    func recordsIdentitySilentlyWhenAllPermissionsGranted() async {
        let store = InMemoryStore()
        let recorder = CallRecorder()
        let resetter = makeResetter(
            signingIdentity: "cert:abc",
            fullDiskAccessState: .granted,
            appManagementState: .granted,
            store: store,
            recorder: recorder
        )

        let prompt = await resetter.evaluateAndResetOnLaunchIfNeeded()
        #expect(prompt == nil)
        #expect(store.handledIdentity == "cert:abc")
        #expect(store.pendingPrompt == nil)
        #expect(recorder.nonPrivilegedCalls.isEmpty)
        #expect(recorder.administratorCalls.isEmpty)
    }

    // MARK: - 按需精准重置

    @Test("仅 App 管理缺失时只重置 SystemPolicyAppBundles，绝不动已授权的 FDA",
          arguments: [AppManagementPermission.State.denied, .unknown])
    func resetsOnlyAppManagementWhenFDAIsGranted(state: AppManagementPermission.State) async throws {
        let store = InMemoryStore()
        let recorder = CallRecorder()
        let resetter = makeResetter(
            signingIdentity: "cert:230",
            fullDiskAccessState: .granted,
            appManagementState: state,
            store: store,
            recorder: recorder
        )

        let prompt = try #require(await resetter.evaluateAndResetOnLaunchIfNeeded())
        #expect(prompt.permissions == [.appManagement])
        #expect(prompt.resetSucceeded == [.appManagement])
        #expect(prompt.signingIdentity == "cert:230")
        #expect(store.handledIdentity == "cert:230")
        #expect(store.pendingPrompt == nil)
        #expect(recorder.nonPrivilegedCalls.count == 1)
        #expect(recorder.nonPrivilegedCalls[0].0 == ["SystemPolicyAppBundles"])
        #expect(recorder.nonPrivilegedCalls[0].1 == LegacyPermissionResetter.expectedBundleIdentifier)
        #expect(recorder.administratorCalls.isEmpty)
    }

    @Test("仅完全磁盘访问被拒绝时只免提权重置 SystemPolicyAllFiles，绝不弹管理员授权")
    func resetsOnlyFullDiskAccessNonPrivilegedOnLaunch() async throws {
        let store = InMemoryStore()
        let recorder = CallRecorder()
        let resetter = makeResetter(
            signingIdentity: "cert:230",
            fullDiskAccessState: .denied,
            appManagementState: .granted,
            store: store,
            recorder: recorder
        )

        let prompt = try #require(await resetter.evaluateAndResetOnLaunchIfNeeded())
        #expect(prompt.permissions == [.fullDiskAccess])
        #expect(recorder.nonPrivilegedCalls.count == 1)
        #expect(recorder.nonPrivilegedCalls[0].0 == ["SystemPolicyAllFiles"])
        #expect(recorder.administratorCalls.isEmpty)
    }

    @Test("完全磁盘访问状态为 unknown 时不误判为需重置")
    func doesNotResetOnUnknownFullDiskAccess() async {
        let store = InMemoryStore()
        let recorder = CallRecorder()
        let resetter = makeResetter(
            fullDiskAccessState: .unknown,
            appManagementState: .granted,
            store: store,
            recorder: recorder
        )

        let prompt = await resetter.evaluateAndResetOnLaunchIfNeeded()
        #expect(prompt == nil)
        #expect(recorder.nonPrivilegedCalls.isEmpty)
        #expect(store.handledIdentity == "cert:new-cert-sha256")
    }

    @Test("两项均失效时一次重置两项并返回完整列表")
    func resetsBothWhenBothMissing() async throws {
        let store = InMemoryStore()
        let recorder = CallRecorder()
        let resetter = makeResetter(
            fullDiskAccessState: .denied,
            appManagementState: .denied,
            store: store,
            recorder: recorder
        )

        let prompt = try #require(await resetter.evaluateAndResetOnLaunchIfNeeded())
        #expect(prompt.permissions == [.appManagement, .fullDiskAccess])
        #expect(prompt.resetSucceeded == [.appManagement, .fullDiskAccess])
        #expect(recorder.nonPrivilegedCalls.count == 1)
        #expect(recorder.nonPrivilegedCalls[0].0 == ["SystemPolicyAppBundles", "SystemPolicyAllFiles"])
        #expect(recorder.administratorCalls.isEmpty)
    }

    // MARK: - 幂等与续签

    @Test("同一签名指纹仅自动清理一次；未来证书再次更新时会重新触发一次")
    func runsOncePerSigningIdentityAndRetriggersOnRenewal() async {
        let store = InMemoryStore()
        let recorder = CallRecorder()
        let first = makeResetter(
            signingIdentity: "cert:2026",
            appManagementState: .denied,
            store: store,
            recorder: recorder
        )

        #expect(await first.evaluateAndResetOnLaunchIfNeeded() != nil)
        #expect(await first.evaluateAndResetOnLaunchIfNeeded() == nil)
        #expect(recorder.nonPrivilegedCalls.count == 1)

        let renewed = makeResetter(
            signingIdentity: "cert:2027",
            appManagementState: .denied,
            store: store,
            recorder: recorder
        )
        let secondPrompt = await renewed.evaluateAndResetOnLaunchIfNeeded()
        #expect(secondPrompt?.signingIdentity == "cert:2027")
        #expect(recorder.nonPrivilegedCalls.count == 2)
    }

    // MARK: - SIGKILL 重启承接

    @Test("若上次重置期间进程被终止并重拉起，启动后承接待展示提示且不重复执行 tccutil")
    func resumesPendingPromptAfterRelaunchWithoutRerunningReset() async throws {
        let store = InMemoryStore()
        store.handledIdentity = "cert:230"
        store.pendingPrompt = .init(
            permissions: [.appManagement, .fullDiskAccess],
            resetSucceeded: [.appManagement, .fullDiskAccess],
            signingIdentity: "cert:230"
        )
        let recorder = CallRecorder()
        let resetter = makeResetter(
            signingIdentity: "cert:230",
            fullDiskAccessState: .granted,
            appManagementState: .denied,
            store: store,
            recorder: recorder
        )

        let prompt = try #require(await resetter.evaluateAndResetOnLaunchIfNeeded())
        #expect(prompt.permissions == [.appManagement])
        #expect(prompt.resetSucceeded == [.appManagement])
        #expect(store.pendingPrompt == nil)
        #expect(recorder.nonPrivilegedCalls.isEmpty)
    }

    @Test("重启承接时若权限已全部就绪则静默清除待展示提示")
    func dropsPendingPromptWhenPermissionsAlreadyRestored() async {
        let store = InMemoryStore()
        store.pendingPrompt = .init(
            permissions: [.appManagement],
            resetSucceeded: [.appManagement],
            signingIdentity: "cert:230"
        )
        let resetter = makeResetter(
            fullDiskAccessState: .granted,
            appManagementState: .granted,
            store: store
        )

        #expect(await resetter.evaluateAndResetOnLaunchIfNeeded() == nil)
        #expect(store.pendingPrompt == nil)
    }

    // MARK: - 手动兜底清理

    @Test("手动清理对 App 管理免提权、对系统域完全磁盘访问权限走管理员提权")
    func manualResetUsesNonPrivilegedForAppManagementAndAdminForFDA() async throws {
        let store = InMemoryStore()
        let recorder = CallRecorder()
        let resetter = makeResetter(store: store, recorder: recorder)

        let outcome = try await resetter.resetManually(permissions: [.fullDiskAccess, .appManagement])
        #expect(outcome.attempted == [.appManagement, .fullDiskAccess])
        #expect(outcome.succeeded == [.appManagement, .fullDiskAccess])
        #expect(outcome.failed.isEmpty)
        #expect(outcome.allSucceeded)
        #expect(store.pendingPrompt == nil)
        #expect(recorder.nonPrivilegedCalls.count == 1)
        #expect(recorder.nonPrivilegedCalls[0].0 == ["SystemPolicyAppBundles"])
        #expect(recorder.administratorCalls.count == 1)
        #expect(recorder.administratorCalls[0].0 == "SystemPolicyAllFiles")
        #expect(recorder.administratorCalls[0].1 == LegacyPermissionResetter.expectedBundleIdentifier)
    }

    @Test("手动清理取消管理员授权时抛出 CancellationError 并清除暂存提示")
    func manualResetPropagatesAdminCancellationCleanly() async {
        let store = InMemoryStore()
        let resetter = makeResetter(
            administratorResult: .failure(CancellationError()),
            store: store
        )

        await #expect(throws: CancellationError.self) {
            _ = try await resetter.resetManually(permissions: [.fullDiskAccess])
        }
        #expect(store.pendingPrompt == nil)
    }

    @Test("不在应用程序目录时手动清理拒绝执行")
    func manualResetRejectsDisallowedLocation() async {
        let resetter = makeResetter(isAllowedLocation: false)
        await #expect(throws: AppInstallationLocation.Failure.self) {
            _ = try await resetter.resetManually(permissions: [.appManagement])
        }
    }

    // MARK: - 脚本与签名指纹工具

    @Test("解析重置脚本逐行输出")
    func parsesResetOutput() {
        let parsed = LegacyPermissionResetter.parseResetOutput("""
        SystemPolicyAppBundles=1
        SystemPolicyAllFiles=0
        malformed
        """)
        #expect(parsed == [
            "SystemPolicyAppBundles": true,
            "SystemPolicyAllFiles": false
        ])
    }

    @Test("非提权重置脚本包含断管保护与进程退出自动重拉起逻辑")
    func resetScriptContainsSigkillRecoveryGuards() {
        let script = LegacyPermissionResetter.nonPrivilegedResetScript
        #expect(script.contains("trap '' HUP PIPE"))
        #expect(script.contains("/usr/bin/tccutil reset"))
        #expect(script.contains("/bin/kill -0 \"$parent_pid\""))
        #expect(script.contains("/usr/bin/open -n \"$bundle_path\""))
    }

    @Test("读取隔离临时应用包的签名指纹：自签名返回 cdhash，未签名返回 nil")
    func readsSigningIdentityFromIsolatedBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPorts-LegacyResetter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("Dummy.app", isDirectory: true)
        let macOSDir = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.shimoko.AppPorts.signing-probe</string>
        <key>CFBundleExecutable</key><string>Dummy</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let executable = macOSDir.appendingPathComponent("Dummy")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)

        // 先移除原有苹果签名，验证未签名返回 nil
        let removeSign = Process()
        removeSign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        removeSign.arguments = ["--remove-signature", executable.path]
        try removeSign.run()
        removeSign.waitUntilExit()
        #expect(LegacyPermissionResetter.currentSigningIdentity(for: appURL) == nil)

        // 再做 ad-hoc 签名，验证能读取到稳定 cdhash 指纹
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", appURL.path]
        try sign.run()
        sign.waitUntilExit()
        #expect(sign.terminationStatus == 0)

        let identity = try #require(LegacyPermissionResetter.currentSigningIdentity(for: appURL))
        #expect(identity.hasPrefix("cdhash:"))
        #expect(identity.count > "cdhash:".count)
    }
}
