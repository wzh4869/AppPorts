import XCTest
@testable import AppPorts

/// 微信账号目录拆分迁移（实验性）的策略测试。
///
/// 关注点：默认关闭时行为与现有白名单完全一致；开启后只放行白名单内的子目录，
/// 且不因为链接目标在外置盘而被绕过。
final class PartialWeChatMigrationPolicyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture/home")

    private func account(_ subpath: String) -> URL {
        home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/account")
            .appendingPathComponent(subpath)
    }

    private func policy(enabled: Bool) -> DataPathPolicy {
        var policy = DataPathPolicy(homeDirectory: home)
        policy.partialWeChatMigration = PartialWeChatMigrationPolicy(isEnabled: enabled)
        return policy
    }

    // MARK: - 默认关闭：白名单行为不变

    func testDisabledByDefaultKeepsExistingWhitelist() {
        let disabled = policy(enabled: false)
        // 账号目录本身照旧可迁移。
        XCTAssertTrue(disabled.evaluate(account("")).canMigrate)
        // 深层目录照旧锁死。
        XCTAssertFalse(disabled.evaluate(account("msg")).canMigrate)
        XCTAssertFalse(disabled.evaluate(account("business")).canMigrate)
        XCTAssertFalse(disabled.evaluate(account("db_storage")).canMigrate)
        XCTAssertNil(disabled.evaluate(account("msg")).partialSubdirectory)
    }

    func testExistingWhitelistTestStillPassesWhenDisabled() {
        // 与 DataPathPolicyTests.testWeChatWhitelistIsUnchangedAndExact 同一组断言，
        // 确认新增的补充判断不会在关闭时改变任何结论。
        let disabled = policy(enabled: false)
        let data = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        for path in ["Documents/xwechat_files/account", "Library/Application Support/com.tencent.xinWeChat"] {
            XCTAssertTrue(disabled.evaluate(data.appendingPathComponent(path)).canMigrate, path)
        }
        for path in ["Documents/xwechat_files", "Documents/Other", "Documents/xwechat_files/account/deeper",
                     "Library/Caches/cache", "Library/Application Support/com.tencent.xinWeChat-other"] {
            XCTAssertFalse(disabled.evaluate(data.appendingPathComponent(path)).canMigrate, path)
        }
    }

    func testExistingWhitelistHoldsWhenEnabled() {
        // 最关键的回归保护：即使拆分迁移开启，账号目录本身与既有白名单的结论不变，
        // 只有 msg/business 这两个子目录被额外放行。
        let enabled = policy(enabled: true)
        let data = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        for path in ["Documents/xwechat_files/account", "Library/Application Support/com.tencent.xinWeChat"] {
            XCTAssertTrue(enabled.evaluate(data.appendingPathComponent(path)).canMigrate, path)
            XCTAssertNil(enabled.evaluate(data.appendingPathComponent(path)).partialSubdirectory, path)
        }
        for path in ["Documents/xwechat_files", "Documents/Other",
                     "Library/Caches/cache", "Library/Application Support/com.tencent.xinWeChat-other"] {
            XCTAssertFalse(enabled.evaluate(data.appendingPathComponent(path)).canMigrate, path)
            XCTAssertNil(enabled.evaluate(data.appendingPathComponent(path)).partialSubdirectory, path)
        }
        // "deeper" 这类未知子目录即使开启也不放行——白名单是封闭的。
        XCTAssertFalse(enabled.evaluate(data.appendingPathComponent("Documents/xwechat_files/account/deeper")).canMigrate)
        XCTAssertNil(enabled.evaluate(data.appendingPathComponent("Documents/xwechat_files/account/deeper")).partialSubdirectory)
    }

    // MARK: - 开启后：只放行白名单子目录

    func testEnabledAllowsOnlyWhitelistedSubdirectories() {
        let enabled = policy(enabled: true)
        for subpath in ["msg", "business"] {
            let decision = enabled.evaluate(account(subpath))
            XCTAssertTrue(decision.canMigrate, subpath)
            XCTAssertEqual(decision.partialSubdirectory, subpath)
        }
        for subpath in ["db_storage", "all_users", "config", "resource", "cache", "temp", "apm_record"] {
            let decision = enabled.evaluate(account(subpath))
            // 这些是启动与聊天记录的必要条件，体积小，一律不放行。
            XCTAssertFalse(decision.canMigrate, subpath)
            XCTAssertNil(decision.partialSubdirectory, subpath)
        }
    }

    func testEnabledDoesNotEscapeTheAccountDirectory() {
        let enabled = policy(enabled: true)
        let data = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        // 账号目录本身仍按原有白名单（可迁移），但不是拆分迁移放行。
        XCTAssertTrue(enabled.evaluate(account("")).canMigrate)
        XCTAssertNil(enabled.evaluate(account("")).partialSubdirectory)
        // 账号目录的父级与更深层级都不能被放行。
        XCTAssertFalse(enabled.evaluate(data.appendingPathComponent("Documents/xwechat_files")).canMigrate)
        XCTAssertFalse(enabled.evaluate(account("msg/attach")).canMigrate)
        XCTAssertFalse(enabled.evaluate(account("msg/attach/2026-10")).canMigrate)
        XCTAssertNil(enabled.evaluate(account("msg/attach")).partialSubdirectory)
    }

    func testEnabledDoesNotAffectOtherAppsOrContainers() {
        let enabled = policy(enabled: true)
        let other = home.appendingPathComponent("Library/Containers/com.other.app/Data/Documents/msg")
        XCTAssertTrue(enabled.evaluate(other).canMigrate, "非微信容器原本就允许")
        XCTAssertNil(enabled.evaluate(other).partialSubdirectory)

        // 微信的其它容器层级不受影响。
        let wechatData = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/msg")
        XCTAssertFalse(enabled.evaluate(wechatData).canMigrate)
        XCTAssertNil(enabled.evaluate(wechatData).partialSubdirectory)
    }

    func testExactLocksAreNotEscapedForOtherApps() {
        // 与 DataPathPolicyTests.testElevenExactLocksDoNotLockBusinessDescendants 同一组路径，
        // 但改用非微信 bundle id：微信容器内的这些层级本来就按 weChatCompatibility 锁死。
        let enabled = policy(enabled: true)
        let data = home.appendingPathComponent("Library/Containers/com.example.app/Data")
        for path in ["Documents", "Library", "Library/Application Scripts", "Library/Application Support",
                     "Library/Caches", "Library/Images", "Library/Logs", "Library/Preferences",
                     "Library/Saved Application State", "SystemData", "tmp"] {
            XCTAssertFalse(enabled.evaluate(data.appendingPathComponent(path)).canMigrate, path)
            XCTAssertNil(enabled.evaluate(data.appendingPathComponent(path)).partialSubdirectory, path)
            XCTAssertTrue(enabled.evaluate(data.appendingPathComponent(path + "/Business")).canMigrate, path)
            XCTAssertNil(enabled.evaluate(data.appendingPathComponent(path + "/Business")).partialSubdirectory, path)
        }
    }

    func testEnabledDoesNotAffectGroupContainers() {
        let enabled = policy(enabled: true)
        let group = home.appendingPathComponent("Library/Group Containers/group.app")
        XCTAssertFalse(enabled.evaluate(group).canMigrate)
        XCTAssertTrue(enabled.evaluate(group.appendingPathComponent("msg")).canMigrate)
        XCTAssertNil(enabled.evaluate(group.appendingPathComponent("msg")).partialSubdirectory,
                     "拆分迁移只针对微信普通容器，不放行 Group Containers 同名目录")
    }

    func testEnabledDoesNotTouchSystemManagedStructure() {
        let enabled = policy(enabled: true)
        let data = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        for path in ["Documents", "Library", "Library/Caches", "tmp"] {
            let decision = enabled.evaluate(data.appendingPathComponent(path))
            XCTAssertFalse(decision.canMigrate, path)
            XCTAssertNil(decision.partialSubdirectory, path)
        }
    }

    // MARK: - 路径匹配鲁棒性

    func testPathMatchingUsesComponentBoundaries() {
        let enabled = policy(enabled: true)
        // 前缀相似但不在当前 home 下的路径：容器外路径本就允许迁移（与
        // DataPathPolicyTests.testRootMatchingUsesActualHomeAndComponentBoundaries 一致），
        // 但拆分迁移绝不能放行它们。
        for path in ["/fixture/home-other/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/account/msg",
                     "/fixture/home/Library/ContainersExtra/com.tencent.xinWeChat/Data/Documents/xwechat_files/account/msg",
                     "/random/xwechat_files/account/msg"] {
            let decision = enabled.evaluate(URL(fileURLWithPath: path))
            XCTAssertNil(decision.partialSubdirectory, path)
        }
    }

    func testSimilarNamesInsideHomeAreNotEscaped() {
        // 真正位于 home 之下、但结构不符的路径，必须保持不可迁移。
        let enabled = policy(enabled: true)
        let data = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        for path in ["Documents/xwechat_files/account/msg/attach",
                     "Documents/xwechat_files/account/msg/attach/2026-10",
                     "Documents/xwechat_filesX/account/msg",
                     "Documents/xwechat_files/account/msgX",
                     "Documents/Other/account/msg"] {
            let decision = enabled.evaluate(data.appendingPathComponent(path))
            XCTAssertFalse(decision.canMigrate, path)
            XCTAssertNil(decision.partialSubdirectory, path)
        }
    }

    func testAnyAccountNameIsAccepted() {
        // 账号名不纳入匹配，任意 wxid 目录都适用。
        let enabled = policy(enabled: true)
        let data = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files")
        for account in ["wxid_abc123_220d", "account2", "wxid_mavf5gq8zzzc22"] {
            let decision = enabled.evaluate(data.appendingPathComponent(account).appendingPathComponent("msg"))
            XCTAssertTrue(decision.canMigrate, account)
            XCTAssertEqual(decision.partialSubdirectory, "msg", account)
        }
    }

    func testAlreadyMigratedPathsKeepTheirDecision() {
        // 已放行的路径（businessData）不经过补充判断，partialSubdirectory 保持 nil。
        let enabled = policy(enabled: true)
        let decision = enabled.evaluate(account(""))
        XCTAssertTrue(decision.canMigrate)
        XCTAssertNil(decision.partialSubdirectory)
        XCTAssertEqual(decision.role, .businessData)
    }

    func testRelocatableSubdirectoryLookupIsExact() {
        let policy = PartialWeChatMigrationPolicy(isEnabled: true)
        XCTAssertEqual(policy.relocatableSubdirectory(of: account("msg"), home: home), "msg")
        XCTAssertEqual(policy.relocatableSubdirectory(of: account("business"), home: home), "business")
        XCTAssertNil(policy.relocatableSubdirectory(of: account("db_storage"), home: home))
        XCTAssertNil(policy.relocatableSubdirectory(of: account(""), home: home))
        XCTAssertNil(policy.relocatableSubdirectory(of: account("msg/attach"), home: home))
    }
}
