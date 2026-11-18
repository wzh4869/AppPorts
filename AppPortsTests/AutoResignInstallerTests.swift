import Foundation
import Testing
@testable import AppPorts

@Suite("Background signing coordination", .serialized)
struct AutoResignInstallerTests {
    @Test("Login re-signing is disabled on every macOS version", arguments: [
        (12, false), (15, false), (26, false), (27, false), (28, false), (99, false), (0, false)
    ])
    func systemSupport(majorVersion: Int, supported: Bool) {
        #expect(AutoResignInstaller.supportsLoginResigning(macOSMajorVersion: majorVersion) == supported)
    }

    @Test("Older systems also stop their existing login writer", arguments: [true, false])
    func preservesOlderSystem(enabled: Bool) async throws {
        let fixture = try PolicyFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(enabled, forKey: AutoResignInstaller.enabledDefaultsKey)
        var stopCalls = 0

        let disabled = try await fixture.apply(majorVersion: 26) { stopCalls += 1 }

        #expect(disabled)
        #expect(stopCalls == 1)
        #expect(!fixture.defaults.bool(forKey: AutoResignInstaller.enabledDefaultsKey))
        #expect(!FileManager.default.fileExists(atPath: fixture.script.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.agent.path))
    }

    @Test("Upgrading clears both stored and legacy-default opt-ins", arguments: [true, false, nil] as [Bool?])
    func disablesExistingInstallation(previousSetting: Bool?) async throws {
        let fixture = try PolicyFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(previousSetting, forKey: AutoResignInstaller.enabledDefaultsKey)
        var stopCalls = 0

        let disabled = try await fixture.apply(majorVersion: 27) {
            stopCalls += 1
            #expect(!fixture.defaults.bool(forKey: AutoResignInstaller.enabledDefaultsKey))
            // Keep the plist and a harmless script until the running process group has exited.
            #expect(FileManager.default.fileExists(atPath: fixture.agent.path))
            let guardedScript = try String(contentsOf: fixture.script, encoding: .utf8)
            #expect(guardedScript.contains("exit 0"))
            #expect(!guardedScript.contains("codesign"))
        }

        #expect(disabled)
        #expect(stopCalls == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.agent.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.script.path))
        #expect(fixture.defaults.object(forKey: AutoResignInstaller.enabledDefaultsKey) as? Bool == false)
        #expect(try String(contentsOf: fixture.backup, encoding: .utf8) == "keep signature backup")
        #expect(try String(contentsOf: fixture.mountAgent, encoding: .utf8) == "keep mount agent")
    }

