import Foundation
import Combine

/// Keep selection reconciliation alive until the latest selection is saved to launchd.
@MainActor
final class AppLibraryAgentSync: ObservableObject {
    static let shared = AppLibraryAgentSync()
    @Published private(set) var isSynchronizing = false
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    @Published private(set) var guardianReady = false
    @Published private(set) var guardianRetrying = false
    private var readinessTask: Task<Void, Never>?
    private var guardianExit: DispatchSourceProcess?
    private var generation: UInt = 0
    private let synchronize: @Sendable () async throws -> Void

    init(synchronize: @escaping @Sendable () async throws -> Void = {
        try await BackgroundAgents.synchronize()
    }) {
        self.synchronize = synchronize
    }

    func selectionDidChange() {
        invalidateGuardianReadiness()
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
            refreshGuardianReadiness()
        }
    }

    private func invalidateGuardianReadiness() {
        readinessTask?.cancel()
        guardianExit?.cancel()
        guardianExit = nil
        guardianReady = false
        guardianRetrying = false
    }

    private func refreshGuardianReadiness() {
        invalidateGuardianReadiness()
        guard BackgroundAgentPreferences.updateGuardianEnabled(), !AppUpdateController.shared.isInstalling,
              NSClassFromString("XCTestCase") == nil else { return }
        observeGuardianReadiness { UpdateRecoveryAgentInstaller.readyGuardianPID() }
    }

    func observeGuardianReadiness(probe: @escaping @Sendable () -> Int32?) {
        readinessTask = Task { [weak self] in
            var delay: UInt64 = 500_000_000
            while !Task.isCancelled {
                let pid = await Task.detached(priority: .utility) { probe() }.value
                guard !Task.isCancelled, let self else { return }
                if let pid {
                    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
                    source.setEventHandler { [weak self] in self?.refreshGuardianReadiness() }
                    guardianExit = source
                    source.resume()
                    guardianRetrying = false
                    guardianReady = true
                    return
                }
                if delay >= 1_000_000_000 && !guardianRetrying { guardianRetrying = true }
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                delay = min(delay * 2, 15_000_000_000)
            }
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
