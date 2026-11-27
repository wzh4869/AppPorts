//
//  LegacyPermissionResetter.swift
//  AppPorts
//
//  应用签名证书更新后，自动清理已失效的旧版 TCC 权限记录并引导用户重新授权。
//

import CryptoKit
import Foundation
import Security

/// 负责在应用签名身份变化且权限失效时清理旧版 TCC 残留记录。
///
/// 设计约束：
/// 1. 仅在老用户（已完成欢迎引导）、应用位于「应用程序」文件夹且实际权限未生效时触发；
/// 2. 绝不重置已经 `.granted` 的权限，且同一签名指纹最多自动执行一次；
/// 3. 启动自动清理绝不弹出管理员密码框；仅在用户主动点击「清理旧版授权记录」且涉及系统域
///    `SystemPolicyAllFiles`（完全磁盘访问权限）时按需请求管理员授权；
/// 4. 执行 `tccutil reset` 前持久化待展示提示与已处理指纹，防止 `tccd` 终止进程导致闪退或死循环。
final class LegacyPermissionResetter: Sendable {
    static let shared = LegacyPermissionResetter()

    static let expectedBundleIdentifier = "com.shimoko.AppPorts"
    static let handledSigningIdentityDefaultsKey = "LegacyPermissionResetter.handledSigningIdentity"
    static let pendingPromptDefaultsKey = "LegacyPermissionResetter.pendingPrompt"

    enum PermissionKind: String, Codable, Hashable, CaseIterable, Sendable {
        case appManagement
        case fullDiskAccess

        var tccService: String {
            switch self {
            case .appManagement: return "SystemPolicyAppBundles"
            case .fullDiskAccess: return "SystemPolicyAllFiles"
            }
        }

        var settingsAction: LaunchReadinessChecker.Item.Action {
            switch self {
            case .appManagement: return .appManagement
            case .fullDiskAccess: return .fullDiskAccess
            }
        }
    }

    struct ResetPrompt: Equatable, Codable, Sendable {
        let permissions: [PermissionKind]
        let resetSucceeded: [PermissionKind]
        let signingIdentity: String
    }

    struct ManualResetOutcome: Equatable, Sendable {
        let attempted: [PermissionKind]
        let succeeded: [PermissionKind]
        let failed: [PermissionKind]

        var allSucceeded: Bool { !attempted.isEmpty && failed.isEmpty }
    }

    struct Store: Sendable {
        var readHandledIdentity: @Sendable () -> String?
        var writeHandledIdentity: @Sendable (String?) -> Void
        var readPendingPrompt: @Sendable () -> ResetPrompt?
        var writePendingPrompt: @Sendable (ResetPrompt?) -> Void

        static let standard = Store(
            readHandledIdentity: {
                UserDefaults.standard.string(forKey: LegacyPermissionResetter.handledSigningIdentityDefaultsKey)
            },
            writeHandledIdentity: { value in
                if let value {
                    UserDefaults.standard.set(value, forKey: LegacyPermissionResetter.handledSigningIdentityDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: LegacyPermissionResetter.handledSigningIdentityDefaultsKey)
                }
            },
            readPendingPrompt: {
                guard let data = UserDefaults.standard.data(forKey: LegacyPermissionResetter.pendingPromptDefaultsKey) else {
                    return nil
                }
                return try? JSONDecoder().decode(ResetPrompt.self, from: data)
            },
            writePendingPrompt: { prompt in
                if let prompt, let data = try? JSONEncoder().encode(prompt) {
                    UserDefaults.standard.set(data, forKey: LegacyPermissionResetter.pendingPromptDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: LegacyPermissionResetter.pendingPromptDefaultsKey)
                }
            }
        )
    }

    struct Dependencies: Sendable {
        var hasCompletedWelcome: @Sendable () -> Bool
        var isAllowedLocation: @Sendable () -> Bool
        var bundleIdentifier: @Sendable () -> String?
        var bundleURL: @Sendable () -> URL
        var signingIdentity: @Sendable () -> String?
        var fullDiskAccessState: @Sendable () -> LaunchReadinessChecker.FullDiskAccessState
        var appManagementState: @Sendable () -> AppManagementPermission.State
        var resetTCC: @Sendable (_ services: [String], _ bundleID: String, _ relaunchBundleURL: URL?) async -> [String: Bool]
        var resetTCCWithAdministrator: @Sendable (_ service: String, _ bundleID: String) async throws -> Bool
        var store: Store

