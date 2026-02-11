//
//  AppModels.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation

// MARK: - 数据模型

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
    
    /// 唯一标识符，用于 SwiftUI 列表渲染
    let id = UUID()
    
    /// 应用名称（包含 .app 扩展名）
    /// - Example: "Safari.app", "Xcode.app"
    var name: String
    
    /// 应用的完整文件路径
    /// - Note: 可能指向本地 /Applications 或外部存储设备
    var path: URL
    
    // MARK: - 状态属性
    
    /// 应用当前状态
    /// - 可能的值：
    ///   - "本地": 应用在本地 /Applications 目录中
    ///   - "已链接": 应用已迁移到外部存储，本地存在符号链接
    ///   - "未链接": 应用在外部存储中，但本地没有链接
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
    
    /// 是否为 iOS 应用（iPhone/iPad 应用，运行在 Apple Silicon Mac 上）
    /// - Note: iOS 应用通常包含 WrappedBundle 或特定的 Info.plist 标识
    var isIOSApp: Bool = false
    
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
    
    /// 如果是文件夹，包含的应用数量
    /// - Note: 仅当 isFolder 为 true 时有效
    var appCount: Int = 0
    
    /// 用于 UI 显示的名称
    /// - 普通应用：直接返回 name
    /// - 文件夹：返回 "文件夹名 (X 个应用)"
    var displayName: String {
        if isFolder {
            return "\(name) (\(appCount) 个应用)"
        }
        return name
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
        lhs.isIOSApp == rhs.isIOSApp
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
    
    /// App Store 应用错误
    /// - Parameter Error: 相关的错误信息
    /// - Note: App Store 应用受 macOS 系统保护，自动迁移可能失败
    case appStoreAppError(Error)
    
    // MARK: - LocalizedError 实现
    
    /// 提供用户友好的错误描述
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return """
            权限不足。请前往"系统设置 > 隐私与安全性 > 完全磁盘访问权限"，\
            允许 AppPorts 访问磁盘，然后重启应用。
            """
            
        case .generalError(let innerError):
            return innerError.localizedDescription
            
        case .appIsRunning:
            return "该应用正在运行。请先退出应用，然后再试。"
            
        case .appStoreAppError:
            return """
            此 App Store 应用受系统保护，无法自动迁移。
            
            请尝试：
            1. 手动将应用移动到外部存储
            2. 然后回到 AppPorts 创建链接
            """
        }
    }
}
