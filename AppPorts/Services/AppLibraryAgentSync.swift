import Foundation
import Combine

/// Keep selection reconciliation alive until the latest selection is saved to launchd.
@MainActor
final class AppLibraryAgentSync: ObservableObject {
    static let shared = AppLibraryAgentSync()
    @Published private(set) var isSynchronizing = false
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var generation: UInt = 0
    private let synchronize: @Sendable () async throws -> Void

    init(synchronize: @escaping @Sendable () async throws -> Void = {
        try await BackgroundAgents.synchronize()
    }) {
        self.synchronize = synchronize
    }

    func selectionDidChange() {
        generation &+= 1
        guard task == nil else { return }
        isSynchronizing = true
        errorMessage = nil
        task = Task {
            while true {
                let current = generation
                let operation = synchronize
                do {
                    try await Task.detached(priority: .utility) { try await operation() }.value
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                    AppLogger.shared.logError("同步后台代理设置失败", error: error)
                }
                if current == generation { break }
            }
            task = nil
            isSynchronizing = false
        }
    }

    func finishBeforeTerminating(timeout: TimeInterval = 5,
                                 _ reply: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard task != nil else { return false }
        Task {
            // Awaiting task.value cannot be interrupted by a timeout when the
            // worker is waiting for another process's operation lock.
            let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
            while task != nil {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    reply(false)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            reply(true)
        }
        return true
    }
}
