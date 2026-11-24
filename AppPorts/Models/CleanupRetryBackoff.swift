import Foundation

/// Scheduling facts never authorize removal or change recovery evidence.
enum CleanupRetryBackoff {
    static let delays: [TimeInterval] = [60, 300, 1800, 7200, 86400]

    static func afterFailure(_ previousCount: Int, now: Date) -> (count: Int, nextAttempt: Date) {
        let count = min(max(0, previousCount), delays.count - 1) + 1
        return (count, now.addingTimeInterval(delays[count - 1]))
    }

    static func shouldDefer(until nextAttempt: Date?, now: Date) -> Bool {
        nextAttempt.map { now < $0 } ?? false
    }
}

enum CleanupRetryTarget: Sendable {
    case transfer(UUID), legacy(UUID), material(UUID)
}

/// Inherited by nested lineage cleanup; foreground operations bypass only the
/// schedule, never a user's keep decision or the deletion proof.
enum CleanupRetryContext {
    @TaskLocal static var automatic = false
    @TaskLocal static var now: @Sendable () -> Date = { Date() }

    static func shouldDefer(_ transfer: DataTransferRecord) -> Bool {
        automatic && CleanupRetryBackoff.shouldDefer(until: transfer.nextAutomaticRetryAt, now: now())
    }

    static func record(_ target: CleanupRetryTarget, failed: Bool, store: ContainerMountStore, failureReason: String? = nil) {
        do { try store.recordCleanupRetry(target, failed: failed, now: now(), failureReason: failureReason) }
        catch { AppLogger.shared.logError("无法保存清理重试时间", error: error, errorCode: "CLEANUP-RETRY-SAVE-FAILED") }
    }

    /// A nested cleanup may already have scheduled this record. Do not count
    /// its failure twice or reset a predecessor's deadline from a stale loop.
    static func recordFailureIfUnchanged(_ initial: DataTransferRecord, store: ContainerMountStore) {
        do {
            guard let current = try store.transfer(operationID: initial.operationID),
                  current.retryFailureCount == initial.retryFailureCount,
                  current.nextAutomaticRetryAt == initial.nextAutomaticRetryAt else { return }
            record(.transfer(initial.operationID), failed: true, store: store)
        } catch { AppLogger.shared.logError("无法保存清理重试时间", error: error, errorCode: "CLEANUP-RETRY-SAVE-FAILED") }
    }
}
