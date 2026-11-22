//
//  AppModels.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation

// MARK: - 数据模型

enum AppContainerKind: String, Sendable {
    case standaloneApp
    case singleAppContainer
    case appSuiteFolder
}

enum AppBodyMigrationPolicy: Equatable, Sendable {
    case standard, requiresConfirmation, localOnly

    init(bundleIdentifier: String) {
        switch bundleIdentifier {
        case "com.shimoko.AppPorts": self = .localOnly
        case "io.github.clash-verge-rev.clash-verge-rev", "com.microsoft.VSCode",
             "com.microsoft.VSCodeInsiders", "com.apple.dt.Xcode": self = .requiresConfirmation
        default: self = .standard
        }
    }
}

enum AppStatus {
    static let local = "本地"
    static let linked = "已链接"
    static let unlinked = "未链接"
    static let partialLinked = "部分链接"
    static let orphanedLink = "孤立链接"
    static let external = "外部"
    static let pendingMoveOut = "待迁出"

    static func localized(_ status: String) -> String {
        switch status {
        case local:
            return "本地".localized
        case linked:
            return "已链接".localized
        case unlinked:
            return "未链接".localized
        case partialLinked:
            return "部分链接".localized
        case orphanedLink:
            return "孤立链接".localized
        case external:
            return "外部".localized
        case pendingMoveOut:
            return "待迁出".localized
        default:
            return status
        }
    }
}

/// 应用程序项目数据模型
///
/// 代表一个 macOS 应用程序的完整信息，包括基本属性、状态和特殊标识。
/// 该模型支持 Identifiable 协议用于 SwiftUI 列表显示，支持 Equatable 用于状态比较，
/// 支持 Sendable 用于跨并发域安全传递。
///
/// - Note: 该模型是不可变的（使用 let），确保数据一致性
///
/// ## 使用示例
/// ```swift
/// let app = AppItem(
///     name: "Safari.app",
///     path: URL(fileURLWithPath: "/Applications/Safari.app"),
///     status: "本地",
///     isSystemApp: true,
///     isRunning: false
/// )
/// ```
struct AppItem: Identifiable, Equatable, Sendable {
    // MARK: - 基本属性

    /// 应用名称（包含 .app 扩展名）
    /// - Example: “Safari.app”, “Xcode.app”
    var name: String

    /// 应用的完整文件路径
    /// - Note: 这是实际操作路径；对”单应用容器”场景会指向外层文件夹
    var path: URL

    /// 基于路径的稳定 ID，避免每次扫描重建列表
    nonisolated var id: String { path.standardizedFileURL.path }

    /// 实际用于展示图标和读取 bundle 信息的 app 路径
    ///
    /// - Note: 对普通 `.app` 与多应用套件，此值等于 `path` 或为 `nil`
    /// - Note: 对“单应用容器”场景，此值指向容器内唯一的 `.app`
    var bundleURL: URL? = nil
    
    // MARK: - 状态属性
    
    /// 应用当前状态
    /// - 可能的值：
    ///   - AppStatus.local: 应用在本地 /Applications 目录中
    ///   - AppStatus.linked: 应用已迁移到外部存储，本地存在入口
    ///   - AppStatus.unlinked: 应用在外部存储中，但本地没有入口
    ///   - AppStatus.pendingMoveOut: 本地真实应用版本高于外部同名目标，可迁出替换外部旧副本
    var status: String
    
    // MARK: - 特征标识
    
    /// 是否为系统应用
    /// - Note: 系统应用通常位于 /System/Applications，不建议迁移
    var isSystemApp: Bool = false
    
    /// 应用是否正在运行
    /// - Note: 正在运行的应用不允许迁移或删除
    var isRunning: Bool = false
    
    /// 是否为 App Store 应用
    /// - Note: App Store 应用包含 _MASReceipt 目录，受系统保护
    var isAppStoreApp: Bool = false

    /// 是否位于外部磁盘的 Applications 目录（macOS 15.1+ MAS 外部安装）
    var isMASExternal: Bool = false
    
    /// 是否为 iOS 应用（iPhone/iPad 应用，运行在 Apple Silicon Mac 上）
    /// - Note: iOS 应用通常包含 WrappedBundle 或特定的 Info.plist 标识
    var isIOSApp: Bool = false

