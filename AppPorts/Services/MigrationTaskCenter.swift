import Combine
import AppKit
import Foundation

enum MigrationApplicationState {
    @MainActor
    static func isRunning(appURL: URL?, bundleIdentifier: String? = nil) -> Bool {
        let applications = NSWorkspace.shared.runningApplications.map {
            AppRunningState.RunningApplication(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
        }
        if let appURL, AppRunningState.isRunning(appURL: appURL, applications: applications) { return true }
        if let bundleIdentifier { return applications.contains { $0.bundleIdentifier == bundleIdentifier } }
        return false
    }
}

enum MigrationCategory: String, Codable, Equatable, Sendable {
    case apps, appData, tools, directories

    var title: String {
        switch self {
        case .apps: return "应用".localized
        case .appData: return "应用数据".localized
        case .tools: return "工具目录".localized
        case .directories: return "目录迁移".localized
        }
    }
}

struct MigrationResources: Codable, Sendable {
    let paths: Set<String>
    let subjectPaths: Set<String>
    let keys: Set<String>
    let dataOperationIDs: Set<UUID>?

    private enum CodingKeys: String, CodingKey {
        case paths, subjectPaths, keys, dataOperationIDs
    }

    init(paths urls: [URL], keys: Set<String> = [], subjectPaths subjectURLs: [URL]? = nil,
         dataOperationIDs: Set<UUID> = []) {
        self.dataOperationIDs = dataOperationIDs
        // Claim both spellings: a local link and its external target must not
        // permit two jobs to edit the same object through different aliases.
        paths = Set(urls.flatMap { [$0.standardizedFileURL.path,
                                   $0.resolvingSymlinksInPath().standardizedFileURL.path] })
        let targetURLs = subjectURLs ?? urls
        subjectPaths = Set(targetURLs.flatMap { [$0.standardizedFileURL.path,
                                                 $0.resolvingSymlinksInPath().standardizedFileURL.path] })
        self.keys = keys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataOperationIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .dataOperationIDs)
        paths = try container.decode(Set<String>.self, forKey: .paths)
        keys = try container.decode(Set<String>.self, forKey: .keys)
        subjectPaths = try container.decodeIfPresent(Set<String>.self, forKey: .subjectPaths) ?? paths
    }

    static func application(paths: [URL], appURL: URL) -> Self {
        // Application transfers also update shared signing/search/Dock facts;
        // keep that existing mutation boundary exclusive within this family.
        var keys: Set<String> = ["application-records"]
        if let identifier = CodeSigner.bundleIdentifier(at: appURL) {
            keys.insert("application:" + identifier)
        }
        return Self(paths: paths, keys: keys)
    }

    static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs == "/" ? "/" : rhs + "/")
            || rhs.hasPrefix(lhs == "/" ? "/" : lhs + "/")
    }

    func overlapsSubject(with other: Self) -> Bool {
        subjectPaths.contains { lhs in
            other.subjectPaths.contains { rhs in Self.pathsOverlap(lhs, rhs) }
        }
    }

    func overlapsSubjectPaths(_ queryPaths: Set<String>) -> Bool {
        subjectPaths.contains { lhs in
            queryPaths.contains { rhs in Self.pathsOverlap(lhs, rhs) }
        }
    }

    func overlapsAllPaths(_ queryPaths: Set<String>) -> Bool {
        paths.contains { lhs in
            queryPaths.contains { rhs in Self.pathsOverlap(lhs, rhs) }
        }
    }

    func conflicts(with other: Self) -> Bool {
        if keys.contains("all-file-operations") || other.keys.contains("all-file-operations") { return true }
        if !keys.isDisjoint(with: other.keys) { return true }
        return paths.contains { lhs in
            other.paths.contains { rhs in Self.pathsOverlap(lhs, rhs) }
        }
    }
}

@MainActor
final class MigrationJob: ObservableObject, Identifiable {
    enum ObservedResult: String, Codable { case recovered, rolledBack }
    /// Identifies one failed attempt. A delayed dialog cannot retry a newer attempt.
    struct RetryToken: Equatable, Sendable {
        let jobID: UUID
        fileprivate let attemptID: UUID
    }

