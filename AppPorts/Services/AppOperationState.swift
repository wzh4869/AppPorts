import Combine
import Foundation

extension Notification.Name {
    static let appPortsRecordsDidChange = Notification.Name("AppPorts.recordsDidChange")
}

/// 跨页面、跨窗口保留文件操作的生命周期，阻止重建视图或重复启动迁移。
@MainActor
final class AppOperationState: ObservableObject {
    static let shared = AppOperationState()

    @Published private var activeOperation: UUID?
    @Published private var migrationCount = 0
    @Published private(set) var recordsRevision: UInt64 = 0
    private var pendingRecordsChange = false
    private var recordObserver: AnyCancellable?
    private var terminationReply: (() -> Void)?
    private var cancellation: (() -> Void)?

    init(notificationCenter: NotificationCenter = .default) {
        recordObserver = notificationCenter.publisher(for: .appPortsRecordsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.isBusy {
                    self.pendingRecordsChange = true
                    return
                }
                self.recordsRevision &+= 1
            }
    }

    var isBusy: Bool { activeOperation != nil || migrationCount > 0 }
    var blocksInteraction: Bool { activeOperation != nil }

    func isOnlyOperation(_ token: UUID) -> Bool {
        activeOperation == token && migrationCount == 0
    }

    func setMigrationCount(_ count: Int) {
        let wasBusy = isBusy
        migrationCount = count
        if wasBusy && !isBusy {
            pendingRecordsChange = false
            recordsRevision &+= 1
            completeTerminationIfIdle()
        }
    }

    func begin() -> UUID? {
        guard !isBusy, terminationReply == nil else { return nil }
        let token = UUID()
        activeOperation = token
        return token
    }

    func finish(_ token: UUID, publishRecordsChange: Bool = true) {
        guard activeOperation == token else { return }
        activeOperation = nil
        cancellation = nil
        // Publish once at the end of a mutating foreground operation (or when a
        // background store change arrived while busy). A pre-lock refusal leaves
        // recordsRevision untouched so idle observers do not rescan or resync.
        let shouldPublish = publishRecordsChange || pendingRecordsChange
        if !isBusy {
            if shouldPublish {
                pendingRecordsChange = false
                recordsRevision &+= 1
            }
        } else if shouldPublish {
            pendingRecordsChange = true
        }
        completeTerminationIfIdle()
        if terminationReply == nil {
            MigrationTaskCenter.shared.schedule()
        }
    }

    private func completeTerminationIfIdle() {
        guard !isBusy, let reply = terminationReply else { return }
        terminationReply = nil
        reply()
    }

    func registerCancellation(for token: UUID, _ cancel: @escaping () -> Void) {
        guard activeOperation == token else { return }
        cancellation = cancel
    }

    /// Keep every UI mutation's task reachable during a normal Quit. The
    /// caller still finishes its token after accounting for the operation.
    @discardableResult
    func startTask(for token: UUID, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard activeOperation == token else { return nil }
        let task = Task { @MainActor in await operation() }
        registerCancellation(for: token) { task.cancel() }
        return task
    }

    /// The operation keeps ownership until its current filesystem boundary is
    /// accounted for. A forced quit remains recoverable from its own journal.
    func finishBeforeTerminating(_ reply: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        terminationReply = reply
        cancellation?()
        return true
    }
}
