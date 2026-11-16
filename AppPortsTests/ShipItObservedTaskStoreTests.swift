import Foundation
import XCTest
@testable import AppPorts

final class ShipItObservedTaskStoreTests: XCTestCase {
    @MainActor
    func testLiveBackgroundPublisherKeepsRunningStatusAcrossColdHistoryLoad() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.save(candidate: fixture.candidate(), status: .running, message: "copying", result: nil, offersRollback: false)
        let entry = try XCTUnwrap(fixture.store.entries().first)
        XCTAssertTrue(WriterAdmission.matchesRunningProcess(try XCTUnwrap(entry.worker)))
        ShipItTaskObserver(store: fixture.store, taskCenter: fixture.center, defaults: fixture.defaults).refresh()
        XCTAssertEqual(fixture.center.jobs.first?.status, .running)
        XCTAssertEqual(fixture.center.jobs.first?.message, "copying")
        let reloaded = MigrationTaskCenter(historyStore: fixture.history, operationState: AppOperationState())
        XCTAssertEqual(reloaded.jobs.first?.status, .attention)
        ShipItTaskObserver(store: fixture.store, taskCenter: reloaded, defaults: fixture.defaults).refresh()
        XCTAssertEqual(reloaded.jobs.first?.status, .running)
        XCTAssertEqual(reloaded.jobs.first?.message, "copying")
        XCTAssertNil(reloaded.jobs.first?.recoveryAction)
    }

    @MainActor
    func testStaleRunningStateBecomesAttentionWithRollbackInsteadOfRestoringRunning() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let candidate = fixture.candidate()
        try fixture.store.save(candidate: candidate, status: .running, message: "copying", result: nil, offersRollback: false)
        let file = fixture.store.directory.appendingPathComponent(candidate.key + ".task.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        document.removeValue(forKey: "worker")
        try JSONSerialization.data(withJSONObject: document).write(to: file, options: .atomic)
        let observer = ShipItTaskObserver(store: fixture.store, taskCenter: fixture.center, defaults: fixture.defaults)
        observer.refresh()
        let job = try XCTUnwrap(fixture.center.jobs.first)
        XCTAssertEqual(job.status, .attention)
        XCTAssertTrue(job.message.contains("上次运行时更新接手未结束，等待检查更新现场。".localized))
        XCTAssertNotNil(job.recoveryAction)
        let reloaded = MigrationTaskCenter(historyStore: fixture.history, operationState: AppOperationState())
        ShipItTaskObserver(store: fixture.store, taskCenter: reloaded, defaults: fixture.defaults).refresh()
        XCTAssertEqual(reloaded.jobs.first?.status, .attention)
        XCTAssertNotNil(reloaded.jobs.first?.recoveryAction)
    }

    @MainActor
    func testBackgroundFailureRestoresRollbackActionAfterColdHistoryLoad() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let candidate = fixture.candidate()
        var rolledBack: ShipItUpdateRecovery.Candidate?
        let observer = ShipItTaskObserver(store: fixture.store, taskCenter: fixture.center, defaults: fixture.defaults,
            rollback: { rolledBack = $0 })
        try fixture.store.save(candidate: candidate, status: .attention, message: "failure", result: nil, offersRollback: true)
        observer.refresh()
        let failed = try XCTUnwrap(fixture.center.jobs.first)
        XCTAssertEqual(failed.status, .attention)
        XCTAssertNotNil(failed.recoveryAction)
        failed.recoveryAction?()
        while rolledBack == nil { await Task.yield() }
        XCTAssertEqual(rolledBack, candidate)
        let reloaded = MigrationTaskCenter(historyStore: fixture.history, operationState: AppOperationState())
        let coldObserver = ShipItTaskObserver(store: fixture.store, taskCenter: reloaded, defaults: fixture.defaults, rollback: { rolledBack = $0 })
        XCTAssertNil(reloaded.jobs.first?.recoveryAction)
        coldObserver.refresh()
        XCTAssertNotNil(reloaded.jobs.first?.recoveryAction)
        XCTAssertEqual(reloaded.jobs.count, 1)
        try fixture.store.save(candidate: candidate, status: .completed, message: "rolled back", result: .rolledBack, offersRollback: false)
        coldObserver.refresh()
        XCTAssertEqual(reloaded.jobs.first?.observedResult, .rolledBack)
        XCTAssertNil(reloaded.jobs.first?.recoveryAction)
    }

    @MainActor
    func testClearedCompletionDoesNotReappearButNewRevisionDoes() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let candidate = fixture.candidate()
        let observer = ShipItTaskObserver(store: fixture.store, taskCenter: fixture.center, defaults: fixture.defaults)
        try fixture.store.save(candidate: candidate, status: .completed, message: "recovered", result: .recovered, offersRollback: false)
        observer.refresh()
        XCTAssertEqual(fixture.center.jobs.count, 1)
        fixture.center.clearCompleted()
        observer.refresh()
        XCTAssertTrue(fixture.center.jobs.isEmpty)
        let reloaded = MigrationTaskCenter(historyStore: fixture.history, operationState: AppOperationState())
        let coldObserver = ShipItTaskObserver(store: fixture.store, taskCenter: reloaded, defaults: fixture.defaults)
        coldObserver.refresh()
        XCTAssertTrue(reloaded.jobs.isEmpty)
        try fixture.store.save(candidate: candidate, status: .attention, message: "new result", result: nil, offersRollback: true)
        coldObserver.refresh()
        XCTAssertEqual(reloaded.jobs.count, 1)
        XCTAssertEqual(reloaded.jobs.first?.message, "new result")
    }

    @MainActor
    func testNewBackgroundResultAppearsThroughActualDirectoryEvent() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let observer = ShipItTaskObserver(store: fixture.store, taskCenter: fixture.center, defaults: fixture.defaults)
        observer.start()
        defer { observer.stop() }
        try fixture.store.save(candidate: fixture.candidate(), status: .completed, message: "event result", result: .recovered, offersRollback: false)
        let deadline = Date().addingTimeInterval(5)
        while fixture.center.jobs.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(fixture.center.jobs.first?.message, "event result")
    }

    @MainActor
    func testDisplayStoreDoesNotReadOrRewriteInstallationReceipts() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.prepare()
        let receipt = fixture.store.directory.appendingPathComponent("installation.json")
        let bytes = Data("installation authority is separate".utf8)
        try bytes.write(to: receipt)
        let candidate = fixture.candidate()
        try fixture.store.save(candidate: candidate, status: .running, message: "copying", result: nil, offersRollback: false)
        XCTAssertEqual(try fixture.store.entries().count, 1)
        XCTAssertEqual(try Data(contentsOf: receipt), bytes)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let suite = "ShipItObserved-" + UUID().uuidString
        let store: ShipItObservedTaskStore
        let defaults: UserDefaults
        let history: MigrationTaskHistoryStore
        let center: MigrationTaskCenter

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ShipItObserved-" + UUID().uuidString)
            store = ShipItObservedTaskStore(directory: root.appendingPathComponent("shipit-recovery"))
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            history = MigrationTaskHistoryStore(fileURL: root.appendingPathComponent("history.json"))
            center = MigrationTaskCenter(historyStore: history, operationState: AppOperationState())
        }

        func candidate() -> ShipItUpdateRecovery.Candidate {
            let record = AppSearchRecord(name: "Fixture", localPath: root.appendingPathComponent("Local/Fixture.app").path,
                externalPath: root.appendingPathComponent("External/Fixture.app").path, expectsLocalEntry: true,
                targetBundleIdentifier: "org.appports.fixture")
            return .init(record: record, request: .init(updateBundleURL: root.appendingPathComponent("Cached/Fixture.app"),
                targetBundleURL: URL(fileURLWithPath: record.externalPath), bundleIdentifier: "org.appports.fixture", launchAfterInstallation: false),
                requestBytes: Data("unique update request".utf8), stateURL: root.appendingPathComponent("state.plist"))
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
