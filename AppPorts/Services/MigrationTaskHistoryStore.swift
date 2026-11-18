import Foundation

/// Display history only. Durable migration journals remain the authority for recovery.
struct MigrationTaskHistoryStore {
    static let clearCompletedOnExitKey = "clearCompletedMigrationTasksOnExit"

    struct Entry: Codable {
        let id: UUID
        let title: String
        let category: MigrationCategory
        let resources: MigrationResources
        let status: MigrationJob.Status
        let message: String
        let startedAt: Date?
        let elapsed: TimeInterval
        let fraction: Double
        let paused: Bool
        let observedKey: String?
        let observedResult: MigrationJob.ObservedResult?

        @MainActor
        init(_ job: MigrationJob) {
            id = job.id
            title = job.title
            category = job.category
            resources = job.resources
            status = job.status
            message = job.message
            startedAt = job.startedAt
            elapsed = job.elapsed
            fraction = job.fraction
            paused = job.status.isFinished ? (job.status == .attention && job.restoredPaused) : job.control.snapshot().pauseRequested
            observedKey = job.observedKey
            observedResult = job.observedResult
        }
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts/migration-task-history.json")
    }

    func load() -> [Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do { return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL)) }
        catch {
            AppLogger.shared.logError("读取任务历史失败", error: error)
            return []
        }
    }

    func save(_ entries: [Entry]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch { AppLogger.shared.logError("保存任务历史失败", error: error) }
    }
}
