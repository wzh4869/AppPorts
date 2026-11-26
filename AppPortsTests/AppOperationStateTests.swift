import Combine
import XCTest
@testable import AppPorts

@MainActor
final class AppOperationStateTests: XCTestCase {
    func testDuplicateOperationsAreRejectedAndStaleCompletionCannotUnlockANewerOperation() throws {
        let state = AppOperationState()
        let first = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.isBusy)
        XCTAssertNil(state.begin())

        state.finish(UUID())
        XCTAssertTrue(state.isBusy)
        state.finish(first)
        XCTAssertFalse(state.isBusy)

        let second = try XCTUnwrap(state.begin())
        state.finish(first)
        XCTAssertTrue(state.isBusy)
        XCTAssertNil(state.begin())
        state.finish(second)
        XCTAssertFalse(state.isBusy)
    }
    func testQuitWaitsForReconciledCompletionAndRequestsCancellationOnce() throws {
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let token = try XCTUnwrap(state.begin())
        var cancelled = false
        var replied = false
        state.registerCancellation(for: token) { cancelled = true }
        XCTAssertTrue(state.finishBeforeTerminating { replied = true })
        XCTAssertTrue(cancelled)
        XCTAssertFalse(replied)
        XCTAssertNil(state.begin())
        state.finish(UUID())
        XCTAssertFalse(replied)
        state.finish(token)
        XCTAssertTrue(replied)
        XCTAssertFalse(state.isBusy)
    }

    func testIdleWindowsObserveCommittedStoreChanges() async throws {
        let center = NotificationCenter()
        let state = AppOperationState(notificationCenter: center)
        let refreshed = expectation(description: "Store commit refreshes an idle window")
        let subscription = state.$recordsRevision.dropFirst().sink { revision in
            if revision == 1 { refreshed.fulfill() }
        }
        center.post(name: .appPortsRecordsDidChange, object: nil)
        await fulfillment(of: [refreshed], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(state.recordsRevision, 1)
    }

    func testFinishingPublishesOnceEvenWithoutStoreNotification() throws {
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let token = try XCTUnwrap(state.begin())
        state.finish(token)
        state.finish(token)
        XCTAssertEqual(state.recordsRevision, 1)
    }

    func testNonMutatingFinishSkipsRecordsRevisionUnlessBackgroundChangeArrived() async throws {
        let center = NotificationCenter()
        let state = AppOperationState(notificationCenter: center)

        let first = try XCTUnwrap(state.begin())
        state.finish(first, publishRecordsChange: false)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.recordsRevision, 0)

        let second = try XCTUnwrap(state.begin())
        center.post(name: .appPortsRecordsDidChange, object: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.recordsRevision, 0)
        state.finish(second, publishRecordsChange: false)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.recordsRevision, 1)

        let third = try XCTUnwrap(state.begin())
        var replied = false
        XCTAssertTrue(state.finishBeforeTerminating { replied = true })
        state.finish(third, publishRecordsChange: false)
        XCTAssertTrue(replied)
        XCTAssertEqual(state.recordsRevision, 1)
    }

    func testNormalQuitCancelsARealDataCopyAndRepliesOnlyAfterItsRecoveryRecordIsSaved() async throws {
        for copies in [1, 4] {
            try await checkNormalQuitCancelsARealDataCopy(copies: copies)
        }
    }

    private func checkNormalQuitCancelsARealDataCopy(copies: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsQuit-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let source = home.appendingPathComponent("Payload")
        let external = root.appendingPathComponent("External")
        for directory in [source, external] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("first current document".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("second current document".utf8).write(to: source.appendingPathComponent("b.txt"))
        try Data("third current document".utf8).write(to: source.appendingPathComponent("c.txt"))
        try Data("fourth current document".utf8).write(to: source.appendingPathComponent("d.txt"))
        try Data("not started after quit".utf8).write(to: source.appendingPathComponent("z.txt"))
        let original = try TreeCopySession.snapshot(at: source)
        let ledger = root.appendingPathComponent("records.plist")
        let store = ContainerMountStore(fileURL: ledger)
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let observation = QuitObservation(state: state)
        let token = try XCTUnwrap(state.begin())
        let item = DataDirItem(name: "Payload", path: source, type: .applicationSupport,
            priority: .critical, description: "Quit validation fixture", status: DataDirStatus.local)
        let job = try XCTUnwrap(state.startTask(for: token) {
            defer { state.finish(token) }
            do {
                _ = try await TreeCopySession.$concurrentSmallFileCopies.withValue(copies) {
                    try await DataDirMover(homeDir: home, store: store).migrateAndComplete(item: item, to: external) { progress in
                        if progress.currentFile == "a.txt" {
                            do {
                                let saved = ContainerMountStore(fileURL: ledger)
                                let pending = try XCTUnwrap(saved.transfers().first)
                                let partial = URL(fileURLWithPath: try XCTUnwrap(pending.preparationPath))
                                let completed = copies == 1 ? ["a.txt"] : ["a.txt", "b.txt", "c.txt", "d.txt"]
                                for name in completed {
                                    XCTAssertEqual(try Data(contentsOf: partial.appendingPathComponent(name)),
                                                   try Data(contentsOf: source.appendingPathComponent(name)))
                                }
                                if copies == 1 {
                                    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.appendingPathComponent("b.txt").path))
                                }
                                XCTAssertFalse(FileManager.default.fileExists(atPath: partial.appendingPathComponent("z.txt").path))
                            } catch {
                                XCTFail("Cannot inspect the first copy callback: \(error)")
                            }
                            await observation.requestQuit()
                        }
                    }
                }
                XCTFail("The copy must stop at cancellation before switching the live source")
            } catch {
                observation.recoveryWasSaved = (try? store.transfers().first?.isPreparationRecoverable) == true
            }
        })
        await job.value

        XCTAssertTrue(observation.requestedQuit)
        XCTAssertTrue(observation.replyFollowedRecoverySave)
        XCTAssertTrue(observation.didReply)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(try TreeCopySession.snapshot(at: source), original)
        let reopened = ContainerMountStore(fileURL: ledger)
        let pending = try XCTUnwrap(reopened.transfers().first)
        XCTAssertTrue(pending.isPreparationRecoverable)
        XCTAssertNil(pending.baseline)
        XCTAssertFalse(pending.isDataSwitchComplete)
        let partial = URL(fileURLWithPath: try XCTUnwrap(pending.preparationPath))
        XCTAssertEqual(try Data(contentsOf: partial.appendingPathComponent("a.txt")),
                       try Data(contentsOf: source.appendingPathComponent("a.txt")))
        if copies == 1 {
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.appendingPathComponent("b.txt").path))
        } else {
            // A batch joins its writes before the first ordered callback. Quit
            // must stop the next batch rather than discard completed siblings.
            for name in ["b.txt", "c.txt", "d.txt"] {
                XCTAssertEqual(try Data(contentsOf: partial.appendingPathComponent(name)),
                               try Data(contentsOf: source.appendingPathComponent(name)))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.appendingPathComponent("z.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("Payload").path))
        let stopped = try TreeCopySession.snapshot(at: partial)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(try TreeCopySession.snapshot(at: partial), stopped)

        try await DataDirMover(homeDir: home, store: reopened).cancelPreparation(operationID: pending.operationID)
        XCTAssertTrue(try reopened.transfers().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try TreeCopySession.snapshot(at: source), original)
    }

    @MainActor
    private final class QuitObservation {
        let state: AppOperationState
        var requestedQuit = false
        var recoveryWasSaved = false
        var didReply = false
        var replyFollowedRecoverySave = false

        init(state: AppOperationState) { self.state = state }

        func requestQuit() {
            guard !requestedQuit else { return }
            requestedQuit = true
            XCTAssertTrue(state.finishBeforeTerminating {
                self.didReply = true
                self.replyFollowedRecoverySave = self.recoveryWasSaved
            })
            XCTAssertFalse(didReply)
            XCTAssertTrue(state.isBusy)
            XCTAssertNil(state.begin())
        }
    }
}
