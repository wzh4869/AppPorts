import Foundation

/// Only copying/reading checkpoints may wait. Entry switching and independent
/// recovery retain their existing transaction boundaries and are never suspended.
final class MigrationTaskControl: @unchecked Sendable {
    let expectedAppStart: AppMigrationStartBlock?

    init(expectedAppStart: AppMigrationStartBlock? = nil) {
        self.expectedAppStart = expectedAppStart
    }

    struct State: Sendable {
        var pauseRequested = false
        var paused = false
        var cancelled = false
    }
    private let condition = NSCondition()
    private var state = State()
    private var criticalSection = false
    private var accumulatedPausedDuration: TimeInterval = 0
    private var pausedSinceUptime: TimeInterval?

    func snapshot() -> State {
        condition.lock(); defer { condition.unlock() }
        return state
    }

    func pausedDuration(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        condition.lock(); defer { condition.unlock() }
        var total = accumulatedPausedDuration
        if let since = pausedSinceUptime {
            total += max(0, now - since)
        }
        return total
    }

    private func setPausedLocked(_ newValue: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if newValue {
            if pausedSinceUptime == nil {
                pausedSinceUptime = now
            }
        } else if let since = pausedSinceUptime {
            accumulatedPausedDuration += max(0, now - since)
            pausedSinceUptime = nil
        }
        state.paused = newValue
    }

    func pause() {
        condition.lock(); defer { condition.unlock() }
        guard !state.cancelled else { return }
        state.pauseRequested = true
    }

    func resume(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        condition.lock(); defer { condition.unlock() }
        state.pauseRequested = false
        setPausedLocked(false, now: now)
        condition.broadcast()
    }

    func cancel(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        condition.lock(); defer { condition.unlock() }
        state.cancelled = true
        state.pauseRequested = false
        setPausedLocked(false, now: now)
        condition.broadcast()
    }

    /// Used only in file traversal and copy loops, never on the main thread.
    func checkpoint() throws {
        condition.lock()
        defer { condition.unlock() }
        while state.pauseRequested && !state.cancelled && !criticalSection && !Thread.isMainThread {
            setPausedLocked(true)
            condition.wait()
        }
        setPausedLocked(false)
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
            setPausedLocked(false)
            return false
        }
        setPausedLocked(true)
        return true
    }

    func setCriticalSection(_ value: Bool) {
        condition.lock(); defer { condition.unlock() }
        criticalSection = value
        if value {
            setPausedLocked(false)
            condition.broadcast()
        }
    }
}

enum MigrationExecution {
    @TaskLocal static var dataTaskID: UUID?
    @TaskLocal static var control: MigrationTaskControl?
    /// Managed jobs have already claimed all overlapping paths. Their leases
    /// share one process lock, still excluding agents and older app instances.
    @TaskLocal static var managed = false

    static func checkpoint() throws {
        try Task.checkCancellation()
        try control?.checkpoint()
    }
}
