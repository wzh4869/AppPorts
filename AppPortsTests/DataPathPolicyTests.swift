import XCTest
@testable import AppPorts

final class DataPathPolicyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture/home")

    func testElevenExactLocksDoNotLockBusinessDescendants() {
        let policy = DataPathPolicy(homeDirectory: home)
        let data = home.appendingPathComponent("Library/Containers/com.example.app/Data")
        for path in ["Documents", "Library", "Library/Application Scripts", "Library/Application Support",
                     "Library/Caches", "Library/Images", "Library/Logs", "Library/Preferences",
                     "Library/Saved Application State", "SystemData", "tmp"] {
            XCTAssertFalse(policy.evaluate(data.appendingPathComponent(path)).canMigrate, path)
            XCTAssertTrue(policy.evaluate(data.appendingPathComponent(path + "/Business")).canMigrate, path)
        }
        XCTAssertFalse(policy.evaluate(data).canMigrate)
        XCTAssertFalse(policy.evaluate(data.deletingLastPathComponent()).canMigrate)
    }

    func testRootMatchingUsesActualHomeAndComponentBoundaries() {
        let policy = DataPathPolicy(homeDirectory: home)
        for path in ["/random/Containers/app/Data/Library", "/fixture/home-other/Library/Containers/app/Data",
                     "/fixture/home/Library/ContainersExtra/app/Data"] {
            XCTAssertTrue(policy.evaluate(URL(fileURLWithPath: path)).canMigrate, path)
        }
        let group = home.appendingPathComponent("Library/Group Containers/group.app")
        XCTAssertEqual(policy.evaluate(group).role, .groupContainerRoot)
        XCTAssertFalse(policy.evaluate(group).canMigrate)
        XCTAssertTrue(policy.evaluate(group.appendingPathComponent("Data")).canMigrate)
    }

    func testWeChatWhitelistIsUnchangedAndExact() {
        let policy = DataPathPolicy(homeDirectory: home)
        let data = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        for path in ["Documents/xwechat_files/account", "Library/Application Support/com.tencent.xinWeChat"] {
            XCTAssertTrue(policy.evaluate(data.appendingPathComponent(path)).canMigrate, path)
        }
        for path in ["Documents/xwechat_files", "Documents/Other", "Documents/xwechat_files/account/deeper",
                     "Library/Caches/cache", "Library/Application Support/com.tencent.xinWeChat-other"] {
            XCTAssertFalse(policy.evaluate(data.appendingPathComponent(path)).canMigrate, path)
        }
    }

    func testActualAliasCannotBypassStructuralProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let realHome = root.appendingPathComponent("home")
        let data = realHome.appendingPathComponent("Library/Containers/com.example.app/Data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: data)
        let policy = DataPathPolicy(homeDirectory: realHome)
        XCTAssertFalse(policy.evaluate(alias).canMigrate)
        XCTAssertFalse(policy.evaluate(alias).mayDiscoverChildren)
    }

    func testRecoveryAndVisibilityAreIndependentOfMigrationPermission() {
        var item = DataDirItem(name: "Data", path: home, type: .containers, priority: .critical, description: "", isMigratable: false)
        item.applySize(DirectorySizeResult(bytes: 0))
        for status in [DataDirStatus.linked, DataDirStatus.needsNormalization, DataDirStatus.mounted,
                       DataDirStatus.pendingMount, DataDirStatus.volumeMissing] {
            item.status = status
            XCTAssertTrue(item.canRestore, status)
            XCTAssertTrue(item.matchesVisibility(showZeroByteDirectories: false, showLockedStructure: false), status)
        }
        item.status = DataDirStatus.local
        XCTAssertFalse(item.canRestore)
        for zeros in [false, true] {
            for locked in [false, true] {
                XCTAssertEqual(item.matchesVisibility(showZeroByteDirectories: zeros, showLockedStructure: locked), locked)
            }
        }
    }
}