    enum Status: String, Codable, Equatable {
        case queued, running, completed, attention, cancelled, incomplete
        var isFinished: Bool { self == .completed || self == .attention || self == .cancelled || self == .incomplete }
        var title: String {
            switch self {
            case .queued: return "等待中".localized
            case .running: return "处理中".localized
            case .completed: return "已完成".localized
            case .attention: return "需要处理".localized
            case .cancelled: return "已取消".localized
            case .incomplete: return "未完成（已归档）".localized
            }
        }
    }

    let id: UUID
    private let attemptID = UUID()
    let title: String
    let category: MigrationCategory
    let resources: MigrationResources
    let observedKey: String?
    var observedResult: ObservedResult?
    var supportsExecutionControls: Bool { observedKey == nil }
    let progress = DataTransferProgress()
    let control: MigrationTaskControl
    var blockedAppStart: AppMigrationStartBlock?
    let createdAt = ProcessInfo.processInfo.systemUptime
    @Published var status: Status = .queued
    @Published var message = ""
    private(set) var startedAt: Date?
    private(set) var startedUptime: TimeInterval?
    var restoredPaused = false
    var restoredFraction: Double?
    var restoredElapsed: TimeInterval?
    var finishedAt: TimeInterval?
    var worker: Task<Void, Never>?
    var operation: (@Sendable (DataTransferProgress) async throws -> String?)?
    var completion: (@MainActor () -> Void)?
    var recoveryHandler: (@MainActor (Error, RetryToken) -> Void)?
    var recoveryAction: (@MainActor () -> Void)?

    /// Keep the operation and subject; the row presents running state separately.
    /// Newly submitted tasks omit progressive prefixes in every language; stripping
    /// a leading "正在" remains only for previously persisted Chinese history rows.
    var displayTitle: String {
        title.hasPrefix("正在") ? String(title.dropFirst(2)) : title
    }

    var retryToken: RetryToken { RetryToken(jobID: id, attemptID: attemptID) }

    init(id: UUID = UUID(), title: String, category: MigrationCategory, resources: MigrationResources,
         startedAt: Date? = nil, observedKey: String? = nil, expectedAppStart: AppMigrationStartBlock? = nil) {
        self.control = MigrationTaskControl(expectedAppStart: expectedAppStart)
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.category = category
        self.resources = resources
        self.observedKey = observedKey
    }

    func markStarted() {
        startedAt = Date()
        startedUptime = ProcessInfo.processInfo.systemUptime
        status = .running
    }

    func elapsed(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        if let restoredElapsed { return restoredElapsed }
        guard let startedUptime else { return 0 }
        let end = finishedAt ?? now
        return max(0, end - startedUptime - control.pausedDuration(at: end))
    }

    var elapsed: TimeInterval { elapsed() }
    // The worker cancelled its execution. The application still needs recovery.
    var guardianPaused: Bool { observedKey != nil && status == .cancelled }

    var stateTitle: String {
        if guardianPaused { return "已暂停自动处理".localized }
        if status == .completed, let observedResult {
            return observedResult == .recovered ? "已接手成功".localized : "已回退更新".localized
        }
        if status.isFinished, status != .attention { return status.title }
        if restoredPaused { return "已暂停（待恢复）".localized }
        if status.isFinished { return status.title }
        let state = control.snapshot()
        if !status.isFinished, state.cancelled { return "正在取消，等待安全收尾".localized }
        if status == .queued, state.pauseRequested { return "已暂停（尚未开始）".localized }
        if state.paused { return "已暂停".localized }
        if state.pauseRequested { return "正在等待可暂停的位置".localized }
        return status.title
    }
    var fraction: Double { status == .completed ? 1 : (restoredFraction ?? progress.snapshot().overallFraction) }
    var badgeStatus: String {
        if control.snapshot().pauseRequested { return "已暂停" }
        return status == .queued ? "等待中" : "处理中"
    }
}

/// Owns execution, reservations, results and presentation independently of pages.
/// Completed rows stay available until explicitly removed by the user.
@MainActor
final class MigrationTaskCenter: ObservableObject {
    static let shared = MigrationTaskCenter()
    @Published private(set) var jobs: [MigrationJob] = []
    @Published var detailID: UUID?
    @Published var showsList = false
    @Published var recoveryJobID: UUID?
    private let maximumConcurrentJobs = 3
    private let historyStore: MigrationTaskHistoryStore
    private let operationState: AppOperationState
    private let makeOperationLock: @Sendable () -> OperationLock

