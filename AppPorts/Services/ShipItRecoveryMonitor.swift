import AppKit
import Combine
import Foundation

/// Event-driven recovery stays alive independently of the visible page.
@MainActor
final class ShipItRecoveryMonitor {
    static let shared = ShipItRecoveryMonitor()
    private let recovery: ShipItUpdateRecovery
    private let injected: Bool
    private let interval: UInt64
    private let debounce: UInt64
    private let eventLatency: TimeInterval
    private let operationState: AppOperationState
    private let workspaceCenter: NotificationCenter
    private let startEvents: (ShipItUpdateEventMonitor, Set<String>) -> Bool
    private let didStartListening: () throws -> Void
    private let didCheck: (() -> Void)?
    private let taskCenter: MigrationTaskCenter?
    private let observedStore: ShipItObservedTaskStore?
    private let logContext: @Sendable (String, [(String, String?)], String) -> Void
    private var events: ShipItUpdateEventMonitor?
    private var observers: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var started = false
    private var listenerReady = false
    private var startupRetryDelay: UInt64 = 1_000_000_000
    private var needsCheck = false
    private var recovering = false
    private var identifiers: Set<String> = []
    private var lastMonitoredCount: Int?
    private var reportedSkips: [String: ShipItUpdateRecovery.SkipObservation] = [:]
    private var suppressed: Set<String> = []
    private var activeCandidateKey: String?
    private var failures: [String: String] = [:]
    private var rejectedPackages: [String: DataPathIdentity] = [:]
    private var unfinished: [String: ShipItUpdateRecovery.Candidate] = [:]

    init(recovery: ShipItUpdateRecovery? = nil, interval: UInt64 = 5_000_000_000,
         operationState: AppOperationState? = nil, debounce: UInt64 = 1_000_000_000,
         eventLatency: TimeInterval = 1, workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         didCheck: (() -> Void)? = nil, taskCenter: MigrationTaskCenter? = nil,
         observedStore: ShipItObservedTaskStore? = nil,
         startEvents: @escaping (ShipItUpdateEventMonitor, Set<String>) -> Bool = { $0.start(identifiers: $1) },
         didStartListening: @escaping () throws -> Void = {},
         logContext: @escaping @Sendable (String, [(String, String?)], String) -> Void = {
             AppLogger.shared.logContext($0, details: $1, level: $2)
         }) {
        self.recovery = recovery ?? ShipItUpdateRecovery(); injected = recovery != nil
        self.interval = interval; self.debounce = debounce; self.eventLatency = eventLatency
        self.operationState = operationState ?? .shared
        self.workspaceCenter = workspaceCenter; self.didCheck = didCheck
        self.startEvents = startEvents
        self.didStartListening = didStartListening
        self.logContext = logContext
        self.taskCenter = taskCenter ?? (recovery == nil ? .shared : nil)
        self.observedStore = observedStore ?? (recovery == nil ? ShipItObservedTaskStore() : nil)
    }

