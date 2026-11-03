import Foundation

/// Keep selection reconciliation alive until the latest selection is saved to launchd.
@MainActor
final class AppLibraryAgentSync {
    static let shared = AppLibraryAgentSync()
    private var task: Task<Void, Never>?
    private var generation: UInt = 0
    private let synchronize: @Sendable () async -> Void

    init(synchronize: @escaping @Sendable () async -> Void = {
        await ContainerMountAgentInstaller.synchronizeSelection()
    }) {
        self.synchronize = synchronize
    }

    func selectionDidChange() {
        generation &+= 1
        guard task == nil else { return }
        task = Task {
            while true {
                let current = generation
                let operation = synchronize
                await Task.detached(priority: .utility) { await operation() }.value
                if current == generation { break }
            }
            task = nil
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
