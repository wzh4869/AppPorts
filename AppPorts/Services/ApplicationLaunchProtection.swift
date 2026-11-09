import Foundation

enum ApplicationLaunchProtection {
    @TaskLocal private static var held: Set<String> = []

    static func contains(_ identifier: String?, directory: URL) -> Bool {
        guard let identifier else { return true }
        return held.contains(directory.standardizedFileURL.path + "\n" + identifier)
    }

    /// Nested recovery stays protected through cancellation and safe completion.
    static func run<T>(identifier: String?, directory: URL, operation: () async throws -> T) async throws -> T {
        guard let identifier, !contains(identifier, directory: directory) else { return try await operation() }
        let lease: ApplicationLaunchGate.Lease
        do { lease = try ApplicationLaunchGate.acquire(bundleIdentifier: identifier, migrating: true, directory: directory) }
        catch {
            AppLogger.shared.logError("无法取得应用启动保护", error: error)
            throw DataOperationSafety.Failure.inspection("其他程序正在处理磁盘，请稍后重试。".localized)
        }
        defer { withExtendedLifetime(lease) {} }
        return try await $held.withValue(held.union([directory.standardizedFileURL.path + "\n" + identifier])) {
            try await operation()
        }
    }

    /// Recovery ignores the caller's cancellation but retains its launch lease
    /// context. The caller awaits completion while still owning that lease.
    static func detached<T: Sendable>(priority: TaskPriority, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let context = held
        return try await Task.detached(priority: priority) {
            try await $held.withValue(context) {
                try await operation()
            }
        }.value
    }
}