        static let live = Dependencies(
            hasCompletedWelcome: { UserDefaults.standard.bool(forKey: WelcomeLaunchPolicy.welcomeCompletedDefaultsKey) },
            isAllowedLocation: { AppInstallationLocation.isAllowed() },
            bundleIdentifier: { Bundle.main.bundleIdentifier },
            bundleURL: { Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL },
            signingIdentity: { LegacyPermissionResetter.currentSigningIdentity() },
            fullDiskAccessState: { LaunchReadinessChecker.fullDiskAccessState() },
            appManagementState: { AppManagementPermission.state() },
            resetTCC: { services, bundleID, relaunchBundleURL in
                await LegacyPermissionResetter.runNonPrivilegedReset(
                    services: services,
                    bundleID: bundleID,
                    relaunchBundleURL: relaunchBundleURL
                )
            },
            resetTCCWithAdministrator: { service, bundleID in
                try await LegacyPermissionResetter.runAdministratorReset(service: service, bundleID: bundleID)
            },
            store: .standard
        )
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    // MARK: - 启动自动清理

    /// 主界面首次启动时检查是否需要自动清理旧版 TCC 残留记录。
    ///
    /// 返回非 `nil` 表示需要向用户弹出「重新授予系统权限」提示窗。
    func evaluateAndResetOnLaunchIfNeeded() async -> ResetPrompt? {
        // 1. 若上一次执行 `tccutil reset` 时进程被 `tccd` 终止并自动重拉起，先承接未展示的提示。
        if let pending = dependencies.store.readPendingPrompt() {
            dependencies.store.writePendingPrompt(nil)
            let stillMissing = missingPermissions(limitedTo: pending.permissions)
            guard !stillMissing.isEmpty else { return nil }
            let stillReset = pending.resetSucceeded.filter { stillMissing.contains($0) }
            AppLogger.shared.logContext(
                "检测到重启前待展示的旧权限清理提示，继续引导授权",
                details: [
                    ("permissions", stillMissing.map(\.rawValue).joined(separator: ",")),
                    ("signing_identity", pending.signingIdentity)
                ]
            )
            return ResetPrompt(
                permissions: stillMissing,
                resetSucceeded: stillReset,
                signingIdentity: pending.signingIdentity
            )
        }

        // 2. 仅针对已完成欢迎引导、安装在应用程序目录且带有有效签名的正式副本执行。
        guard dependencies.hasCompletedWelcome(),
              dependencies.bundleIdentifier() == Self.expectedBundleIdentifier,
              dependencies.isAllowedLocation(),
              let identity = dependencies.signingIdentity(),
              !identity.isEmpty else {
            return nil
        }

        // 同一签名指纹只自动处理一次，避免反复重置或打扰用户。
        guard dependencies.store.readHandledIdentity() != identity else {
            return nil
        }

        // 3. 仅纳入实际失效的权限；两项均正常时只静默记录当前签名指纹，绝不触碰 TCC。
        let missing = missingPermissions(limitedTo: PermissionKind.allCases)
        guard !missing.isEmpty else {
            dependencies.store.writeHandledIdentity(identity)
            return nil
        }

        // 4. 在调用 `tccutil` 前先持久化已处理指纹和待展示提示，防止 `SIGKILL` 造成重启循环或丢提示。
        dependencies.store.writeHandledIdentity(identity)
        let provisional = ResetPrompt(
            permissions: missing,
            resetSucceeded: missing,
            signingIdentity: identity
        )
        dependencies.store.writePendingPrompt(provisional)

        let results = await dependencies.resetTCC(
            missing.map(\.tccService),
            Self.expectedBundleIdentifier,
            dependencies.bundleURL()
        )

        // 若进程未被 `tccd` 杀掉，由当前实例直接弹窗，不再留待下次启动。
        dependencies.store.writePendingPrompt(nil)
        let succeeded = missing.filter { results[$0.tccService] == true }

        AppLogger.shared.logContext(
            "签名变更后已自动执行旧版权限记录清理",
            details: [
                ("signing_identity", identity),
                ("missing", missing.map(\.tccService).joined(separator: ",")),
                ("reset_succeeded", succeeded.map(\.tccService).joined(separator: ","))
            ]
        )

        return ResetPrompt(
            permissions: missing,
            resetSucceeded: succeeded,
            signingIdentity: identity
        )
    }

    // MARK: - 手动兜底清理

