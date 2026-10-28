import Foundation

/// Internal completion of the original user request. Calls coalesce and each
/// owning service retains its journal until the actual work has finished.
actor OperationMaintenance {
    static let shared = OperationMaintenance()
    private struct RunningMaintenance {
        let task: Task<[String], Never>
        let progress: DataTransferProgress
    }

    private var active: RunningMaintenance?
    private var dataActive: RunningMaintenance?
    private var lastFinishedAt: Date?
    private let perform: @Sendable () async -> [String]

    init(perform: (@Sendable () async -> [String])? = nil) {
        self.perform = perform ?? { await OperationMaintenance.performMaintenance() }
    }

    /// A foreground retry adopts the worker's reporter, including when it
    /// joins maintenance that already began in the background.
    func run(minimumInterval: TimeInterval = 0, observeProgress: (@Sendable (DataTransferProgress) async -> Void)? = nil) async -> [String] {
        if let active {
            await observeProgress?(active.progress)
            return await active.task.value
        }
        if let lastFinishedAt, Date().timeIntervalSince(lastFinishedAt) < minimumInterval { return [] }
        let progress = DataTransferProgress()
        let perform = self.perform
        let task = Task.detached(priority: .utility) {
            await progress.track { _ in
                progress.begin(.recovering)
                return await perform()
            }
        }
        active = RunningMaintenance(task: task, progress: progress)
        defer { active = nil; lastFinishedAt = Date() }
        await observeProgress?(progress)
        return await task.value
    }

    /// 应用数据页的手动重试只处理数据目录，不夹带应用迁移或签名清理。
    func runDataOperations(retryOperationID: UUID? = nil, observeProgress: (@Sendable (DataTransferProgress) async -> Void)? = nil) async -> [String] {
        if let dataActive {
            await observeProgress?(dataActive.progress)
            return await dataActive.task.value
        }
        let progress = DataTransferProgress()
        let task = Task.detached(priority: .utility) {
            await progress.track { _ in
                progress.begin(.recovering)
                return await Self.finishDataOperations(interactive: true, retryOperationID: retryOperationID)
            }
        }
        dataActive = RunningMaintenance(task: task, progress: progress)
        defer { dataActive = nil; lastFinishedAt = Date() }
        await observeProgress?(progress)
        return await task.value
    }

    private static func performMaintenance() async -> [String] {
        var warnings = await finishDataOperations()
        let applications = AppMigrationService()
        do {
            let inventory = try applications.pendingTransferInspection()
            warnings += inventory.issues.map(\.message)
            // Retry everything that can still advance, then close out whatever
            // provably cannot. Both are AppPorts' own bookkeeping: a stuck record
            // keeps its paths blocked, so leaving it for the user would hand them
            // a state they cannot act on and an app they cannot operate.
            for record in inventory.records {
                guard !applications.retryDisposition(for: record).isTerminal else { continue }
                do {
                    let result = try await applications.retryTransfer(operationID: record.operationID)
                    if let message = result.pendingMessage { warnings.append(message) }
                } catch { warnings.append(record.appName + ": " + error.localizedDescription) }
            }
            warnings += applications.retireUnrecoverableTransfers()
        } catch { warnings.append(error.localizedDescription) }
        // Signature work acquires its own locks, after data/app locks release.
        warnings += await CodeSigner().performAutomaticMaintenance()
        if !warnings.isEmpty {
            AppLogger.shared.logContext("操作自动收尾尚未完成", details: [("reason", warnings.joined(separator: "\n"))], level: "WARN")
        }
        return warnings
    }

    /// A managed retry retains the caller's progress and cancellation context.
    /// It is scheduled exclusively against all other foreground file jobs.
    func runManagedDataOperations(retryOperationID: UUID? = nil) async -> [String] {
        await Self.finishDataOperations(interactive: true, retryOperationID: retryOperationID)
    }

    private static func finishDataOperations(interactive: Bool = false, retryOperationID: UUID? = nil) async -> [String] {
        let warnings = await CleanupRetryContext.$automatic.withValue(!interactive) {
            await finishScheduledDataOperations(interactive: interactive, retryOperationID: retryOperationID)
        }
        // Diagnostics cannot delay entry recovery or hold its operation lock.
        await VolumeStateReporting.collect()
        return warnings
    }

    private static func finishScheduledDataOperations(interactive: Bool, retryOperationID: UUID?) async -> [String] {
        let lock = OperationLock()
        guard await lock.acquire(timeout: OperationLock.appWaitTimeout) else {
            let failure = lock.diagnosticFailure(scope: .global)
            AppLogger.shared.logOperationFailure(category: "data_maintenance", operationID: failure.failureID.uuidString,
                error: failure, stage: "waiting")
            return [failure.localizedDescription]
        }
        defer { lock.release() }
        var warnings: [String] = []
        let store = ContainerMountStore.shared
        let ejection: DiskEjectionPauseStore.Snapshot
        do { ejection = try await DiskEjectionPauseStore(store: store).refreshed(using: DiskUtility(administratorRunner: nil)) }
        catch { return [error.localizedDescription] }
        if interactive {
            do {
                // Check explicit retry before changing cleanup intent or selecting a direct cleanup path.
                if let retryOperationID, let transfer = try store.transfer(operationID: retryOperationID),
                   transfer.mode == .mount, try store.manualMountPauseBlocks(transfer) {
                    return [ManualMountPauseError.retryPaused.localizedDescription]
                }
                for transfer in try store.transfers() where transfer.cleanupDisposition != nil {
                    // A general retry resumes deferred work, never a copy the
                    // user explicitly chose to keep. That requires its own retry.
                    if transfer.operationID == retryOperationID
                        || retryOperationID == nil && transfer.cleanupDisposition == .deferred {
                        try store.setCleanupDisposition(nil, expected: transfer)
                    }
                }
            } catch { return [error.localizedDescription] }
        }
        let migrator = ContainerVolumeMigrator(disk: interactive ? DiskUtility() : DiskUtility(administratorRunner: nil))
        if let retryOperationID {
            do {
                guard let transfer = try store.transfer(operationID: retryOperationID) else { return [] }
                if transfer.isDataSwitchComplete {
                    if transfer.mode == .mount { try await migrator.cleanupRetainedTransfer(operationID: retryOperationID) }
                    else { try await DataDirMover(allowsAdministratorPrompt: interactive).cleanupRetainedTransfer(operationID: retryOperationID) }
                    return []
                }
                if transfer.mode == .symlink {
                    let warning = try await DataDirMover().resumeVerifiedTransfer(operationID: retryOperationID, progressHandler: nil)
                    return warning.map { [$0] } ?? []
                }
                return await migrator.performAutomaticMaintenance(only: retryOperationID, ignoresRetryBackoff: true)
            } catch { return [error.localizedDescription] }
        }
        warnings += await migrator.performAutomaticMaintenance(ignoresRetryBackoff: interactive)
        let outcomes = await migrator.remountAvailableRecords()
        for outcome in outcomes {
            switch outcome.state {
            case .failed(let reason), .requiresIntervention(let reason): warnings.append(reason)
            case .unavailable: warnings.append(outcome.record.appName + ": " + "请连接保存数据的外部存储。".localized)
            default: break
            }
        }
        do {
            let transfers = try store.transfers()
            let parents = Set(transfers.filter { $0.rollbackCompletedAt == nil }.compactMap(\.priorOperationID))
            for transfer in transfers where transfer.mode == .symlink && transfer.needsAutomaticCompletion && !parents.contains(transfer.operationID) {
                if ejection.blocks(transfer) { continue }
                if !interactive, transfer.isDataSwitchComplete,
                   CleanupRetryBackoff.shouldDefer(until: transfer.nextAutomaticRetryAt, now: Date()) { continue }
                do {
                    let warning = try await DataDirMover().resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: nil)
                    if let warning { warnings.append(warning) }
                    if warning != nil { CleanupRetryContext.recordFailureIfUnchanged(transfer, store: store) }
                } catch {
                    warnings.append(transfer.appName + ": " + error.localizedDescription)
                    CleanupRetryContext.recordFailureIfUnchanged(transfer, store: store)
                }
            }
        } catch { warnings.append(error.localizedDescription) }
        return warnings
    }
}
