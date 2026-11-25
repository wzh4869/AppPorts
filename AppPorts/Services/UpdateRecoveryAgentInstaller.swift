import Foundation

enum UpdateRecoveryAgentInstaller {
    static let label = "com.shimoko.AppPorts.update-guardian"
    static let launchArgument = "--update-agent"

    static var definitionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func launchAgentPayload(executablePath: String, signatureIdentity: String? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, launchArgument],
            "AssociatedBundleIdentifiers": ["com.shimoko.AppPorts"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": ["Aqua"]
        ]
        if let file = try? SignatureSnapshot.info(at: URL(fileURLWithPath: executablePath)) {
            result["AppPortsExecutableIdentity"] = "\(file.st_dev):\(file.st_ino)"
        }
        if let signatureIdentity { result["AppPortsSignatureIdentity"] = signatureIdentity }
        return result
    }

    static func suspendForApplicationUpdate() throws -> Bool {
        try ContainerMountAgentInstaller.suspendAgent(label: label)
    }

    static func readyGuardianPID() -> Int32? {
        guard BackgroundAgentPreferences.updateGuardianEnabled(),
              let executable = Bundle.main.executableURL,
              let pid = ContainerMountAgentInstaller.runningServicePID(label: label),
              GuardianReadiness.matches(pid: pid, executable: executable, directory: WriterAdmission.defaultDataDirectory)
        else { return nil }
        return pid
    }

    /// The caller holds the shared operation lock before stopping a live worker.
    static func synchronizeConfiguration(
        enabled: Bool = BackgroundAgentPreferences.updateGuardianEnabled(),
        definitionURL: URL = Self.definitionURL,
        running: URL = Bundle.main.executableURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AppPorts"),
        selectExecutable: (URL, String?) -> String? = { ContainerMountAgentInstaller.agentExecutablePath(running: $0, recorded: $1) },
        signatureIdentity: (String) -> String? = ContainerMountAgentInstaller.executableSignatureIdentity,
        runningServicePID: (() -> Int32?)? = nil,
        runningProcessIsCurrent: ((Int32, String) -> Bool)? = nil,
        waitForExit: ((Int32) -> Void)? = nil,
        run: ([String]) -> Int32 = ContainerMountAgentInstaller.runLaunchctl
    ) throws {
        guard enabled else {
            try ContainerMountAgentInstaller.removeAgent(label: label, definitionURL: definitionURL, run: run)
            return
        }
        let existing = try? Data(contentsOf: definitionURL)
        let recorded = existing.flatMap(ContainerMountAgentInstaller.recordedExecutablePath(inAgentPlist:))
        guard let executable = selectExecutable(running, recorded) else {
            throw ContainerMountAgentInstaller.InstallError.temporaryLocation
        }
        let payload = launchAgentPayload(executablePath: executable,
            signatureIdentity: signatureIdentity(executable))
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let livePID = (runningServicePID ?? {
            isRunningUnitTests ? nil : ContainerMountAgentInstaller.runningServicePID(label: label)
        })()
        let checkCompliance = runningProcessIsCurrent ?? { pid, expectedPath in
            WriterAdmission.isProcessCompliantWriter(pid: pid, expectedExecutablePath: expectedPath)
        }
        let staleRunningAgent = livePID.map { !checkCompliance($0, executable) } ?? false
        if staleRunningAgent, let livePID {
            AppLogger.shared.logContext("检测到旧版后台更新守护进程，准备重启同步", details: [
                ("stale_pid", String(livePID)),
                ("expected_executable", executable)
            ], level: "WARN")
        }
        let reloaded = try ContainerMountAgentInstaller.configureAgent(
            definitionMatches: existing == data,
            writeDefinition: {
                try FileManager.default.createDirectory(at: definitionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: definitionURL, options: .atomic)
            },
            run: run,
            serviceLabel: label,
            definitionURL: definitionURL,
            forceReload: staleRunningAgent,
            previousPID: livePID,
            waitForExit: waitForExit
        )
        // A clean exit leaves the job registered. Kickstart without -k also preserves
        // a worker launchd may have started between the PID check and this request.
        if !reloaded && livePID == nil {
            guard run(["kickstart", "gui/\(getuid())/\(label)"]) == 0 else {
                throw ContainerMountAgentInstaller.InstallError.launchAgentLoadFailed
            }
        }
    }
}

enum UpdateGuardianReporting {
    struct Snapshot: Equatable, Sendable {
        let enabled: Bool
        let ready: Bool
        let monitoredCount: Int?
        let receiptCount: Int
        let pendingRollbackCount: Int
    }

    static func collect(
        defaults: UserDefaults = .standard,
        dataDirectory: URL = WriterAdmission.defaultDataDirectory,
        readyPID: (() -> Int32?)? = nil
    ) -> Snapshot {
        let enabled = BackgroundAgentPreferences.updateGuardianEnabled(defaults: defaults)
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let ready: Bool
        if let readyPID {
            ready = enabled && readyPID() != nil
        } else if isRunningUnitTests {
            ready = false
        } else {
            ready = enabled && UpdateRecoveryAgentInstaller.readyGuardianPID() != nil
        }
        let useDirectory = readyPID != nil || dataDirectory != WriterAdmission.defaultDataDirectory || !isRunningUnitTests
        let monitoredCount: Int?
        let receiptCount: Int
        let pendingRollbackCount: Int
        if useDirectory {
            let store = AppSearchRecordStore(fileURL: dataDirectory.appendingPathComponent("app-search-records.json"))
            monitoredCount = try? ShipItUpdateRecovery(records: store).monitoredBundleIdentifiers().count
            let counts = recoveryDirectoryCounts(at: dataDirectory.appendingPathComponent("shipit-recovery"))
            receiptCount = counts.receipts
            pendingRollbackCount = counts.pendingRollbacks
        } else {
            monitoredCount = nil
            receiptCount = 0
            pendingRollbackCount = 0
        }
        return Snapshot(enabled: enabled, ready: ready, monitoredCount: monitoredCount,
                        receiptCount: receiptCount, pendingRollbackCount: pendingRollbackCount)
    }

    private static func recoveryDirectoryCounts(at directory: URL) -> (receipts: Int, pendingRollbacks: Int) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return (0, 0)
        }
        var receipts = 0
        var rollbackKeys: Set<String> = []
        for name in entries where !name.hasPrefix(".") {
            if name.hasSuffix(".rollback.json") {
                rollbackKeys.insert(String(name.dropLast(".rollback.json".count)))
            } else if name.hasSuffix(".rollback-intent.json") {
                rollbackKeys.insert(String(name.dropLast(".rollback-intent.json".count)))
            } else if name.hasSuffix(".json"), !name.hasSuffix(".task.json") {
                receipts += 1
            }
        }
        return (receipts, rollbackKeys.count)
    }

    /// Aggregate guardian status contains no application names, paths, or credentials.
    static func diagnosticSection(_ snapshot: Snapshot? = nil) -> [String] {
        let value = snapshot ?? collect()
        return [
            "update_guardian",
            "  enabled: \(value.enabled)",
            "  ready: \(value.ready)",
            "  monitored_count: \(value.monitoredCount.map(String.init) ?? "unknown")",
            "  receipt_count: \(value.receiptCount)",
            "  pending_rollback_count: \(value.pendingRollbackCount)"
        ]
    }
}