    /// 用户在「准备情况」主动触发清理：App 管理免提权清理，系统域完全磁盘访问权限按需提权清理。
    func resetManually(permissions: [PermissionKind]) async throws -> ManualResetOutcome {
        guard dependencies.isAllowedLocation() else {
            throw AppInstallationLocation.Failure()
        }
        guard dependencies.bundleIdentifier() == Self.expectedBundleIdentifier else {
            return ManualResetOutcome(attempted: [], succeeded: [], failed: [])
        }

        let ordered = PermissionKind.allCases.filter { permissions.contains($0) }
        guard !ordered.isEmpty else {
            return ManualResetOutcome(attempted: [], succeeded: [], failed: [])
        }

        let identity = dependencies.signingIdentity() ?? "unknown"
        dependencies.store.writePendingPrompt(
            ResetPrompt(permissions: ordered, resetSucceeded: ordered, signingIdentity: identity)
        )
        defer { dependencies.store.writePendingPrompt(nil) }

        var succeeded: [PermissionKind] = []
        var failed: [PermissionKind] = []

        if ordered.contains(.appManagement) {
            let results = await dependencies.resetTCC(
                [PermissionKind.appManagement.tccService],
                Self.expectedBundleIdentifier,
                dependencies.bundleURL()
            )
            if results[PermissionKind.appManagement.tccService] == true {
                succeeded.append(.appManagement)
            } else {
                failed.append(.appManagement)
            }
        }

        if ordered.contains(.fullDiskAccess) {
            let ok = try await dependencies.resetTCCWithAdministrator(
                PermissionKind.fullDiskAccess.tccService,
                Self.expectedBundleIdentifier
            )
            if ok {
                succeeded.append(.fullDiskAccess)
            } else {
                failed.append(.fullDiskAccess)
            }
        }

        AppLogger.shared.logContext(
            "手动清理旧版权限记录完成",
            details: [
                ("attempted", ordered.map(\.tccService).joined(separator: ",")),
                ("succeeded", succeeded.map(\.tccService).joined(separator: ",")),
                ("failed", failed.map(\.tccService).joined(separator: ","))
            ]
        )

        return ManualResetOutcome(attempted: ordered, succeeded: succeeded, failed: failed)
    }

    // MARK: - 辅助方法

    private func missingPermissions(limitedTo candidates: [PermissionKind]) -> [PermissionKind] {
        var missing: [PermissionKind] = []
        if candidates.contains(.appManagement), dependencies.appManagementState() != .granted {
            missing.append(.appManagement)
        }
        if candidates.contains(.fullDiskAccess), dependencies.fullDiskAccessState() == .denied {
            missing.append(.fullDiskAccess)
        }
        return missing
    }

    /// 读取当前应用包的签名指纹：优先取叶子证书 SHA-256，无证书时回退到 CDHash。
    static func currentSigningIdentity(for bundleURL: URL = Bundle.main.bundleURL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var rawInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any] else {
            return nil
        }

        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first {
            let data = SecCertificateCopyData(leaf) as Data
            return "cert:" + sha256Hex(data)
        }

        if let cdhash = info[kSecCodeInfoUnique as String] as? Data, !cdhash.isEmpty {
            return "cdhash:" + cdhash.map { String(format: "%02x", $0) }.joined()
        }

        return nil
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 非提权重置脚本：忽略管道断裂，并在原 AppPorts 进程被 `tccd` 终止时自动拉起同一应用包。
    static let nonPrivilegedResetScript = """
    trap '' HUP PIPE
    parent_pid="$1"
    bundle_path="$2"
    bundle_id="$3"
    shift 3
    for svc in "$@"; do
      if /usr/bin/tccutil reset "$svc" "$bundle_id" >/dev/null 2>&1; then
        printf '%s=1\\n' "$svc" 2>/dev/null || true
      else
        printf '%s=0\\n' "$svc" 2>/dev/null || true
      fi
    done
    if [ -n "$bundle_path" ] && ! /bin/kill -0 "$parent_pid" 2>/dev/null; then
      /usr/bin/open -n "$bundle_path" >/dev/null 2>&1 || true
    fi
    """

    static func parseResetOutput(_ output: String) -> [String: Bool] {
        var parsed: [String: Bool] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let service = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !service.isEmpty {
                parsed[service] = (value == "1")
            }
        }
        return parsed
    }

    private static func runNonPrivilegedReset(
        services: [String],
        bundleID: String,
        relaunchBundleURL: URL?,
        runner: any ShellCommandRunning = ProcessCommandRunner()
    ) async -> [String: Bool] {
        guard !services.isEmpty else { return [:] }
        let parentPID = String(ProcessInfo.processInfo.processIdentifier)
        let bundlePath = relaunchBundleURL?.path ?? ""
        let arguments = ["-c", nonPrivilegedResetScript, "appports-tcc-reset", parentPID, bundlePath, bundleID] + services
        do {
            let result = try await runner.run(executable: "/bin/sh", arguments: arguments, timeout: 15)
            guard !result.timedOut else {
                AppLogger.shared.logContext(
                    "重置旧版权限记录超时",
                    details: [("services", services.joined(separator: ","))],
                    level: "WARN"
                )
                return [:]
            }
            return parseResetOutput(result.stdoutText)
        } catch {
            AppLogger.shared.logError("重置旧版权限记录失败", error: error, errorCode: "LEGACY-TCC-RESET-FAILED")
            return [:]
        }
    }

    private static func runAdministratorReset(service: String, bundleID: String) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            do {
                let result = try DiskUtility.runWithAdministratorPrivileges(
                    executable: "/usr/bin/tccutil",
                    arguments: ["reset", service, bundleID]
                )
                return result.status == 0 && !result.timedOut
            } catch DiskUtility.Failure.administratorPromptCancelled {
                throw CancellationError()
            }
        }.value
    }
}