    init(historyStore: MigrationTaskHistoryStore = MigrationTaskHistoryStore(),
         operationState: AppOperationState? = nil,
         makeOperationLock: @escaping @Sendable () -> OperationLock = { OperationLock() }) {
        self.historyStore = historyStore
        self.operationState = operationState ?? .shared
        self.makeOperationLock = makeOperationLock
        jobs = historyStore.load().map { entry in
            let job = MigrationJob(id: entry.id, title: entry.title, category: entry.category,
                                   resources: entry.resources, startedAt: entry.startedAt, observedKey: entry.observedKey)
            job.observedResult = entry.observedResult
            job.restoredPaused = entry.paused && (!entry.status.isFinished || entry.status == .attention)
            job.restoredFraction = entry.fraction
            job.restoredElapsed = entry.elapsed
            job.status = entry.status.isFinished ? entry.status : .attention
            job.message = entry.message
            if !entry.status.isFinished {
                job.message = (entry.observedKey == nil
                    ? "上次运行时任务未结束。请先检查迁移记录，再继续处理；不会自动重新迁移或删除文件。".localized
                    : "上次运行时更新接手未结束，等待检查更新现场。".localized)
                    + (entry.message.isEmpty ? "" : "\n" + entry.message)
            }
            return job
        }
    }

    func saveHistoryForExit() {
        let clearCompleted = UserDefaults.standard.object(forKey: MigrationTaskHistoryStore.clearCompletedOnExitKey) as? Bool ?? true
        historyStore.save(jobs.filter { !clearCompleted || $0.status != .completed }.map(MigrationTaskHistoryStore.Entry.init))
    }

    private func persistHistory() {
        historyStore.save(jobs.map(MigrationTaskHistoryStore.Entry.init))
    }

    var hasUnfinishedJobs: Bool { jobs.contains { !$0.status.isFinished } }
    var unfinishedCount: Int { jobs.filter { !$0.status.isFinished }.count }
    var hasAttention: Bool { jobs.contains { $0.status == .attention } }
    var detail: MigrationJob? { jobs.first { $0.id == detailID } }

    func openJobDetail(_ job: MigrationJob) {
        showsList = false
        detailID = job.id
    }

    private static func normalizedPathSet(_ urls: [URL]) -> Set<String> {
        Set(urls.flatMap { [$0.standardizedFileURL.path,
                            $0.resolvingSymlinksInPath().standardizedFileURL.path] })
    }

    func activeJob(overlappingSubject urls: [URL], includeObserved: Bool = false) -> MigrationJob? {
        let candidates = jobs.filter { !$0.status.isFinished && (includeObserved || $0.supportsExecutionControls) }
        guard !candidates.isEmpty else { return nil }
        let queryPaths = Self.normalizedPathSet(urls)
        guard !queryPaths.isEmpty else { return nil }
        return candidates.first { $0.resources.overlapsSubjectPaths(queryPaths) }
    }

    func activeJob(overlappingAllPaths urls: [URL], includeObserved: Bool = false) -> MigrationJob? {
        let candidates = jobs.filter { !$0.status.isFinished && (includeObserved || $0.supportsExecutionControls) }
        guard !candidates.isEmpty else { return nil }
        let queryPaths = Self.normalizedPathSet(urls)
        guard !queryPaths.isEmpty else { return nil }
        return candidates.first { $0.resources.overlapsAllPaths(queryPaths) }
    }

    func hasActiveJob(overlappingSubject pathStrings: [String]) -> Bool {
        let urls = pathStrings.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        return activeJob(overlappingSubject: urls) != nil
    }

    private func conflictingUnfinishedJob(for resources: MigrationResources) -> MigrationJob? {
        jobs.first { job in
            guard !job.status.isFinished, job.supportsExecutionControls else { return false }
            if job.resources.keys.contains("all-file-operations") && resources.keys.contains("all-file-operations") {
                return job.resources.dataOperationIDs == resources.dataOperationIDs
            }
            return job.resources.overlapsSubject(with: resources)
        }
    }

