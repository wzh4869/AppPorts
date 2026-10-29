import Darwin
import XCTest
@testable import AppPorts

final class PartialWeChatMigrationPolicyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture/home")
    private var account: URL { PartialWeChatMigrationPolicy(homeDirectory: home).accountsRoot.appendingPathComponent("wxid_account") }

    func testDisabledPolicyKeepsExistingWhitelist() {
        let policy = DataPathPolicy(homeDirectory: home, partialWeChatMigrationEnabled: false)
        XCTAssertTrue(policy.evaluate(account).canMigrate)
        XCTAssertFalse(policy.evaluate(account).mayDiscoverChildren)
        for name in ["msg", "business", "db_storage", "config", "resource"] {
            XCTAssertFalse(policy.evaluate(account.appendingPathComponent(name)).canMigrate, name)
        }
    }

    func testEnabledPolicyOnlyAllowsExactMediaMembers() {
        let policy = DataPathPolicy(homeDirectory: home, partialWeChatMigrationEnabled: true)
        for name in ["msg", "business"] {
            let decision = policy.evaluate(account.appendingPathComponent(name))
            XCTAssertTrue(decision.canMigrate)
            XCTAssertTrue(decision.partialSubdirectory)
            XCTAssertFalse(decision.mayDiscoverChildren)
        }
        for name in ["db_storage", "config", "resource", "all_users", "msg_other", "business/deeper", "msg/deeper"] {
            XCTAssertFalse(policy.evaluate(account.appendingPathComponent(name)).canMigrate, name)
        }
        XCTAssertTrue(policy.evaluate(account).mayDiscoverChildren)
        XCTAssertFalse(policy.evaluate(account).partialSubdirectory)
    }

    func testSpecialSharedDirectoriesAreNotAccounts() {
        let policy = PartialWeChatMigrationPolicy(homeDirectory: home)
        for name in ["all_users", "config", "resource"] {
            let shared = policy.accountsRoot.appendingPathComponent(name)
            XCTAssertFalse(policy.isAccount(shared))
            XCTAssertFalse(policy.isAccount(shared.appendingPathComponent(".")))
            XCTAssertNil(policy.account(forMember: shared.appendingPathComponent("msg")))
        }
    }

    func testOtherContainersAndGroupContainersAreUnaffected() {
        let enabled = DataPathPolicy(homeDirectory: home, partialWeChatMigrationEnabled: true)
        let disabled = DataPathPolicy(homeDirectory: home, partialWeChatMigrationEnabled: false)
        for relative in ["Library/Containers/com.other.app/Data/Documents/xwechat_files/account/msg",
                         "Library/Group Containers/com.tencent.xinWeChat/Data/Documents/account/business",
                         "Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat"] {
            let url = home.appendingPathComponent(relative)
            XCTAssertEqual(enabled.evaluate(url), disabled.evaluate(url))
        }
        let matching = PartialWeChatMigrationPolicy(homeDirectory: home)
        XCTAssertFalse(matching.isAccount(URL(fileURLWithPath: account.path + "-other/deeper")))
        XCTAssertNil(matching.account(forMember: URL(fileURLWithPath: account.path.replacingOccurrences(of: "/fixture/home/", with: "/fixture/home-other/") + "/msg")))
    }

    func testAliasCannotExposeDatabaseAsMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = PartialWeChatMigrationPolicy(homeDirectory: root).accountsRoot.appendingPathComponent("wxid_test")
        let database = account.appendingPathComponent("db_storage")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let media = account.appendingPathComponent("msg")
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: database)
        XCTAssertFalse(DataPathPolicy(homeDirectory: root, partialWeChatMigrationEnabled: true).evaluate(media).canMigrate)
    }

    func testOfflineReadAccessOnlyMatchesExactMediaInTheSelectedContainer() {
        for identifier in [PartialWeChatMigrationPolicy.bundleIdentifier, "com.tencent.xinWeChat.dual"] {
            let policy = PartialWeChatMigrationPolicy(homeDirectory: home, containerIdentifier: identifier)
            let account = policy.accountsRoot.appendingPathComponent("wxid_fixture")
            for member in ["msg", "business"] {
                XCTAssertTrue(policy.allowsOfflineReadAccess(at: account.appendingPathComponent(member)))
            }
            for relative in ["", "db_storage", "config", "msg/deeper", "business/deeper"] {
                XCTAssertFalse(policy.allowsOfflineReadAccess(at: account.appendingPathComponent(relative)))
            }
            for shared in ["all_users", "config", "resource"] {
                XCTAssertFalse(policy.allowsOfflineReadAccess(at: policy.accountsRoot.appendingPathComponent(shared + "/msg")))
            }
            XCTAssertFalse(policy.allowsOfflineReadAccess(at: home.appendingPathComponent("staging/msg")))
        }
        let dual = PartialWeChatMigrationPolicy(homeDirectory: home, containerIdentifier: "com.tencent.xinWeChat.dual")
        XCTAssertFalse(dual.allowsOfflineReadAccess(at: account.appendingPathComponent("msg")))
    }

    func testOfflineReadAccessRejectsMediaAndAccountAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = PartialWeChatMigrationPolicy(homeDirectory: root)
        let account = policy.accountsRoot.appendingPathComponent("wxid_fixture")
        let media = account.appendingPathComponent("msg")
        for target in [account.appendingPathComponent("db_storage"), account.appendingPathComponent("business"), root.appendingPathComponent("outside")] {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: media, withDestinationURL: target)
            XCTAssertFalse(policy.allowsOfflineReadAccess(at: media))
            try FileManager.default.removeItem(at: media)
        }
        let alias = policy.accountsRoot.appendingPathComponent("wxid_alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: account)
        XCTAssertFalse(policy.allowsOfflineReadAccess(at: alias.appendingPathComponent("business")))
    }

    func testAppListIdentityIgnoresUUIDSizeAndRunningUpdates() {
        var first = AppItem(name: "WeChat.app", path: account, status: "本地")
        var next = AppItem(name: "WeChat.app", path: account, status: "本地")
        first.version = "4.1"
        next.version = "4.1"
        next.size = "20 GB"
        next.sizeBytes = 20_000_000_000
        next.isRunning = true
        XCTAssertEqual(first.id, next.id)
        XCTAssertEqual(AppDataScanIdentity(first), AppDataScanIdentity(next))
        next.version = "4.2"
        XCTAssertNotEqual(AppDataScanIdentity(first), AppDataScanIdentity(next))
    }

    func testUnchangedStoreDoesNotWriteOrNotifyAgain() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let record = fixture.record(at: fixture.account)
        try fixture.store.upsert(record)
        let noChange = expectation(description: "No event for an unchanged record")
        noChange.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: .appPortsRecordsDidChange,
            object: fixture.store, queue: nil) { _ in noChange.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        try fixture.store.upsert(record)
        try fixture.store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: nil)
        wait(for: [noChange], timeout: 0.1)
    }

    func testWholeAndSplitModesRejectOverlapsBeforeDiskCommands() async throws {
        for whole in [true, false] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            try fixture.store.upsert(fixture.record(at: whole ? fixture.account : fixture.account.appendingPathComponent("msg")))
            let service = fixture.service()
            XCTAssertEqual(try service.state(of: fixture.account), whole ? .whole : .split)
            do {
                _ = try await service.migrate(account: fixture.account, mode: whole ? .split : .whole,
                    externalRoot: fixture.external, appName: "WeChat")
                XCTFail("Mode switch must require restoration")
            } catch WeChatAccountMigrationService.Failure.restoreFirst {}
            XCTAssertTrue(fixture.runner.calls.isEmpty)
        }
    }

    func testSplitCoordinatesBothFakeMountsAndRestoresWhenDisabled() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let service = fixture.service()
        let database = fixture.account.appendingPathComponent("db_storage/payload")
        let before = try DataPathIdentity.capture(database)
        let warnings = try await service.migrate(account: fixture.account, mode: .split,
            externalRoot: fixture.external, appName: "WeChat")
        XCTAssertTrue(warnings.isEmpty, warnings.joined(separator: "\n"))
        XCTAssertEqual(try fixture.store.recordsStrict().count, 2)
        XCTAssertEqual(try service.state(of: fixture.account), .split)
        XCTAssertEqual(try DataPathIdentity.capture(database), before)
        XCTAssertEqual(try Data(contentsOf: database), Data("database".utf8))
        let restored = try await fixture.service(enabled: false).restoreSplit(account: fixture.account)
        XCTAssertTrue(restored.isEmpty, restored.joined(separator: "\n"))
        XCTAssertTrue(try fixture.store.recordsStrict().isEmpty)
        XCTAssertEqual(try service.state(of: fixture.account), .local)
        for member in ["msg", "business"] {
            XCTAssertEqual(try String(contentsOf: fixture.account.appendingPathComponent(member + "/payload"), encoding: .utf8), member)
        }
    }

    func testInterruptedSplitResumesOnlyTheRemainingMember() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        await fixture.driver.failNextMigration(of: "business")
        do {
            _ = try await fixture.service().migrate(account: fixture.account, mode: .split,
                externalRoot: fixture.external, appName: "WeChat")
            XCTFail("Expected the second member to fail")
        } catch DataOperationSafety.Failure.inspection {}
        XCTAssertEqual(try fixture.store.recordsStrict().count, 1)
        XCTAssertEqual(try fixture.service().state(of: fixture.account), .split)
        _ = try await fixture.service().migrate(account: fixture.account, mode: .split,
            externalRoot: URL(fileURLWithPath: fixture.external.path, isDirectory: true), appName: "WeChat")
        XCTAssertEqual(try fixture.store.recordsStrict().count, 2)
        let members = await fixture.driver.migratedMembers
        XCTAssertEqual(members, ["msg", "business"], "The completed member must not be copied again")
    }

    func testModeSwitchIsAllowedOnlyAfterCompleteRestoration() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.migrate(account: fixture.account, mode: .split,
            externalRoot: fixture.external, appName: "WeChat")
        do {
            _ = try await service.migrate(account: fixture.account, mode: .whole,
                externalRoot: fixture.external, appName: "WeChat")
            XCTFail("Split migration must first be restored")
        } catch WeChatAccountMigrationService.Failure.restoreFirst {}
        _ = try await service.restoreSplit(account: fixture.account)
        _ = try await service.migrate(account: fixture.account, mode: .whole,
            externalRoot: fixture.external, appName: "WeChat")
        XCTAssertEqual(try service.state(of: fixture.account), .whole)
        do {
            _ = try await service.migrate(account: fixture.account, mode: .split,
                externalRoot: fixture.external, appName: "WeChat")
            XCTFail("Whole-account migration must first be restored")
        } catch WeChatAccountMigrationService.Failure.restoreFirst {}
    }

    func testDisabledSplitFailsBeforeCallingDriver() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        do {
            _ = try await fixture.service(enabled: false).migrate(account: fixture.account, mode: .split,
                externalRoot: fixture.external, appName: "WeChat")
            XCTFail("The feature defaults to disabled")
        } catch WeChatAccountMigrationService.Failure.disabled {}
        XCTAssertTrue(try fixture.store.recordsStrict().isEmpty)
    }

    func testGroupedMediaSizeExcludesLocalDatabase() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = DataDirItem(name: "Account", path: fixture.account, type: .containers,
                                  priority: .critical, description: "")
        let members = PartialWeChatMigrationPolicy(homeDirectory: fixture.home).members(of: fixture.account).map { url in
            var item = DataDirItem(name: url.lastPathComponent, path: url, type: .containers,
                                   priority: .critical, description: "")
            item.status = DataDirStatus.mounted
            return item
        }
        let rows = WeChatAccountMigrationService.groupedItems([account] + members, homeDirectory: fixture.home)
        let row = try XCTUnwrap(rows.first)
        let measured = measureDataDirectorySize(for: row)
        XCTAssertTrue(measured.isComplete)
        XCTAssertEqual(measured.bytes, Int64("msg".utf8.count + "business".utf8.count))
        XCTAssertNil(row.sizeMeasurementURL, "The account root must not count local databases as external data")
    }

    func testRestoredMemberWithPendingCleanupDoesNotLookUnmounted() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var member = DataDirItem(name: "msg", path: fixture.account.appendingPathComponent("msg"), type: .containers,
                                 priority: .critical, description: "")
        member.hasMountTransferRecord = true
        member.recoveryOperationID = UUID()
        member.status = DataDirStatus.local
        let rows = WeChatAccountMigrationService.groupedItems([member], homeDirectory: fixture.home)
        XCTAssertEqual(try XCTUnwrap(rows.first).status, DataDirStatus.pendingCompletion)
    }

    func testMissingMemberFailsBeforeMovingEitherDirectory() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.account.appendingPathComponent("business"))
        do {
            _ = try await fixture.service().migrate(account: fixture.account, mode: .split,
                externalRoot: fixture.external, appName: "WeChat")
            XCTFail("Both members must pass preflight")
        } catch {}
        XCTAssertTrue(fixture.runner.calls.isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.account.appendingPathComponent("msg/payload"), encoding: .utf8), "msg")
    }

    private final class Fixture {
        let root: URL
        let home: URL
        let account: URL
        let external: URL
        let store: ContainerMountStore
        let runner = FakeDiskCommandRunner()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatSplitTests-" + UUID().uuidString).resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            account = PartialWeChatMigrationPolicy(homeDirectory: home).accountsRoot.appendingPathComponent("wxid_test")
            external = root.appendingPathComponent("External")
            store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"))
            for member in ["msg", "business", "db_storage"] {
                let folder = account.appendingPathComponent(member)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data((member == "db_storage" ? "database" : member).utf8).write(to: folder.appendingPathComponent("payload"))
            }
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            runner.hideContentsOnUnmount()
        }
        func record(at source: URL) -> ContainerMountRecord {
            ContainerMountRecord(appName: "WeChat", bundleIdentifier: PartialWeChatMigrationPolicy.bundleIdentifier,
                dataDirType: DataDirType.containers.rawValue, mountPointPath: source.path,
                volumeUUID: "SYNTHETIC-UUID", volumeName: "Synthetic", externalRootPath: external.path)
        }
        lazy var driver = FakeAccountMountDriver(store: store, runner: runner)
        func service(enabled: Bool = true) -> WeChatAccountMigrationService {
            WeChatAccountMigrationService(homeDirectory: home, store: store, migrator: driver, enabled: enabled)
        }
        func cleanup() {
            // Only this synthetic fixture's directories are ever touched.
            let urls = [root] + runner.stashedVolumeContents
            for url in urls {
                _ = chmod(url.path, 0o700)
                if let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let child as URL in iterator { _ = chmod(child.path, 0o700) }
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    /// Models the mount-driver contract only. Real copy/verification/cleanup is
    /// covered separately by ContainerVolumeMigratorTests.completedMountRoundTrips.
    private actor FakeAccountMountDriver: WeChatAccountMountDriving {
        let store: ContainerMountStore
        let runner: FakeDiskCommandRunner
        var migratedMembers: [String] = []
        private var failedMember: String?
        func failNextMigration(of member: String) { failedMember = member }
        init(store: ContainerMountStore, runner: FakeDiskCommandRunner) { self.store = store; self.runner = runner }
        func migrateAndComplete(item: DataDirItem, externalRootURL: URL, appName: String,
                                bundleIdentifier: String?, progressHandler: FileCopier.ProgressHandler?) async throws -> ContainerVolumeMigrator.MigrationResult {
            if failedMember == item.path.lastPathComponent {
                failedMember = nil
                throw DataOperationSafety.Failure.inspection(item.path.path)
            }
            migratedMembers.append(item.path.lastPathComponent)
            let record = ContainerMountRecord(appName: appName, bundleIdentifier: bundleIdentifier,
                dataDirType: item.type.rawValue, mountPointPath: item.path.path, volumeUUID: UUID().uuidString,
                volumeName: "Synthetic", externalRootPath: externalRootURL.path)
            try store.upsert(record)
            runner.markVolumeMounted(record.volumeUUID, at: item.path.path)
            return .init(record: record, cleanupWarning: nil, operationID: UUID())
        }
        func restoreAndComplete(record: ContainerMountRecord, estimatedTotalBytes: Int64,
                                progressHandler: FileCopier.ProgressHandler?) async throws -> ContainerVolumeMigrator.CleanupWarning? {
            try store.remove(mountPointPath: record.mountPointPath)
            return nil
        }
        func mount(record: ContainerMountRecord) async throws { runner.markVolumeMounted(record.volumeUUID, at: record.mountPointPath) }
        func cancelPreparation(operationID: UUID, preserveUnclaimedMaterials: Bool) async throws {
            XCTFail("Unexpected cancellation in a completed fixture")
        }
        func resumeVerifiedTransfer(operationID: UUID, progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
            XCTFail("Unexpected transfer recovery in a completed fixture")
            return nil
        }
    }

}
