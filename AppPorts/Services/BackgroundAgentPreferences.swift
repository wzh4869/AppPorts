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
        let lock = OperationLock()
        while !Task.isCancelled {
            if await lock.acquire(timeout: OperationLock.appWaitTimeout) {
                defer { lock.release() }
                try Task.checkCancellation()
                guard await !AppUpdateController.shared.isInstalling else { return }
                try applyConfiguration(diskMaintenance: { try ContainerMountAgentInstaller.synchronizeConfiguration() },
                                       updateGuardian: { try UpdateRecoveryAgentInstaller.synchronizeConfiguration() })
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
        catch { failures.append("Disk maintenance agent".localized(fallbackLanguage: "en") + ": " + error.localizedDescription) }
        do { try updateGuardian() }
        catch { failures.append("Application update guardian".localized(fallbackLanguage: "en") + ": " + error.localizedDescription) }
        guard failures.isEmpty else {
            throw NSError(domain: "AppPorts.BackgroundAgents", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
        }
    }
}
