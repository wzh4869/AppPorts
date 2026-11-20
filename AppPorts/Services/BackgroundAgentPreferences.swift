import Foundation

enum BackgroundAgentPreferences {
    static let diskMaintenanceKey = "diskMaintenanceAgentEnabled"
    static let updateGuardianKey = "applicationUpdateGuardianEnabled"

    static func diskMaintenanceEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: diskMaintenanceKey) as? Bool ?? true
    }

    static func updateGuardianEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: updateGuardianKey) as? Bool ?? true
    }
}

enum BackgroundAgents {
    static func synchronize() async throws {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        try await synchronizeAgents(
            makeLock: { OperationLock(writerAdmissionCheck: {}) },
            isInstalling: { await AppUpdateController.shared.isInstalling },
            diskMaintenance: { try ContainerMountAgentInstaller.synchronizeConfiguration() },
            updateGuardian: { try UpdateRecoveryAgentInstaller.synchronizeConfiguration() }
        )
    }

    /// LaunchAgent reconciliation only mutates launchd registrations, never user data stores.
    /// Acquiring the exclusive file lock without WriterAdmission prevents a stale agent from a
    /// replaced app bundle from deadlocking the very bootout/bootstrap that replaces it, while
    /// still waiting if an agent actively holds `operation.lock`.
    static func synchronizeAgents(
        makeLock: () -> OperationLock,
        isInstalling: @escaping @Sendable () async -> Bool = { false },
        diskMaintenance: () throws -> Void,
        updateGuardian: () throws -> Void
    ) async throws {
        let lock = makeLock()
        while !Task.isCancelled {
            if await lock.acquire(timeout: OperationLock.appWaitTimeout) {
                defer { lock.release() }
                try Task.checkCancellation()
                guard await !isInstalling() else { return }
                try applyConfiguration(diskMaintenance: diskMaintenance, updateGuardian: updateGuardian)
                return
            }
            guard lock.diagnosticFailure(scope: .global).reason == .globalLockBusy else {
                throw lock.diagnosticFailure(scope: .global)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CancellationError()
    }

    /// One agent's configuration failure must not keep the other agent enabled.
    static func applyConfiguration(diskMaintenance: () throws -> Void, updateGuardian: () throws -> Void) throws {
        var failures: [String] = []
        do { try diskMaintenance() }
        catch { failures.append("Disk maintenance agent".localized + ": " + error.localizedDescription) }
        do { try updateGuardian() }
        catch { failures.append("Application update guardian".localized + ": " + error.localizedDescription) }
        guard failures.isEmpty else {
            throw NSError(domain: "AppPorts.BackgroundAgents", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
        }
    }
}
