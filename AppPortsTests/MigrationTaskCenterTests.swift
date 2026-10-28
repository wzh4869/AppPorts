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
}
