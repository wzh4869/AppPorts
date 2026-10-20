//
//  PartialWeChatMigrationPolicy.swift
//  AppPorts
//

import Foundation

/// 微信账号目录内部的部分目录迁移策略（拆分迁移）。
///
/// ## 背景
///
/// `DataPathPolicy` 对微信只放行 `Documents/xwechat_files/<账号>` 整层，更深路径一律按
/// `weChatCompatibility` 锁死。这是有意的保守默认：整层迁移是社区与官方教程验证最充分的路径。
///
/// 但整层迁移有一个结构性代价：加密聊天数据库（`db_storage`）与登录密钥（`all_users`）
/// 跟着媒体文件一起搬到外置盘，于是外置盘不在时微信连文字消息都打不开。
///
/// 拆分迁移把这两类数据分开：
/// - **留本地**：`db_storage`（加密 SQLite 数据库）、`all_users`（登录密钥）、`config`、`resource`
/// - **可外迁**：`msg`（图片/视频/文件）、`business`（收藏、表情）
///
/// 实测（macOS 26 + 微信 4.1.13，账号目录 19 GB）确认：
/// - 微信用**相对路径**定位媒体文件，数据库内不存在绝对路径引用
/// - 外置盘缺席时微信可正常启动、聊天列表与文字消息可用，仅媒体文件需重新接收
/// - 外置盘缺席时微信**不会**往空的 `msg/` 写一套新数据形成分叉
///
/// ## 风险与适用范围
///
/// 这是**实验性**能力，默认关闭。理由：
/// - 微信 4.0 曾大改数据结构使旧方案全部失效，内部实现不稳定
/// - 上述结论仅在单一版本、单账号、单使用模式下验证
/// - 拆分会同时存在本地与外部两份数据，回滚路径比整层迁移复杂
///
/// 因此只在用户显式开启后生效，且每个放行目录都要求能单独回滚。
struct PartialWeChatMigrationPolicy: Sendable {
    /// 允许外迁的账号目录子目录。
    ///
    /// 故意只放行体积大、可再生或可重新接收的目录：
    /// - `msg`：聊天图片、视频、收到的文件（体积主体）
    /// - `business`：收藏、表情、朋友圈缓存
    ///
    /// `db_storage`、`all_users`、`config`、`resource`、`cache`、`temp`、`apm_record`
    /// 一律不放行：它们是启动与聊天记录的必要条件，且体积小。
    static let relocatableSubdirectories: Set<String> = [
        "msg",
        "business",
    ]

    /// 账号目录在容器内的固定路径段。账号名本身不纳入匹配，
    /// 因此 `wxid_xxx_220d` 之类的任意账号目录都适用。
    private static let accountPathComponents = ["Documents", "xwechat_files"]

    /// 是否允许拆分迁移。默认关闭，需用户在设置中显式开启。
    var isEnabled: Bool

    init(isEnabled: Bool = MigrationPreferences.isPartialWeChatMigrationActive) {
        self.isEnabled = isEnabled
    }

    /// 评估一个路径在拆分迁移下的许可。
    ///
    /// 只对 `.../Documents/xwechat_files/<账号>/<子目录>` 这一层生效；
    /// 账号目录本身及其它所有路径都交给 `DataPathPolicy`，本策略不发表意见。
    func evaluate(_ url: URL, home: URL) -> Decision {
        guard isEnabled else { return .notApplicable }
        guard let subdirectory = relocatableSubdirectory(of: url, home: home) else { return .notApplicable }
        return Decision(canMigrate: true, reason: nil, subdirectory: subdirectory)
    }

    /// 从路径中取出可外迁的子目录名；不是可外迁的账号子目录时返回 nil。
    func relocatableSubdirectory(of url: URL, home: URL) -> String? {
        let containers = home.appendingPathComponent("Library/Containers").standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        guard path.starts(with: containers), path.count > containers.count else { return nil }

        let relative = Array(path.dropFirst(containers.count))
        // Containers/<bundle id>/Data/Documents/xwechat_files/<账号>/<子目录>
        // relative: [bundle id, "Data", "Documents", "xwechat_files", <账号>, <子目录>]
        guard relative.count == 6 else { return nil }
        guard relative[0] == "com.tencent.xinWeChat" else { return nil }
        guard relative[1] == "Data" else { return nil }
        // 账号名（relative[4]）不参与匹配，只校验固定路径段。
        guard Array(relative[2..<4]) == Self.accountPathComponents else { return nil }

        let subdirectory = relative[5]
        guard Self.relocatableSubdirectories.contains(subdirectory) else { return nil }
        return subdirectory
    }

    struct Decision: Equatable, Sendable {
        let canMigrate: Bool
        let reason: Reason?
        /// 放行的子目录名，用于日志与回滚定位。
        let subdirectory: String?

        static let notApplicable = Decision(canMigrate: false, reason: nil, subdirectory: nil)

        static func allowed(_ subdirectory: String) -> Decision {
            Decision(canMigrate: true, reason: nil, subdirectory: subdirectory)
        }
    }

    enum Reason: Equatable, Sendable {
        /// 拆分迁移会同时保留本地与外部两份数据，需要向用户说明回滚方式。
        case splitDataRequiresManualRollback
    }
}
