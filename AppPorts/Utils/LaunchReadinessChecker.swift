//
//  LaunchReadinessChecker.swift
//  AppPorts
//
//  欢迎屏的启动自检：迁移所需权限是否齐全、外部存储格式是否满足要求。
//

import Foundation
import Darwin

// MARK: - 启动自检

/// 欢迎屏「状态检查」的判定逻辑。
///
/// 三个检查项：
/// 1. **完全磁盘访问权限**：读取 `~/Library` 下受 TCC 保护的应用数据（邮件、信息等）需要它；
/// 2. **App 管理权限**（`kTCCServiceSystemPolicyAppBundles`）：替换 `/Applications` 里的应用需要它；
/// 3. **外部存储格式**：只有沙盒应用的数据（挂载迁移）要求 APFS；其他情况说明「不影响其他迁移」。
///
/// 结果只用于提示，不阻断用户进入主界面：外部存储可以稍后再选。
struct LaunchReadinessChecker: Sendable {

    /// 当前进程实际打开受保护文件的结果，不代表读到了系统设置的授权记录。
    enum FullDiskAccessState: Equatable, Sendable {
        case granted
        case denied
        case unknown
    }

    /// 始终使用运行中的 bundle，不能通过名称查找 /Applications 中的另一份副本。
    struct RunningApplication: Equatable, Sendable {
        let url: URL
        let version: String
        let build: String

        init(bundle: Bundle = .main) {
            url = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
            build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        }
    }

    // MARK: 结果类型

    /// 单项检查结果
    struct Item: Identifiable, Equatable, Sendable {
        enum Level: Equatable, Sendable {
            /// 已满足
            case ok
            /// 不满足，但有退路（例如外部盘不是 APFS）
            case warning
            /// 不满足且必须处理（缺少权限）
            case failed
        }

        /// 点击「去设置授予权限」后要打开的系统设置面板
        enum Action: Equatable, Sendable {
            case fullDiskAccess
            case appManagement
        }

        let id: String
        let level: Level
        let title: String
        let detail: String
        let action: Action?
    }

    /// 外部存储的检查结果
    enum ExternalDriveState: Equatable, Sendable {
        /// 用户还没选外部存储
        case notSelected
        /// 路径不存在或卷信息读不出来（盘没插、卷已卸载）
        case unavailable(path: String)
        /// 已是 APFS，可以挂载迁移
        case apfs
        /// APFS 已加密：挂载迁移会为新数据卷单独设置密码
        case encryptedAPFS
        /// 不是 APFS，挂载迁移不可用
        case notAPFS(filesystem: String?)
    }

    /// 检查项的稳定标识，界面与测试共用。
    enum ItemID {
        static let fullDiskAccess = "full-disk-access"
        static let appManagement = "app-management"
        static let externalDrive = "external-drive"
    }

    /// 外部存储路径在 UserDefaults 里的键，与主界面共用。
    static let externalDrivePathKey = "ExternalDrivePath"

    // MARK: 依赖注入

    /// 检测用到的外部依赖；测试注入假实现，避免依赖真机状态。
    struct Probe: Sendable {
        var fullDiskAccessState: @Sendable () -> FullDiskAccessState
        var appManagementState: @Sendable () -> AppManagementPermission.State
        var externalDrivePath: @Sendable () -> String?
        var externalDriveState: @Sendable (_ path: String) async -> ExternalDriveState
    }

    let probe: Probe

    init(probe: Probe = .live) {
        self.probe = probe
    }

    // MARK: 检查

    /// 依次检查三项，返回界面直接可用的结果列表。
    func check() async -> [Item] {
        let savedPath = probe.externalDrivePath()
        let driveState: ExternalDriveState
        if let savedPath, !savedPath.isEmpty {
            driveState = await probe.externalDriveState(savedPath)
        } else {
            driveState = .notSelected
        }

        return Self.items(
            fullDiskAccessState: probe.fullDiskAccessState(),
            appManagementState: probe.appManagementState(),
            externalDriveState: driveState
        )
    }