    @Test("A loaded task must be checked even after its plist is gone")
    func stopsOrphanedTask() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.agent)
        try FileManager.default.removeItem(at: fixture.script)
        fixture.defaults.set(true, forKey: AutoResignInstaller.enabledDefaultsKey)
        var stopCalls = 0

        try await fixture.apply(majorVersion: 28) { stopCalls += 1 }
        try await fixture.apply(majorVersion: 28) { stopCalls += 1 }

        #expect(stopCalls == 2)
        #expect(!fixture.defaults.bool(forKey: AutoResignInstaller.enabledDefaultsKey))
        #expect(!FileManager.default.fileExists(atPath: fixture.script.path))
        #expect(fixture.defaults.string(forKey: AutoResignInstaller.policyErrorDefaultsKey) == nil)
    }

    @Test("A failed stop retains a harmless script and exposes an error until retry succeeds")
    func stopFailureAndRetry() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: AutoResignInstaller.enabledDefaultsKey)

        await #expect(throws: AutoResignInstaller.InstallError.self) {
            try await fixture.apply(majorVersion: 27) {
                throw AutoResignInstaller.InstallError.backgroundTaskStillRunning
            }
        }

        #expect(!fixture.defaults.bool(forKey: AutoResignInstaller.enabledDefaultsKey))
        #expect(fixture.defaults.string(forKey: AutoResignInstaller.policyErrorDefaultsKey)?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: fixture.agent.path))
        // Running the retained script only proves it stays harmless; the deadline
        // is fixture headroom, not a behaviour assertion, so it survives a loaded
        // CI runner.
        let result = try await ProcessCommandRunner().run(executable: "/bin/bash", arguments: [fixture.script.path], timeout: 20)
        #expect(result.status == 0)
        #expect(!result.timedOut)

        try await fixture.apply(majorVersion: 27) {}
        #expect(fixture.defaults.string(forKey: AutoResignInstaller.policyErrorDefaultsKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.agent.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.script.path))
    }

    @Test(
        "Failed plist removal keeps the disabled script for the next login",
        .enabled(if: getuid() != 0, "Root ignores read-only directory permissions")
    )
    func cleanupFailureRetainsGuard() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.cleanup() }
        let agentDirectory = fixture.agent.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: agentDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agentDirectory.path) }
        var stopCalls = 0

        await #expect(throws: (any Error).self) {
            try await fixture.apply(majorVersion: 27) { stopCalls += 1 }
        }

        #expect(stopCalls == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.agent.path))
        #expect(try String(contentsOf: fixture.script, encoding: .utf8).contains("exit 0"))
        #expect(fixture.defaults.string(forKey: AutoResignInstaller.policyErrorDefaultsKey)?.isEmpty == false)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agentDirectory.path)
        try await fixture.apply(majorVersion: 27) {}
        #expect(!FileManager.default.fileExists(atPath: fixture.agent.path))
        #expect(fixture.defaults.string(forKey: AutoResignInstaller.policyErrorDefaultsKey) == nil)
    }

    @Test("The installed script is unconditionally read-only, including old classic preferences")
    func loginScriptNeverMutatesApplications() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.cleanup() }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppPorts/AppPorts-ReSign.sh")
        let script = try String(contentsOf: source, encoding: .utf8)
        #expect(!script.contains("/usr/bin/codesign"))
        #expect(!script.contains("xattr"))
        #expect(!script.contains("rm -"))
        #expect(!script.contains("defaults read"))
        let isolatedScript = fixture.root.appendingPathComponent("login-script.sh")
        try ("CLASSIC_MODE=1\n" + script).write(to: isolatedScript, atomically: true, encoding: .utf8)
        // Same fixture headroom as above: the script must not touch anything, and
        // a slow runner must not turn that into a failure.
        let result = try await ProcessCommandRunner().run(executable: "/bin/bash", arguments: [isolatedScript.path], timeout: 20)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(try String(contentsOf: fixture.backup, encoding: .utf8) == "keep signature backup")
    }

    @Test("An explicitly absent login task needs no stop command")
    func absentTask() async throws {
        let runner = Runner(responses: [.result(status: 113, text: "Could not find service")])
        try await AutoResignInstaller.stopBackgroundTask(runner: runner)
        #expect(await runner.calls.count == 1)
    }

    @Test("Permission errors cannot be mistaken for an absent task")
    func queryFailure() async throws {
        let runner = Runner(responses: [.result(status: 1, text: "Operation not permitted")])
        await #expect(throws: AutoResignInstaller.InstallError.self) {
            try await AutoResignInstaller.stopBackgroundTask(runner: runner)
        }
        #expect(await runner.calls.count == 1)
    }

    @Test("Supported systems wait for a single service to exit")
    func waitForBootout() async throws {
        let runner = Runner(responses: [.result(text: "pid = 99999"), .result(text: "bootout [--wait]"), .result()])
        try await AutoResignInstaller.stopBackgroundTask(runner: runner, processGroupIsRunning: { _ in false })
        let commands = await runner.calls
        #expect(commands.last?.prefix(2) == ["bootout", "--wait"])
        #expect(commands.last?.last?.hasSuffix("/com.shimoko.AppPorts.re-sign") == true)
    }

    @Test("Old systems require the entire process group to exit")
    func refusesLiveChildProcesses() async throws {
        let runner = Runner(responses: [.result(text: "pid = 99999"), .result(text: "bootout <service>"), .result()])
        await #expect(throws: AutoResignInstaller.InstallError.self) {
            try await AutoResignInstaller.stopBackgroundTask(runner: runner, processGroupIsRunning: { _ in true }, timeout: 0)
        }
        #expect(await runner.calls.last?.first == "bootout")
        #expect(await runner.calls.last?.contains("--wait") == false)
    }

    @Test("A timed-out stop never permits signature restoration")
    func refusesStopTimeout() async throws {
        let runner = Runner(responses: [.result(text: "pid = 99999"), .result(text: "--wait"), .result(timedOut: true)])
        await #expect(throws: AutoResignInstaller.InstallError.self) {
            try await AutoResignInstaller.stopBackgroundTask(runner: runner, processGroupIsRunning: { _ in false })
        }
    }

    private struct PolicyFixture {
        static let oldScript = "#!/bin/bash\n# Old login codesign task\nexit 73\n"
        let root: URL
        let defaults: UserDefaults
        let suiteName: String
        var agent: URL { root.appendingPathComponent("LaunchAgents/com.shimoko.AppPorts.re-sign.plist") }
        var mountAgent: URL { root.appendingPathComponent("LaunchAgents/com.shimoko.AppPorts.container-mount.plist") }
        var script: URL { root.appendingPathComponent("AppPorts/AppPorts-ReSign.sh") }
        var backup: URL { root.appendingPathComponent("AppPorts/signature-backups/keep.plist") }

        init() throws {
            suiteName = "AppPortsAutoResignTests-" + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: suiteName))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
            try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old login agent".utf8).write(to: agent)
            try Data(Self.oldScript.utf8).write(to: script)
            try Data("keep signature backup".utf8).write(to: backup)
            try Data("keep mount agent".utf8).write(to: mountAgent)
        }

        @discardableResult
        func apply(majorVersion: Int, stop: () async throws -> Void) async throws -> Bool {
            try await AutoResignInstaller.disableIfUnsupported(
                macOSMajorVersion: majorVersion,
                defaults: defaults,
                agentPlistURL: agent,
                scriptURL: script,
                stopTask: stop
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private actor Runner: ShellCommandRunning {
        var responses: [Response]
        private(set) var calls: [[String]] = []
        init(responses: [Response]) { self.responses = responses }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            calls.append(arguments)
            let response = responses.removeFirst()
            return ShellCommandResult(status: response.status, standardOutput: Data(response.text.utf8), standardError: Data(), timedOut: response.timedOut)
        }
    }

    private struct Response {
        let status: Int32
        let text: String
        let timedOut: Bool
        static func result(status: Int32 = 0, text: String = "", timedOut: Bool = false) -> Self {
            Self(status: status, text: text, timedOut: timedOut)
        }
    }
}