    /// 有 AppPorts 签名备份，且当前签名已确认为 Ad-hoc。
    var isResigned: Bool = false

    /// 原始开发者签名已被 Ad-hoc 签名替换：备份记录的原始身份是开发者证书，当前签名却是 ad-hoc。
    /// 这类应用在 macOS 27 上可能无法打开，修复路径是还原数据、重装后再挂载迁移。
    var signatureReplaced: Bool = false

    /// 有恢复记录，但本次无法检查真实应用的签名。不能解释为已替换或已恢复。
    var signatureCheckUnavailable: Bool = false

    var needsSignatureAttention: Bool { signatureReplaced || signatureCheckUnavailable }

    /// 是否为 Electron 应用（含 Electron Framework）
    var isElectronApp: Bool = false

    /// 是否为 Sparkle/Squirrel 自更新应用
    var isSparkleApp: Bool = false

    /// 是否有自更新能力（Sparkle、electron-updater、自定义更新器）
    var hasSelfUpdater: Bool = false

    /// 是否需要 uchg 锁定（仅 Sparkle/Electron 有更新器的应用）
    var needsLock: Bool = false

    var updateInspection: AppUpdateInspection?
    var updateRoute: AppUpdateRoute = .unknown
    var bodyMigrationPolicy: AppBodyMigrationPolicy = .standard
    var showsAppData: Bool { !isFolder && bodyMigrationPolicy != .localOnly }
    var bundleIsLocked: Bool?
    var hasVerifiedUpdateInspection: Bool { updateInspection != nil && bundleIsLocked != nil }

    /// 应用版本号（CFBundleShortVersionString）
    var version: String? = nil

    // MARK: - 大小信息
    
    /// 应用大小的可读字符串（如 "1.2 GB", "450 MB"）
    /// - Note: nil 表示尚未计算大小
    var size: String? = nil
    
    /// 应用大小的原始字节数
    /// - Note: 用于排序和精确比较，0 表示尚未计算
    var sizeBytes: Int64 = 0
    
    // MARK: - 文件夹属性
    
    /// 是否为包含多个应用的文件夹（如 Microsoft Office 文件夹）
    /// - Note: 文件夹项可以批量迁移其中的所有应用
    var isFolder: Bool = false

    /// 容器类型
    var containerKind: AppContainerKind = .standaloneApp
    
    /// 如果是文件夹，包含的应用数量
    /// - Note: 仅当 isFolder 为 true 时有效
    var appCount: Int = 0
    
    /// 用于 UI 显示的名称
    /// - 普通应用：直接返回 name
    /// - 文件夹：返回 "文件夹名 (X 个应用)"
    /// - 单应用容器：返回内部 app 的名称
    nonisolated var displayName: String {
        if isFolder {
            return String(format: "%@ (%lld 个应用)".localized, name, Int64(appCount))
        }
        if let bundleURL {
            return bundleURL.lastPathComponent
        }
        return name
    }

    /// UI 展示图标与 bundle 元数据时使用的 URL
    nonisolated var displayURL: URL {
        bundleURL ?? path
    }

    /// 是否按“整个文件夹”执行迁移/还原/链接
    nonisolated var usesFolderOperation: Bool {
        isFolder || containerKind == .singleAppContainer
    }

    nonisolated var willMigrateToStoreDirectory: Bool {
        status == AppStatus.local && isAppStoreApp && !usesFolderOperation
    }

    // MARK: - Equatable 实现
    
    /// 自定义相等性比较
    /// - Note: 比较所有属性以确保完整的状态一致性
    static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.status == rhs.status &&
        lhs.isRunning == rhs.isRunning &&
        lhs.size == rhs.size &&
        lhs.sizeBytes == rhs.sizeBytes &&
        lhs.isAppStoreApp == rhs.isAppStoreApp &&
        lhs.isMASExternal == rhs.isMASExternal &&
        lhs.isIOSApp == rhs.isIOSApp &&
        lhs.isResigned == rhs.isResigned &&
        lhs.signatureReplaced == rhs.signatureReplaced &&
        lhs.signatureCheckUnavailable == rhs.signatureCheckUnavailable &&
        lhs.isElectronApp == rhs.isElectronApp &&
        lhs.isSparkleApp == rhs.isSparkleApp &&
        lhs.hasSelfUpdater == rhs.hasSelfUpdater &&
        lhs.needsLock == rhs.needsLock &&
        lhs.updateInspection == rhs.updateInspection &&
        lhs.updateRoute == rhs.updateRoute &&
        lhs.bodyMigrationPolicy == rhs.bodyMigrationPolicy &&
        lhs.bundleIsLocked == rhs.bundleIsLocked &&
        lhs.bundleURL == rhs.bundleURL &&
        lhs.containerKind == rhs.containerKind &&
        lhs.isSystemApp == rhs.isSystemApp &&
        lhs.isFolder == rhs.isFolder &&
        lhs.appCount == rhs.appCount &&
        lhs.version == rhs.version
    }
}

