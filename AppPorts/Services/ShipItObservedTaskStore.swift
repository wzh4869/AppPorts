import Foundation

/// Per-request display records avoid competing whole-history writes from two processes.
struct ShipItObservedTaskStore {
    struct Entry: Codable {
        let candidate: ShipItUpdateRecovery.Candidate
        let status: MigrationJob.Status
        let message: String
        let result: MigrationJob.ObservedResult?
        let offersRollback: Bool
        let revision: UUID
        let worker: WriterProcessIdentity?
    }

    let directory: URL

    init(directory: URL = WriterAdmission.defaultDataDirectory.appendingPathComponent("shipit-recovery")) {
        self.directory = directory
    }

    func prepare() throws {
        try WriterAdmission.prepareForWrite(dataDirectory: directory.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(candidate: ShipItUpdateRecovery.Candidate, status: MigrationJob.Status, message: String,
              result: MigrationJob.ObservedResult?, offersRollback: Bool) throws {
        try prepare()
        let entry = Entry(candidate: candidate, status: status, message: message, result: result,
                          offersRollback: offersRollback, revision: UUID(), worker: try? WriterAdmission.currentProcessIdentity())
        try DurableFileIO.write(try JSONEncoder().encode(entry), to: directory.appendingPathComponent(candidate.key + ".task.json"))
    }

    func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".task.json") }
            .compactMap { url in
                do {
                    let data = try Data(contentsOf: url)
                    guard data.count <= 256 * 1024 else { return nil }
                    let entry = try JSONDecoder().decode(Entry.self, from: data)
                    return url.lastPathComponent == entry.candidate.key + ".task.json" ? entry : nil
                } catch {
                    AppLogger.shared.logError("读取后台更新任务状态失败", error: error)
                    return nil
                }
            }
    }
}

@MainActor
final class ShipItTaskObserver {
    static let shared = ShipItTaskObserver()
    static let seenKey = "observedBackgroundUpdateTasks"
    private let store: ShipItObservedTaskStore
    private let taskCenter: MigrationTaskCenter
    private let defaults: UserDefaults
    private let rollback: @MainActor (ShipItUpdateRecovery.Candidate) async -> Void
    private let injected: Bool
    private var monitor: FolderMonitor?
    private var applied: [String: String]
    private var imported: Set<String> = []

    init(store: ShipItObservedTaskStore? = nil, taskCenter: MigrationTaskCenter? = nil,
         defaults: UserDefaults = .standard,
         rollback: @escaping @MainActor (ShipItUpdateRecovery.Candidate) async -> Void = {
             await ShipItRecoveryMonitor.shared.rollback($0)
         }) {
        self.store = store ?? ShipItObservedTaskStore(); self.taskCenter = taskCenter ?? .shared
        self.defaults = defaults; self.rollback = rollback; injected = store != nil
        applied = defaults.dictionary(forKey: Self.seenKey) as? [String: String] ?? [:]
    }

    func start() {
        guard monitor == nil else { return }
        guard injected || (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
              && NSClassFromString("XCTestCase") == nil) else { return }
        do {
            try store.prepare()
            let watcher = FolderMonitor(url: store.directory)
            watcher.startMonitoring { [weak self] in Task { @MainActor in self?.refresh() } }
            monitor = watcher
            refresh()
        } catch { AppLogger.shared.logError("监听后台更新任务失败", error: error) }
    }

    func refresh() {
        do {
            for entry in try store.entries() {
                let key = entry.candidate.key
                let existing = taskCenter.jobs.first { $0.observedKey == key }
                let interrupted = (entry.status == .running || entry.status == .queued)
                    && entry.worker.map(WriterAdmission.matchesRunningProcess) != true
                guard applied[key] != entry.revision.uuidString || (existing != nil && !imported.contains(key))
                        || (interrupted && existing != nil && existing?.status != .attention) else { continue }
                var action: (@MainActor () -> Void)?
                if entry.offersRollback || interrupted {
                    let rollback = self.rollback
                    action = { _ = Task { await rollback(entry.candidate) } }
                }
                taskCenter.updateObserved(key: key,
                    title: "应用更新恢复".localized + " · " + entry.candidate.record.name,
                    resources: MigrationResources(paths: [entry.candidate.request.targetBundleURL,
                        URL(fileURLWithPath: entry.candidate.record.localPath)]),
                    status: interrupted ? .attention : entry.status,
                    message: interrupted ? "上次运行时更新接手未结束，等待检查更新现场。".localized + "\n" + entry.message : entry.message,
                    result: entry.result, recovery: action)
                applied[key] = entry.revision.uuidString
                imported.insert(key)
            }
            defaults.set(applied, forKey: Self.seenKey)
        } catch { AppLogger.shared.logError("同步后台更新任务失败", error: error) }
    }

    func stop() {
        monitor?.stopMonitoring(); monitor = nil
    }
}
