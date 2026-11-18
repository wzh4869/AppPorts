import Foundation

/// Only copying/reading checkpoints may wait. Entry switching and independent
/// recovery retain their existing transaction boundaries and are never suspended.
final class MigrationTaskControl: @unchecked Sendable {
    struct State: Sendable {
        var pauseRequested = false
        var paused = false
        var cancelled = false
    }
    private let condition = NSCondition()
    private var state = State()
    private var criticalSection = false

    func snapshot() -> State {
        condition.lock(); defer { condition.unlock() }
        return state
    }

    func pause() {
        condition.lock(); defer { condition.unlock() }
        guard !state.cancelled else { return }
        state.pauseRequested = true
    }

    func resume() {
        condition.lock(); defer { condition.unlock() }
        state.pauseRequested = false
        state.paused = false
        condition.broadcast()
    }

    func cancel() {
        condition.lock(); defer { condition.unlock() }
        state.cancelled = true
        state.pauseRequested = false
        state.paused = false
        condition.broadcast()
    }

    /// Used only in file traversal and copy loops, never on the main thread.
    func checkpoint() throws {
        condition.lock()
        defer { condition.unlock() }
        while state.pauseRequested && !state.cancelled && !criticalSection && !Thread.isMainThread {
            state.paused = true
            condition.wait()
        }
        state.paused = false
        if state.cancelled { throw CancellationError() }
    }

    func checkpointAsync() async throws {
        while shouldWaitForPause() {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try checkpoint()
        try Task.checkCancellation()
    }

    private func shouldWaitForPause() -> Bool {
        condition.lock(); defer { condition.unlock() }
        if !state.pauseRequested || state.cancelled || criticalSection {
            state.paused = false
            return false
        }
        state.paused = true
        return true
    }

    func setCriticalSection(_ value: Bool) {
        condition.lock(); defer { condition.unlock() }
        criticalSection = value
        if value {
            state.paused = false
            condition.broadcast()
        }
    }
}

enum MigrationExecution {
    @TaskLocal static var control: MigrationTaskControl?
    /// Managed jobs have already claimed all overlapping paths. Their leases
    /// share one process lock, still excluding agents and older app instances.
    @TaskLocal static var managed = false

    static func checkpoint() throws {
        try Task.checkCancellation()
        try control?.checkpoint()
    }
}