    func start() {
        guard !started else { return }
        if !injected {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
                  NSClassFromString("XCTestCase") == nil else { return }
        }
        started = true
        listenerReady = false
        startupRetryDelay = 1_000_000_000
        events = ShipItUpdateEventMonitor(caches: recovery.cacheDirectory, latency: eventLatency,
            watchedFiles: [recovery.records.storageURL]) { [weak self] in
            Task { @MainActor [weak self] in self?.requestCheck() }
        }
        operationState.$recordsRevision.dropFirst().sink { [weak self] _ in
            guard let self, !self.recovering else { return }
            self.requestCheck()
        }.store(in: &observers)
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceCenter.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.requestCheck()
            }.store(in: &observers)
        }
        workspaceCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let identifier = app.bundleIdentifier, self.identifiers.contains(identifier) else { return }
                self.requestCheck()
            }.store(in: &observers)
        requestCheck(after: 0)
    }

    private func requestCheck(after delay: UInt64? = nil) {
        guard started else { return }
        scheduled?.cancel()
        scheduled = nil
        if task != nil { needsCheck = true; return }
        let wait = delay ?? debounce
        scheduled = Task {
            if wait > 0 {
                do { try await Task.sleep(nanoseconds: wait) } catch { return }
            }
            guard !Task.isCancelled else { return }
            scheduled = nil
            check()
        }
    }

    private func check() {
        guard started, task == nil else { return }
        task = Task {
            var retry = false
            do {
                let worker = recovery
                identifiers = try await Task.detached(priority: .utility) { try worker.monitoredBundleIdentifiers() }.value
                try Task.checkCancellation()
                if lastMonitoredCount != identifiers.count {
                    lastMonitoredCount = identifiers.count
                    logContext("更新守护监听名单已更新", [("monitored_count", String(identifiers.count))], "TRACE")
                }
                updateListener()
                let scan = try await Task.detached(priority: .utility) { try worker.scanCandidates() }.value
                let candidates = scan.candidates
                recordSkips(scan.skips)
                let rollbacks = try await Task.detached(priority: .utility) { try worker.pendingRollbacks() }.value
                rejectedPackages = rejectedPackages.filter { key, _ in candidates.contains { $0.key == key } }
                for pending in rollbacks {
                    guard !Task.isCancelled else { break }
                    let candidate = pending.candidate
                    if pending.automatic {
                        if !(await recover(candidate, automaticRollback: true)) { retry = true }
                    } else {
                        suppressed.insert(candidate.key)
                        display(candidate, status: .attention,
                                message: "回退尚未完成，可重试回退更新。".localized, offerRollback: true)
                    }
                }
                for candidate in candidates where !suppressed.contains(candidate.key) {
                    guard !Task.isCancelled else { break }
                    activeCandidateKey = candidate.key
                    if !(await recover(candidate)) { retry = true }
                    activeCandidateKey = nil
                    if operationState.isBusy { break }
                }
            } catch is CancellationError {
                // A stopped check must never publish readiness.
            } catch { AppLogger.shared.logError("检查 ShipIt 更新恢复失败", error: error) }
            task = nil
            didCheck?()
            if needsCheck {
                needsCheck = false
                requestCheck()
            } else if !listenerReady && started {
                requestCheck(after: retry ? min(interval, startupRetryDelay) : startupRetryDelay)
                startupRetryDelay = min(startupRetryDelay * 2, 30_000_000_000)
            } else if retry { requestCheck(after: interval) }
        }
    }

    private func recordSkips(_ skips: [ShipItUpdateRecovery.SkipObservation]) {
        let current = Dictionary(skips.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { _, latest in latest })
        for (bundleIdentifier, skip) in current.sorted(by: { $0.key < $1.key }) where reportedSkips[bundleIdentifier] != skip {
            logContext("跳过 ShipIt 更新候选", [
                ("bundle_id", skip.bundleIdentifier),
                ("reason", skip.reason.rawValue)
            ], "TRACE")
        }
        reportedSkips = current
    }

    private func updateListener() {
        guard let events, startEvents(events, identifiers) else {
            AppLogger.shared.log("ShipIt 文件事件监听启动失败，将自动重试", level: "WARN")
            return
        }
        guard !listenerReady else { return }
        do {
            try didStartListening()
            listenerReady = true
        } catch {
            AppLogger.shared.logError("无法记录更新守护就绪状态，将自动重试", error: error)
        }
    }

    private enum Outcome { case waiting, updated, rolledBack(String) }

    private func recover(_ candidate: ShipItUpdateRecovery.Candidate, automaticRollback: Bool = false) async -> Bool {
        guard let token = operationState.begin() else {
            display(candidate, status: .queued, message: ShipItUpdateRecovery.Step.waiting.message)
            return false
        }
        recovering = true
        defer {
            // Ignore our own completion notification; failed recovery uses the retry delay.
            operationState.finish(token)
            recovering = false
        }
        let worker = recovery
        let report = reporter(candidate)
        let previous = rejectedPackages[candidate.key]
        let operation = Task.detached(priority: .utility) { () throws -> Outcome in
            if automaticRollback {
                return .rolledBack(try await worker.rollback(candidate, automatic: true, report: report))
            }
            return try await worker.recover(candidate, previousRejection: previous, report: report) ? .updated : .waiting
        }
        operationState.registerCancellation(for: token) { operation.cancel() }
        do {
            let completed = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            switch completed {
            case .updated:
                display(candidate, status: .completed, message: "AppPorts 已成功接手并完成更新。".localized, result: .recovered)
            case .rolledBack(let version):
                display(candidate, status: .completed, message: String(format: "新版签名校验失败，已自动回退至 %@。".localized, version), result: .rolledBack)
            case .waiting:
                if !Task.isCancelled { display(candidate, status: .queued, message: ShipItUpdateRecovery.Step.waiting.message) }
                return false
            }
            return true
        } catch let rejection as ShipItUpdateRecovery.RejectedUpdate {
            rejectedPackages[candidate.key] = rejection.identity
            display(candidate, status: .queued, message: rejection.localizedDescription + " " + ShipItUpdateRecovery.Step.preparing.message)
            return false
        } catch ShipItUpdateRecovery.RollbackError.newDownload {
            rejectedPackages.removeValue(forKey: candidate.key)
            return false
        } catch ShipItUpdateRecovery.RollbackError.oldApplicationMissing {
            display(candidate, status: .attention, message: ShipItUpdateRecovery.RollbackError.oldApplicationMissing.localizedDescription, offerRollback: true)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if automaticRollback {
                if case ShipItUpdateRecovery.RollbackError.busy = error {
                    display(candidate, status: .queued, message: ShipItUpdateRecovery.Step.waiting.message)
                    return false
                }
                display(candidate, status: .attention, message: String(format: "回退未完成：%@\n必要副本已保留，可重试回退。".localized, error.localizedDescription), offerRollback: true)
                if case ShipItUpdateRecovery.RollbackError.changed = error { return true }
                return false
            }
            AppLogger.shared.logError("自动接手 ShipIt 更新失败，更新副本已保留", error: error)
            let failure = String(format: "接手失败：%@\n将自动重试，也可以回退更新。".localized, error.localizedDescription)
            failures[candidate.key] = failure
            display(candidate, status: .attention, message: failure, offerRollback: true)
            return false
        }
    }

    private func reporter(_ candidate: ShipItUpdateRecovery.Candidate) -> ShipItUpdateRecovery.Reporter {
        { [weak self] step in
            await MainActor.run { [weak self] in self?.display(candidate, status: .running, message: step.message) }
        }
    }

    private func display(_ candidate: ShipItUpdateRecovery.Candidate, status: MigrationJob.Status, message: String,
                         result: MigrationJob.ObservedResult? = nil, offerRollback: Bool = false) {
        if status == .running || status == .queued { unfinished[candidate.key] = candidate }
        else { unfinished.removeValue(forKey: candidate.key) }
        var action: (@MainActor () -> Void)?
        if offerRollback {
            action = { [weak self] in
                _ = Task<Void, Never> { @MainActor [weak self] in
                    if let self { await self.rollback(candidate) }
                }
            }
        }
        var detail = message
        if status == .completed { failures.removeValue(forKey: candidate.key) }
        else if (status == .running || status == .queued), let failure = failures[candidate.key] {
            detail += "\n" + failure
        }
        do {
            try observedStore?.save(candidate: candidate, status: status, message: detail,
                                    result: result, offersRollback: offerRollback)
        } catch { AppLogger.shared.logError("保存后台更新任务状态失败", error: error) }
        taskCenter?.updateObserved(key: candidate.key,
            title: "应用更新恢复".localized + " · " + candidate.record.name,
            resources: MigrationResources(paths: [candidate.request.targetBundleURL,
                URL(fileURLWithPath: candidate.record.localPath)]),
            status: status, message: detail, result: result, recovery: action)
    }

    func rollback(_ candidate: ShipItUpdateRecovery.Candidate) async {
        do { try recovery.requestRollback(candidate) }
        catch {
            display(candidate, status: .attention, message: error.localizedDescription, offerRollback: true)
            return
        }
        suppressed.insert(candidate.key)
        failures.removeValue(forKey: candidate.key)
        if activeCandidateKey == candidate.key {
            task?.cancel()
            await task?.value
        }
        guard let token = operationState.begin() else {
            display(candidate, status: .attention,
                    message: "更新器或其他操作仍在运行，请稍后重试回退。".localized, offerRollback: true)
            return
        }
        recovering = true
        defer { operationState.finish(token); recovering = false }
        let worker = recovery
        let report = reporter(candidate)
        let operation = Task.detached(priority: .utility) { try await worker.rollback(candidate, report: report) }
        operationState.registerCancellation(for: token) { operation.cancel() }
        do {
            let version = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            display(candidate, status: .completed,
                    message: String(format: "已回退至 %@，本次更新缓存和临时文件已清理。".localized, version), result: .rolledBack)
        } catch {
            display(candidate, status: .attention,
                    message: String(format: "回退未完成：%@\n必要副本已保留，可重试回退。".localized, error.localizedDescription),
                    offerRollback: true)
        }
    }

    func stop(disabledByUser: Bool = false) async {
        started = false
        observers.removeAll()
        events?.stop(); events = nil
        scheduled?.cancel(); scheduled = nil
        task?.cancel()
        await task?.value
        task = nil
        needsCheck = false
        lastMonitoredCount = nil
        reportedSkips.removeAll()
        for candidate in Array(unfinished.values) {
            if disabledByUser, failures[candidate.key] == nil {
                let message = String(format: "更新守护已关闭。「%@」仍待恢复，重新开启守护后将继续检查。".localized, candidate.record.name)
                display(candidate, status: .cancelled, message: message)
            } else {
                let message = failures[candidate.key] ?? "上次运行时更新接手未结束，等待检查更新现场。".localized
                display(candidate, status: .attention, message: message, offerRollback: true)
            }
        }
    }
}
