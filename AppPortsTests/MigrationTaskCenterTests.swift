import Foundation
import Testing
@testable import AppPorts

@MainActor
struct MigrationTaskCenterTests {
    @Test("A structured failure keeps one association across task display, history and diagnostics")
    func blockedTaskKeepsDiagnosticAssociation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let failure = OperationBlockage(reason: .signaturePreparation,
            applicationURL: fixture.root.appendingPathComponent("Example.app"),
            blockingOperationID: UUID(), blockingPhase: "prepared")
        fixture.center.submit(title: "Synthetic signature dependency", category: .apps, resources: fixture.resources,
            operation: { progress in
                progress.begin(.verifying)
                throw failure
            })
        let job = try #require(fixture.center.detail)
        let worker = try #require(job.worker)
        await worker.value
        #expect(job.status == .attention)
        #expect(job.message == failure.localizedDescription)
        #expect(fixture.history.load().first?.message == job.message)
        #expect(fixture.reopen().jobs.first?.message == job.message)
        let summary = try #require(AppLogger.shared.recentOperationSummariesSnapshot().last { $0.operationID == job.id.uuidString })
        #expect(summary.errorCode == failure.diagnosticCode)
        #expect(summary.details["failure_stage"] == "verifying")
        #expect(summary.details["attempt_id"].flatMap(UUID.init(uuidString:)) != nil)
        #expect(summary.details["cause_failure_id"] == failure.failureID.uuidString)
        #expect(summary.details["cause_blocking_operation_id"] == failure.blockingOperationID?.uuidString)
    }

    @Test("An explicit retry replaces the failed attempt in the list and saved history")
    func retryUpdatesTheOriginalTask() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let center = fixture.center
        var retry: MigrationJob.RetryToken?
        let id = center.submit(title: "Migrate payload", category: .appData, resources: fixture.resources,
            recovery: { _, token in retry = token }, operation: { progress in
                progress.begin(.switching)
                throw Failure.applicationRunning
            })
        let original = try #require(center.detail)
        let firstWorker = try #require(original.worker)
        await firstWorker.value
        #expect(original.status == .attention)
        #expect(original.fraction > 0)
        #expect(center.hasAttention)
        #expect(!fixture.state.isBusy)
        #expect(retry == nil, "Recovery requires an explicit user action")
        original.recoveryAction?()
        let token = try #require(retry)

        // Old controls can outlive their sheet; a retry must own fresh controls.
        original.control.pause()
        original.control.cancel()
        let retriedID = center.submit(title: original.title, category: original.category,
            resources: fixture.resources, retrying: token, operation: { _ in nil })
        let retried = try #require(center.detail)
        #expect(retriedID == id)
        #expect(center.jobs.count == 1)
        #expect(retried !== original)
        #expect(retried.retryToken != token)
        #expect(retried.status == .running)
        #expect(retried.message.isEmpty)
        #expect(retried.fraction == 0)
        #expect(retried.finishedAt == nil)
        #expect(retried.createdAt >= original.createdAt)
        #expect(retried.startedAt != nil)
        #expect(retried.progress !== original.progress)
        #expect(!retried.control.snapshot().pauseRequested)
        #expect(!retried.control.snapshot().cancelled)
        #expect(fixture.state.isBusy)
        #expect(!center.hasAttention)
        let savedRunning = try #require(fixture.history.load().first)
        #expect(savedRunning.id == id)
        #expect(savedRunning.status == .running)
        #expect(savedRunning.fraction == 0)

        let retryWorker = try #require(retried.worker)
        await retryWorker.value
        #expect(retried.status == .completed)
        #expect(retried.fraction == 1)
        #expect(!center.hasAttention)
        #expect(!fixture.state.isBusy)
        let saved = fixture.history.load()
        #expect(saved.count == 1)
        #expect(saved.first?.id == id)
        #expect(saved.first?.status == .completed)
        #expect(saved.first?.paused == false)

        let reopened = fixture.reopen()
        #expect(reopened.jobs.count == 1)
        #expect(reopened.jobs.first?.id == id)
        #expect(reopened.jobs.first?.status == .completed)
        #expect(reopened.jobs.first?.fraction == 1)
        #expect(reopened.jobs.first?.recoveryAction == nil)
        #expect(!reopened.hasAttention)
    }

    @Test("Duplicate or late retry callbacks cannot execute again")
    func staleRetryIsIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let center = fixture.center
        let original = try await fixture.fail()
        let token = original.retryToken
        center.submit(title: original.title, category: original.category,
            resources: fixture.resources, retrying: token, operation: { _ in nil })
        let retry = try #require(center.detail)
        #expect(!center.canRetry(token))

        // Both clicks happen before the worker gets its first turn.
        center.submit(title: original.title, category: original.category,
            resources: fixture.resources, retrying: token, operation: { _ in
                Issue.record("A repeated click executed a second operation")
                return nil
            })
        #expect(center.jobs.count == 1)
        #expect(center.detail === retry)
        let worker = try #require(retry.worker)
        await worker.value

        center.submit(title: original.title, category: original.category,
            resources: fixture.resources, retrying: token, operation: { _ in
                Issue.record("A completed task was retried by an old callback")
                return nil
            })
        #expect(center.detail === retry)
        #expect(retry.status == .completed)
        #expect(retry.worker == nil)
        center.removeFinished([retry.id])
        center.submit(title: original.title, category: original.category,
            resources: fixture.resources, retrying: token, operation: { _ in
                Issue.record("A removed task was recreated by an old callback")
                return nil
            })
        #expect(center.jobs.isEmpty)
        #expect(fixture.history.load().isEmpty)
    }

    @Test("A failed retry keeps its latest error and rejects the previous attempt's dialog")
    func aNewFailureInvalidatesTheOldRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try await fixture.fail()
        let center = fixture.center
        var nextRetry: MigrationJob.RetryToken?
        center.submit(title: original.title, category: original.category,
            resources: fixture.resources, retrying: original.retryToken,
            recovery: { _, token in nextRetry = token }, operation: { _ in throw Failure.offline })
        let failedRetry = try #require(center.detail)
        let worker = try #require(failedRetry.worker)
        await worker.value
        #expect(failedRetry.status == .attention)
        #expect(failedRetry.message == Failure.offline.localizedDescription)
        failedRetry.recoveryAction?()
        #expect(nextRetry == failedRetry.retryToken)
        #expect(center.canRetry(failedRetry.retryToken))
        #expect(!center.canRetry(original.retryToken))
        center.submit(title: original.title, category: original.category,
            resources: fixture.resources, retrying: original.retryToken, operation: { _ in
                Issue.record("A previous attempt's dialog retried a newer failure")
                return nil
            })
        #expect(center.detail === failedRetry)
        #expect(failedRetry.worker == nil)
        #expect(center.jobs.count == 1)
        #expect(fixture.history.load().first?.message == Failure.offline.localizedDescription)
    }

    @Test("A separate operation on the same paths does not rewrite a prior failure")
    func samePathsDoNotImplyARetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try await fixture.fail()
        let id = fixture.center.submit(title: original.title, category: original.category,
            resources: fixture.resources, operation: { _ in nil })
        let newJob = try #require(fixture.center.detail)
        let worker = try #require(newJob.worker)
        await worker.value
        #expect(id != original.id)
        #expect(fixture.center.jobs.count == 2)
        #expect(original.status == .attention)
        #expect(newJob.status == .completed)
    }

    @Test("A cleanup warning is still attention after retry and restart")
    func cleanupWarningDoesNotBecomeMigrationSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try await fixture.fail()
        fixture.center.submit(title: original.title, category: original.category,
            resources: fixture.resources, retrying: original.retryToken,
            operation: { _ in "Retained copy requires attention" })
        let retried = try #require(fixture.center.detail)
        let worker = try #require(retried.worker)
        await worker.value
        #expect(retried.status == .attention)
        #expect(retried.recoveryAction == nil, "Cleanup must use the ledger, not repeat the migration")
        #expect(fixture.reopen().jobs.first?.status == .attention)
    }

    @Test("Restarted history is display-only", arguments: [MigrationJob.Status.queued, .running, .attention])
    func interruptedHistoryNeverExecutes(status: MigrationJob.Status) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let job = MigrationJob(title: "Migrate payload", category: .appData, resources: fixture.resources)
        job.status = status
        job.restoredElapsed = 120
        job.restoredFraction = 0.88
        fixture.history.save([.init(job)])
        let center = fixture.reopen()
        center.schedule()
        let loaded = try #require(center.jobs.first)
        #expect(loaded.status == .attention)
        #expect(loaded.elapsed == 120)
        #expect(loaded.fraction == 0.88)
        #expect(loaded.worker == nil)
        #expect(loaded.operation == nil)
        #expect(loaded.recoveryAction == nil)
        #expect(!center.canRetry(job.retryToken), "Retry tokens do not survive process restart")
        #expect(!center.hasUnfinishedJobs)
    }

    private enum Failure: String, LocalizedError {
        case applicationRunning, offline
        var errorDescription: String? { rawValue }
    }

    @Test("Observed updates keep one persisted result without claiming migration execution")
    func observedUpdateHistoryAndControls() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let job = fixture.center.updateObserved(key: "update-request", title: "Update fixture", resources: fixture.resources,
            status: .running, message: "Copying")
        #expect(fixture.center.unfinishedCount == 1)
        let token = try #require(fixture.state.begin(), "Observed work must not block its worker's operation token")
        fixture.center.pause([job.id])
        fixture.center.cancel([job.id])
        #expect(!job.control.snapshot().pauseRequested)
        #expect(!job.control.snapshot().cancelled)
        #expect(job.worker == nil && job.operation == nil)
        fixture.state.finish(token)
        var rollbackCalls = 0
        fixture.center.updateObserved(key: "update-request", title: "Update fixture", resources: fixture.resources,
            status: .attention, message: "Failed", recovery: { rollbackCalls += 1 })
        fixture.center.updateObserved(key: "update-request", title: "Update fixture", resources: fixture.resources,
            status: .running, message: "Retrying")
        #expect(fixture.center.jobs.count == 1)
        #expect(fixture.center.jobs.first?.id == job.id)
        job.recoveryAction?()
        #expect(rollbackCalls == 1, "Rollback stays reachable during automatic retry")
        fixture.center.updateObserved(key: "update-request", title: "Update fixture", resources: fixture.resources,
            status: .completed, message: "Rolled back", result: .rolledBack)
        #expect(job.recoveryAction == nil)
        let loaded = try #require(fixture.reopen().jobs.first)
        #expect(loaded.observedKey == "update-request")
        #expect(loaded.observedResult == .rolledBack)
        #expect(loaded.message == "Rolled back")
        #expect(!loaded.supportsExecutionControls)
    }

    @Test("Existing history without observed fields still loads")
    func existingHistoryRemainsCompatible() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let job = MigrationJob(title: "Original history", category: .apps, resources: fixture.resources)
        job.status = .completed
        let encoded = try JSONEncoder().encode([MigrationTaskHistoryStore.Entry(job)])
        var entries = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        entries[0].removeValue(forKey: "observedKey")
        entries[0].removeValue(forKey: "observedResult")
        try JSONSerialization.data(withJSONObject: entries).write(to: fixture.root.appendingPathComponent("history.json"))
        let loaded = try #require(fixture.reopen().jobs.first)
        #expect(loaded.title == "Original history")
        #expect(loaded.supportsExecutionControls)
    }

    @Test("Conflicting unfinished operations on overlapping subjectPaths reuse the running job instead of queuing")
    func conflictingOperationOnSameSubjectOpensRunningJob() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = fixture.root.appendingPathComponent("xwechat_files/wxid_1")
        let member = account.appendingPathComponent("msg/file")
        let firstResources = MigrationResources(
            paths: [account, member, fixture.root.appendingPathComponent("WeChat.app")],
            keys: ["apfs-layout", "application:com.tencent.xinWeChat"],
            subjectPaths: [account, member]
        )
        let runningID = fixture.center.submit(
            title: "Migrate split",
            category: .appData,
            resources: firstResources,
            presentDetails: true,
            operation: { _ in
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw CancellationError()
            }
        )
        fixture.center.detailID = nil

        let reverseResources = MigrationResources(
            paths: [account, member, fixture.root.appendingPathComponent("WeChat.app")],
            keys: ["apfs-layout", "application:com.tencent.xinWeChat"],
            subjectPaths: [account, member]
        )
        let duplicateID = fixture.center.submit(
            title: "Restore split",
            category: .appData,
            resources: reverseResources,
            presentDetails: true,
            operation: { _ in
                Issue.record("Conflicting reverse task must not enqueue")
                return nil
            }
        )
        #expect(duplicateID == runningID)
        #expect(fixture.center.jobs.count == 1)
        #expect(fixture.center.detailID == runningID)
        fixture.center.cancel([runningID])
        await fixture.center.jobs.first?.worker?.value
    }

    @Test("Disjoint subjectPaths sharing lock keys still queue while row matching stays scoped")
    func disjointSubjectsSharingAppQueueCleanly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let appURL = fixture.root.appendingPathComponent("WeChat.app")
        let account1 = fixture.root.appendingPathComponent("xwechat_files/wxid_1")
        let account2 = fixture.root.appendingPathComponent("xwechat_files/wxid_2")
        let id1 = fixture.center.submit(
            title: "Migrate account 1",
            category: .appData,
            resources: MigrationResources(
                paths: [account1, appURL],
                keys: ["apfs-layout", "application:com.tencent.xinWeChat"],
                subjectPaths: [account1]
            ),
            operation: { _ in
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw CancellationError()
            }
        )
        let id2 = fixture.center.submit(
            title: "Migrate account 2",
            category: .appData,
            resources: MigrationResources(
                paths: [account2, appURL],
                keys: ["apfs-layout", "application:com.tencent.xinWeChat"],
                subjectPaths: [account2]
            ),
            operation: { _ in nil }
        )
        #expect(id1 != id2)
        #expect(fixture.center.jobs.count == 2)
        #expect(fixture.center.activeJob(overlappingSubject: [account1])?.id == id1)
        #expect(fixture.center.activeJob(overlappingSubject: [account2])?.id == id2)
        #expect(fixture.center.activeJob(overlappingAllPaths: [appURL])?.id == id1)
        #expect(fixture.center.jobs.first(where: { $0.id == id2 })?.badgeStatus == "等待中")
        fixture.center.cancel([id1])
        await fixture.center.jobs.first(where: { $0.id == id1 })?.worker?.value
        await fixture.center.jobs.first(where: { $0.id == id2 })?.worker?.value
        #expect(fixture.center.jobs.first(where: { $0.id == id2 })?.status == .completed)
    }

    @Test("Queued wait time is excluded from elapsed duration")
    func queuedWaitExcludedFromElapsedDuration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hold = try #require(fixture.state.begin())
        let id = fixture.center.submit(title: "Queued wait", category: .appData, resources: fixture.resources) { _ in
            try await Task.sleep(nanoseconds: 30_000_000)
            return nil
        }
        let job = try #require(fixture.center.jobs.first(where: { $0.id == id }))
        #expect(job.status == .queued)
        #expect(job.elapsed == 0)
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(job.elapsed == 0)
        fixture.state.finish(hold)
        fixture.center.schedule()
        await job.worker?.value
        #expect(job.status == .completed)
        let started = try #require(job.startedUptime)
        let finished = try #require(job.finishedAt)
        #expect(started >= job.createdAt)
        #expect(job.elapsed == finished - started)
    }

    @Test("Pause requested inside critical section does not persist as paused after completion")
    func pauseRequestedInCriticalSectionClearsOnCompletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = AsyncGate()
        let entered = AsyncGate()
        let id = fixture.center.submit(title: "Critical completion", category: .appData, resources: fixture.resources) { _ in
            MigrationExecution.control?.setCriticalSection(true)
            await entered.open()
            await gate.wait()
            MigrationExecution.control?.setCriticalSection(false)
            return nil
        }
        let job = try #require(fixture.center.jobs.first(where: { $0.id == id }))
        await entered.wait()
        fixture.center.pause([id])
        #expect(job.control.snapshot().pauseRequested)
        await gate.open()
        await job.worker?.value
        #expect(job.status == .completed)
        #expect(!job.restoredPaused)
        #expect(!job.control.snapshot().pauseRequested)
        #expect(MigrationTaskHistoryStore.Entry(job).paused == false)
        let reloaded = try #require(fixture.reopen().jobs.first(where: { $0.id == id }))
        #expect(reloaded.status == .completed)
        #expect(!reloaded.restoredPaused)
        #expect(reloaded.stateTitle == MigrationJob.Status.completed.title)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let history: MigrationTaskHistoryStore
        let state: AppOperationState
        let center: MigrationTaskCenter
        let resources: MigrationResources

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationTaskCenterTests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            history = MigrationTaskHistoryStore(fileURL: root.appendingPathComponent("history.json"))
            state = AppOperationState(notificationCenter: NotificationCenter())
            let lockURL = root.appendingPathComponent("operation.lock")
            center = MigrationTaskCenter(historyStore: history, operationState: state,
                makeOperationLock: { OperationLock(fileURL: lockURL, writerAdmissionCheck: {}) })
            resources = MigrationResources(paths: [root.appendingPathComponent("payload")])
        }

        func fail() async throws -> MigrationJob {
            center.submit(title: "Migrate payload", category: .appData, resources: resources,
                operation: { _ in throw Failure.applicationRunning })
            let job = try #require(center.detail)
            let worker = try #require(job.worker)
            await worker.value
            #expect(job.status == .attention)
            return job
        }

        func reopen() -> MigrationTaskCenter {
            let lockURL = root.appendingPathComponent("operation.lock")
            return MigrationTaskCenter(historyStore: history,
                operationState: AppOperationState(notificationCenter: NotificationCenter()),
                makeOperationLock: { OperationLock(fileURL: lockURL, writerAdmissionCheck: {}) })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private actor AsyncGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let ready = waiters
            waiters.removeAll()
            ready.forEach { $0.resume() }
        }
    }
}
