//
//  DataDirItem.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/3/4.
//

import Foundation

// MARK: - 数据目录类型

/// 数据目录的来源类型
enum DataDirType: String, CaseIterable, Sendable {
    /// ~/Library/Application Support/ 下的应用数据
    case applicationSupport = "Application Support"
    /// ~/Library/Containers/ 下的沙盒应用数据
    case containers = "Containers"
    /// ~/Library/Group Containers/ 下的共享数据
    case groupContainers = "Group Containers"
    /// ~/Library/Caches/ 下的应用缓存
    case caches = "Caches"
    /// ~/Library/Saved Application State/ 下的窗口状态
    case savedState = "Saved State"
    /// ~/.xxx 工具直写目录
    case dotFolder = "工具目录"
    /// 用户手动添加的目录
    case custom = "自定义"

    /// 显示用图标
    var icon: String {
        switch self {
        case .applicationSupport: return "doc.fill"
        case .containers:         return "shippingbox.fill"
        case .groupContainers:    return "square.grid.2x2.fill"
        case .caches:             return "arrow.2.circlepath"
        case .savedState:         return "clock.arrow.circlepath"
        case .dotFolder:          return "wrench.fill"
        case .custom:             return "folder.badge.plus"
        }
    }
}

// MARK: - 迁移优先级

/// 目录迁移的重要程度建议
enum DataDirPriority: String, Sendable, Comparable {
    /// 重要：迁移后必须正常工作，影响应用核心功能
    case critical    = "重要"
    /// 推荐：占用空间大，迁移收益高
    case recommended = "推荐"
    /// 可选：空间较小或可重建
    case optional    = "可选"

    static func < (lhs: DataDirPriority, rhs: DataDirPriority) -> Bool {
        let order: [DataDirPriority] = [.critical, .recommended, .optional]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    var color: String {
        switch self {
        case .critical:    return "red"
        case .recommended: return "orange"
        case .optional:    return "blue"
        }
    }
}

// MARK: - 数据目录模型

/// 表示一个可迁移的数据目录项
///
/// 覆盖两类目录：
/// - `~/Library/` 下与 `.app` 关联的标准数据目录
/// - `~/.xxx` 工具直写目录（如 `.npm`、`.m2`、`.ollama`）
///
/// ## 使用示例
/// ```swift
/// let item = DataDirItem(
///     name: "npm 缓存",
///     path: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".npm"),
///     type: .dotFolder,
///     priority: .recommended,
///     description: "Node.js 包管理器缓存",
///     isMigratable: true
/// )
/// ```
struct DataDirItem: Identifiable, Equatable, Sendable {
    // MARK: - 基本属性
    let id = UUID()

    /// 显示名称（如 "npm 缓存", "Application Support"）
    var name: String

    /// 目录实际路径
    var path: URL

    /// 目录类型
    var type: DataDirType

    /// 迁移优先级建议
    var priority: DataDirPriority

    /// 用途说明（展示给用户）
    var description: String

    /// 关联的应用名称（仅 Library 类型目录有，dotFolder 为 nil）
    var associatedAppName: String? = nil

    // MARK: - 状态属性

    /// 当前状态
    /// - "本地"：正常存在于本机
    /// - "已链接"：已迁移到外部，本地为符号链接
    /// - "未找到"：路径不存在
    var status: String = "本地"

    /// 目录大小字符串（nil 表示计算中）
    var size: String? = nil

    /// 目录大小原始字节数
    var sizeBytes: Int64 = 0

    // MARK: - 权限控制

    /// 是否允许迁移
    ///
    /// - Note: `.local`、`.config` 等系统级目录设为 false，只读展示
    var isMigratable: Bool = true

    /// 不可迁移时的原因说明
    var nonMigratableReason: String? = nil

    // MARK: - 符号链接信息

    /// 如果已链接，链接指向的外部路径
    var linkedDestination: URL? = nil

    // MARK: - Equatable
    static func == (lhs: DataDirItem, rhs: DataDirItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.status == rhs.status &&
        lhs.size == rhs.size &&
        lhs.sizeBytes == rhs.sizeBytes
    }
}