    /// Observed work retains its own operation token and filesystem locks.
    @discardableResult
    func updateObserved(key: String, title: String, resources: MigrationResources,
                        status: MigrationJob.Status, message: String,
                        result: MigrationJob.ObservedResult? = nil,
                        recovery: (@MainActor () -> Void)? = nil) -> MigrationJob {
        let job: MigrationJob
        if let existing = jobs.first(where: { $0.observedKey == key }) { job = existing }
        else {
            job = MigrationJob(title: title, category: .apps, resources: resources, observedKey: key)
            jobs.append(job)
        }
        if status == .running, job.startedAt == nil { job.markStarted() }
        job.status = status
        job.message = message
        job.observedResult = result
        if status == .completed || job.guardianPaused { job.recoveryAction = nil }
        else if let recovery { job.recoveryAction = recovery }
        job.restoredPaused = false
        job.restoredElapsed = nil
        job.finishedAt = status.isFinished ? ProcessInfo.processInfo.systemUptime : nil
        persistHistory()
        objectWillChange.send()
        return job
    }

    func canRetry(_ retry: MigrationJob.RetryToken) -> Bool {
        jobs.contains { $0.retryToken == retry && $0.status == .attention }
    }

    @discardableResult
    func submit(title: String, category: MigrationCategory, resources: MigrationResources,
                presentDetails: Bool = true,
                retrying retry: MigrationJob.RetryToken? = nil,
                recovery: (@MainActor (Error, MigrationJob.RetryToken) -> Void)? = nil,
                operation: @escaping @Sendable (DataTransferProgress) async throws -> String?,
                completion: (@MainActor () -> Void)? = nil) -> UUID {
        let retryIndex: Int?
        if let retry {
            // Retry is explicit, never inferred from matching titles or paths.
            // Removed, completed and superseded attempts must not be recreated.
            guard canRetry(retry), let index = jobs.firstIndex(where: { $0.id == retry.jobID }) else {
                if presentDetails, jobs.contains(where: { $0.id == retry.jobID }) {
                    showsList = false
                    detailID = retry.jobID
                }
                return retry.jobID
            }
            retryIndex = index
        } else {
            retryIndex = nil
        }
        if retry == nil, let existing = conflictingUnfinishedJob(for: resources) {
            if presentDetails { openJobDetail(existing) }
            return existing.id
        }
        let job = MigrationJob(id: retry?.jobID ?? UUID(), title: title, category: category, resources: resources,
                               expectedAppStart: retryIndex.flatMap { jobs[$0].blockedAppStart })
        job.operation = operation
        job.completion = completion
        job.recoveryHandler = recovery
        if let retryIndex {
            // A fresh execution resets progress, cancellation and timing while
            // the task list, detail selection and persisted history keep one ID.
            jobs[retryIndex] = job
        } else {
            jobs.append(job)
        }
        if presentDetails {
            showsList = false
            detailID = job.id
        }
        scheduleRunnableJobs()
        publishCount()
        return job.id
    }

    func pause(_ ids: Set<UUID>) {
        for job in jobs where ids.contains(job.id) && job.supportsExecutionControls && !job.status.isFinished { job.control.pause() }
        objectWillChange.send()
        persistHistory()
    }

    func resume(_ ids: Set<UUID>) {
        for job in jobs where ids.contains(job.id) && job.supportsExecutionControls && !job.status.isFinished { job.control.resume() }
        scheduleRunnableJobs()
        objectWillChange.send()
        persistHistory()
    }

    func cancel(_ ids: Set<UUID>) {
        let now = ProcessInfo.processInfo.systemUptime
        for job in jobs where ids.contains(job.id) && job.supportsExecutionControls && !job.status.isFinished {
            job.control.cancel(at: now)
            if job.status == .queued {
                job.status = .cancelled
                job.finishedAt = now
                job.operation = nil
                job.completion = nil
                job.recoveryHandler = nil
            } else {
                // Do not release reservations until the worker has completed
                // its journal-driven recovery and returned from the operation.
                job.worker?.cancel()
            }
        }
        scheduleRunnableJobs()
        publishCount()
    }

    func markArchivedIncomplete(_ id: UUID, message: String) {
        guard let job = jobs.first(where: { $0.id == id }), job.status.isFinished else { return }
        job.status = .incomplete
        job.message = message
        job.restoredPaused = false
        job.recoveryAction = nil
        publishCount()
    }

    func removeFinished(_ ids: Set<UUID>) {
        jobs.removeAll { ids.contains($0.id) && $0.status.isFinished }
        if let detailID, !jobs.contains(where: { $0.id == detailID }) { self.detailID = nil }
        persistHistory()
    }