    /// 纯函数版本：把已检测到的状态映射成检查项，方便测试。
    static func items(
        fullDiskAccessState: FullDiskAccessState,
        appManagementState: AppManagementPermission.State,
        externalDriveState: ExternalDriveState
    ) -> [Item] {
        [
            fullDiskAccessItem(state: fullDiskAccessState),
            appManagementItem(state: appManagementState),
            externalDriveItem(state: externalDriveState)
        ]
    }

    static func fullDiskAccessItem(state: FullDiskAccessState) -> Item {
        switch state {
        case .denied:
            return Item(
                id: ItemID.fullDiskAccess,
                level: .failed,
                title: "完全磁盘访问权限".localized,
                detail: "当前 AppPorts 读取受保护文件时被系统拒绝。若已开启权限，请核对授权的是否为当前这份应用，并退出重开。".localized,
                action: .fullDiskAccess
            )
        case .unknown:
            return Item(
                id: ItemID.fullDiskAccess,
                level: .warning,
                title: "完全磁盘访问权限".localized,
                detail: "无法确认当前 AppPorts 的访问权限：检查文件不可用或发生其他读取错误。请在系统设置中核对。".localized,
                action: .fullDiskAccess
            )
        case .granted:
            return Item(
                id: ItemID.fullDiskAccess,
                level: .ok,
                title: "完全磁盘访问权限".localized,
                detail: "当前 AppPorts 已通过受保护文件读取检查；个别目录仍可能有其他访问限制。".localized,
                action: nil
            )
        }
    }

    static func appManagementItem(state: AppManagementPermission.State) -> Item {
        let level: Item.Level
        let detail: String
        switch state {
        case .granted:
            level = .ok
            detail = "当前 AppPorts 已获准更新或删除其他应用。".localized
        case .denied:
            level = .failed
            detail = "当前 AppPorts 未获准更新或删除其他应用。请在系统设置的「App 管理」中开启权限。".localized
        case .unknown:
            level = .warning
            detail = "无法读取当前 AppPorts 的 App 管理授权状态。请在系统设置中核对。".localized
        }
        return Item(
            id: ItemID.appManagement,
            level: level,
            title: "App 管理权限".localized,
            detail: detail,
            action: .appManagement
        )
    }

    private static func externalDriveItem(state: ExternalDriveState) -> Item {
        switch state {
        case .notSelected:
            return Item(
                id: ItemID.externalDrive,
                level: .warning,
                title: "外部存储".localized,
                detail: "可以先开始使用，之后再选择存放应用的外部存储。".localized,
                action: nil
            )
        case .unavailable(let path):
            return Item(
                id: ItemID.externalDrive,
                level: .warning,
                title: "外部存储".localized,
                detail: String(
                    format: "读不到外部存储路径：%@。请连接外部存储后重新检查。".localized,
                    path
                ),
                action: nil
            )
        case .apfs:
            return Item(
                id: ItemID.externalDrive,
                level: .ok,
                title: "外部存储".localized,
                detail: "格式为 APFS。应用和数据目录都可以迁移到这里，包括沙盒应用的数据（如聊天记录）。".localized,
                action: nil
            )
        case .encryptedAPFS:
            return Item(
                id: ItemID.externalDrive,
                level: .ok,
                title: "外部存储".localized,
                detail: "格式为 APFS（已加密）。可以迁移沙盒应用数据；首次迁移时需为新数据卷设置密码，可选择保存到本机钥匙串。".localized,
                action: nil
            )
        case .notAPFS(let filesystem):
            // 不把用户引向经典模式：它会重签沙盒应用，在 macOS 27 上可能让应用打不开。
            let format = filesystemDisplayName(filesystem) ?? "未知格式".localized
            return Item(
                id: ItemID.externalDrive,
                level: .warning,
                title: "外部存储".localized,
                detail: String(
                    format: "当前格式：%@。应用和普通数据目录可以照常迁移到这里。只有沙盒应用的数据（如聊天记录）需要 APFS 格式；这部分留在本机也不影响使用，不需要为此改动这块盘。".localized,
                    format
                ),
                action: nil
            )
        }
    }

