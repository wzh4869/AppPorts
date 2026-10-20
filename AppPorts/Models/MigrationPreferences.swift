//
//  MigrationPreferences.swift
//  AppPorts
//

import Foundation

/// 数据迁移相关的用户偏好，供视图、扫描器和登录脚本共用。
enum MigrationPreferences {
    /// 经典数据迁移模式：容器目录允许符号链接迁移，沙盒应用允许重签名。
    /// 只面向暂不升级 macOS 27 且外置盘不是 APFS 的用户；27 及以上已知不工作，开关禁用。
    static let classicDataMigrationKey = "classicDataMigrationEnabled"

    /// 启动提醒里用户点过「以后再说」的应用集合（真实应用路径）。
    static let dismissedSignatureRepairKey = "signatureRepairDismissedApps"

    /// 微信账号目录的拆分迁移（实验性）：只外迁 `msg`、`business`，
    /// 保留 `db_storage` 与 `all_users` 在本地，使外置盘缺席时微信仍可启动。
    /// 默认关闭，需用户在设置中显式开启。
    static let partialWeChatMigrationKey = "partialWeChatMigrationEnabled"

    /// 经典模式是否可用。macOS 27 上被重签名的沙盒应用可能无法打开，
    /// 但 QQ 音乐等实测正常，因此不按版本禁用，只在确认框里说明。
    static var isClassicModeSupported: Bool { true }

    /// 当前是否为 macOS 27 及以上，用于选择提示文案。
    static var isMacOS27OrLater: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    /// 经典模式是否生效：用户开启且系统允许。
    static var isClassicDataMigrationActive: Bool {
        isClassicModeSupported && UserDefaults.standard.bool(forKey: classicDataMigrationKey)
    }

    /// 微信拆分迁移是否生效。实验性能力，默认关闭。
    static var isPartialWeChatMigrationActive: Bool {
        UserDefaults.standard.bool(forKey: partialWeChatMigrationKey)
    }

    static var dismissedSignatureRepairApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: dismissedSignatureRepairKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: dismissedSignatureRepairKey) }
    }
}