    /// Removes only successful task records; never touches migrated files or pending tasks.
    func clearCompleted() {
        removeFinished(Set(jobs.filter { $0.status == .completed }.map(\.id)))
    }

    func schedule() {
        if scheduleRunnableJobs() {
            objectWillChange.send()
            persistHistory()
        }
    }

    @discardableResult
    private func scheduleRunnableJobs() -> Bool {
        guard !operationState.blocksInteraction else { return false }
        var didStart = false
        var active = jobs.filter { $0.status == .running && $0.supportsExecutionControls }
        for job in jobs where job.status == .queued {
            guard active.count < maximumConcurrentJobs else { break }
            guard !job.control.snapshot().pauseRequested,
                  !active.contains(where: { $0.resources.conflicts(with: job.resources) }) else { continue }
            guard let operation = job.operation else { continue }
            job.markStarted()
            didStart = true
            active.append(job)
            let control = job.control
            let progress = job.progress
            let makeOperationLock = self.makeOperationLock
            job.worker = Task { [weak self] in
                let result: Result<String?, Error>
                do {
                    let message = try await MigrationExecution.$managed.withValue(true) {
                        try await MigrationExecution.$control.withValue(control) {
                            try await control.checkpointAsync()
                            return try await progress.track { _ in
                                progress.begin(.waiting, detail: "正在等待取得磁盘操作权限。".localized)
                                let lock = makeOperationLock()
                                guard await lock.acquire(timeout: OperationLock.appWaitTimeout) else {
                                    try Task.checkCancellation()
                                    throw lock.diagnosticFailure(scope: .global)
                                }
                                defer { lock.release() }
                                try await control.checkpointAsync()
                                progress.begin(.preparing)
                                return try await MigrationExecution.$dataTaskID.withValue(job.id) {
                                    try await operation(progress)
                                }
                            }
                        }
                    }
                    result = .success(message)
                } catch { result = .failure(error) }
                self?.finish(job, result: result)
            }
        }
        return didStart
    }

    private func finish(_ job: MigrationJob, result: Result<String?, Error>) {
        switch result {
        case .success(let warning):
            job.message = warning ?? ""
            if let warning, !warning.isEmpty { job.status = .attention }
            else if job.control.snapshot().cancelled {
                job.status = .cancelled
                job.message = "取消请求已处理；已完成的迁移步骤不会撤销。".localized
            } else { job.status = .completed }
        case .failure(let error):
            if error is CancellationError {
                job.status = .cancelled
                job.message = "任务已取消。已保留的数据和未完成的清理可在原页面查看。".localized
            } else {
                let snapshot = job.progress.snapshot()
                AppLogger.shared.logOperationFailure(category: "migration_task", operationID: job.id.uuidString,
                    error: error, stage: String(describing: snapshot.stage), startedAt: job.startedAt,
                    details: [("task_title", job.title), ("attempt_id", job.retryToken.attemptID.uuidString),
                              ("task_category", String(describing: job.category)),
                              ("resource_paths", job.resources.paths.sorted().joined(separator: "\n"))])
                job.status = .attention
                job.message = error.localizedDescription
                if let block = error as? AppMigrationStartBlock, let operation = job.operation {
                    job.blockedAppStart = block
                    let retry = job.retryToken, title = job.title, resources = job.resources
                    let completion = job.completion
                    job.recoveryAction = { [weak self] in
                        self?.submit(title: title, category: .apps, resources: resources, retrying: retry,
                                     operation: operation, completion: completion)
                    }
                } else if let recovery = job.recoveryHandler {
                    let retry = job.retryToken
                    job.recoveryAction = { recovery(error, retry) }
                }
            }
        }
        let finishedUptime = ProcessInfo.processInfo.systemUptime
        job.finishedAt = finishedUptime
        job.restoredPaused = false
        job.control.resume(at: finishedUptime)
        job.worker = nil
        job.operation = nil
        job.recoveryHandler = nil
        let completion = job.completion
        job.completion = nil
        completion?()
        scheduleRunnableJobs()
        publishCount()
    }

    private func publishCount() {
        operationState.setMigrationCount(jobs.filter { !$0.status.isFinished && $0.supportsExecutionControls }.count)
        persistHistory()
        objectWillChange.send()
    }
}