    /// diskutil 给出的文件系统类型（apfs/hfs/exfat…）转成用户认得的写法。
    static func filesystemDisplayName(_ type: String?) -> String? {
        guard let raw = type?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "apfs": return "APFS"
        case "hfs": return "HFS+"
        case "exfat": return "ExFAT"
        case "msdos", "fat": return "FAT32"
        case "ntfs": return "NTFS"
        default: return raw.uppercased()
        }
    }

    // MARK: 探针实现

    /// 只有拿到「完全磁盘访问权限」才能打开的文件；按先后顺序探测。
    static func fullDiskAccessProbePaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
        [
            "\(homeDirectory)/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db"
        ]
    }

    /// 尝试打开受 TCC 保护的文件来判断完全磁盘访问权限。
    ///
    /// - Note: 直接 `open`，不以 fileExists/isReadableFile 代替访问检查；只打开并关闭，
    ///   不读取数据库内容。没有可用检查文件或发生 I/O 错误时不能断言用户未授权。
    ///   不使用 Messages 等可能获单独文件授权的路径作为完全磁盘访问权限的依据。
    static func fullDiskAccessState(
        candidatePaths: [String] = fullDiskAccessProbePaths(),
        openProbe: (String) -> Int32 = probeProtectedFile
    ) -> FullDiskAccessState {
        var wasDenied = false
        for path in candidatePaths {
            let error = openProbe(path)
            if error == 0 { return .granted }
            if error == EACCES || error == EPERM { wasDenied = true }
        }
        return wasDenied ? .denied : .unknown
    }

    private static func probeProtectedFile(at path: String) -> Int32 {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return errno }
        // 目录或替代链接不能证明受保护数据库可访问。
        return (metadata.st_mode & S_IFMT) == S_IFREG ? 0 : EINVAL
    }

    /// 读取外部存储路径所在卷的文件系统类型。
    static func externalDriveState(atPath path: String, disk: DiskUtility = DiskUtility()) async -> ExternalDriveState {
        guard FileManager.default.fileExists(atPath: path) else { return .unavailable(path: path) }
        // diskutil 只认卷的挂载点或设备，不认卷内子目录。
        let volumePath = DiskUtility.mountedVolumePath(containing: URL(fileURLWithPath: path)) ?? path
        guard let info = try? await disk.volumeInfo(for: volumePath) else { return .unavailable(path: path) }
        guard info.isAPFS else { return .notAPFS(filesystem: info.filesystemType) }
        return info.isEncrypted ? .encryptedAPFS : .apfs
    }
}

// MARK: - 生产环境探针

extension LaunchReadinessChecker.Probe {
    /// 真机上的检测实现。
    static let live = LaunchReadinessChecker.Probe(
        fullDiskAccessState: { LaunchReadinessChecker.fullDiskAccessState() },
        appManagementState: { AppManagementPermission.state() },
        externalDrivePath: { UserDefaults.standard.string(forKey: LaunchReadinessChecker.externalDrivePathKey) },
        externalDriveState: { path in await LaunchReadinessChecker.externalDriveState(atPath: path) }
    )
}

// MARK: - 系统设置入口

extension LaunchReadinessChecker.Item.Action {
    var guideInstruction: String {
        switch self {
        case .fullDiskAccess:
            return "把图标拖入“完全磁盘访问权限”列表，再打开开关。".localized
        case .appManagement:
            return "把图标拖入“App 管理”列表，再打开开关。".localized
        }
    }

    /// 对应的「系统设置」面板；旧系统没有「App 管理」面板时退回「隐私与安全性」首页。
    var settingsURLs: [URL] {
        let rawValues: [String]
        switch self {
        case .fullDiskAccess:
            rawValues = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
        case .appManagement:
            rawValues = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles",
                "x-apple.systempreferences:com.apple.preference.security"
            ]
        }
        return rawValues.compactMap { URL(string: $0) }
    }
}