/// 应用列表已测量项的展示体积汇总；仅用于界面展示，不代表本机已释放空间，也不参与迁移准入判断。
struct AppListDisplaySizeSummary: Equatable {
    let bytes: Int64
    let isCalculating: Bool
    let itemCount: Int

    init(apps: [AppItem]) {
        var seen = Set<String>()
        var total: Int64 = 0
        var calculating = false
        var count = 0
        for app in apps where seen.insert(app.id).inserted {
            count += 1
            if app.size == nil {
                calculating = true
            } else {
                total += max(0, app.sizeBytes)
            }
        }
        self.bytes = total
        self.isCalculating = calculating
        self.itemCount = count
    }

    var headerText: String? {
        guard itemCount > 0 else { return nil }
        if isCalculating && bytes == 0 {
            return "计算中...".localized
        }
        var text = LocalizedByteCountFormatter.string(fromByteCount: bytes)
        if isCalculating {
            text += "（统计中）".localized
        }
        return text
    }
}

// MARK: - 错误类型

/// 应用迁移操作中可能发生的错误
///
/// 定义了应用迁移、链接创建和删除操作中可能遇到的各种错误情况。
/// 每个错误都提供了本地化的错误描述，方便向用户展示。
///
/// ## 使用示例
/// ```swift
/// do {
///     try moveApp(to: destination)
/// } catch let error as AppMoverError {
///     showAlert(error.errorDescription ?? "未知错误")
/// }
/// ```
enum AppMoverError: LocalizedError {
    
    /// 权限被拒绝
    /// - Parameter Error: 底层的系统错误信息
    /// - Note: 通常需要在"系统设置 > 隐私与安全性"中授予完全磁盘访问权限
    case permissionDenied(Error)
    
    /// 一般性错误
    /// - Parameter Error: 底层的错误详情
    case generalError(Error)
    
    /// 应用正在运行
    /// - Note: 必须先退出应用才能进行迁移或删除操作
    case appIsRunning
    
    // MARK: - LocalizedError 实现
    
    /// 提供用户友好的错误描述
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return """
            权限不足。请前往“系统设置 > 隐私与安全性 > 完全磁盘访问权限”，\
            允许 AppPorts 访问磁盘，然后重启应用。
            """.localized
            
        case .generalError(let innerError):
            return innerError.localizedDescription
            
        case .appIsRunning:
            return "该应用正在运行。请先退出应用，然后再试。".localized
        }
    }
}

// MARK: - 签名已被替换（启动提醒）

/// 「签名已被替换」提醒使用的轻量条目，只带提醒需要的展示信息。
///
/// 该提醒不依赖完整应用扫描（体积计算、Sparkle 探测等），启动时单独查一次即可，
/// 所以不能复用 `AppItem`——那需要等首次扫描跑完。
struct SignatureReplacedApp: Identifiable, Equatable, Sendable {
    let name: String
    let bundleURL: URL?
    let path: URL

    /// 与完整扫描结果一致的稳定标识，用于记住「以后再说」。
    var dismissalKey: String { (bundleURL ?? path).standardizedFileURL.path }
    var displayName: String { bundleURL?.lastPathComponent ?? name }
    var id: String { dismissalKey }
}

extension AppItem {
    /// 完整扫描结果转成提醒条目，两种来源共用同一份提醒逻辑。
    var signatureRepairEntry: SignatureReplacedApp {
        SignatureReplacedApp(name: name, bundleURL: bundleURL, path: path)
    }
}
