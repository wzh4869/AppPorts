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
        if let signatureIdentity { result["AppPortsSignatureIdentity"] = signatureIdentity }
        return result
    }

    static func suspendForApplicationUpdate() throws -> Bool {
        try ContainerMountAgentInstaller.suspendAgent(label: label)
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
        try ContainerMountAgentInstaller.configureAgent(
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
    }
}
