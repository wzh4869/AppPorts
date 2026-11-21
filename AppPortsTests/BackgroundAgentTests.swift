import AppKit
import Foundation
import XCTest
@testable import AppPorts

final class BackgroundAgentTests: XCTestCase {
    func testOneAgentConfigurationFailureDoesNotPreventTheOtherFromBeingApplied() {
        var guardianApplied = false
        XCTAssertThrowsError(try BackgroundAgents.applyConfiguration(diskMaintenance: { throw CocoaError(.fileReadCorruptFile) },
            updateGuardian: { guardianApplied = true }))
        XCTAssertTrue(guardianApplied)
        var diskApplied = false
        XCTAssertThrowsError(try BackgroundAgents.applyConfiguration(diskMaintenance: { diskApplied = true },
            updateGuardian: { throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertTrue(diskApplied)
    }

    func testBothAgentsDefaultOnAndExplicitChoicesSurviveReload() throws {
        let suite = "BackgroundAgents-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(BackgroundAgentPreferences.diskMaintenanceEnabled(defaults: defaults))
        XCTAssertTrue(BackgroundAgentPreferences.updateGuardianEnabled(defaults: defaults))
        defaults.set(false, forKey: BackgroundAgentPreferences.diskMaintenanceKey)
        defaults.set(false, forKey: BackgroundAgentPreferences.updateGuardianKey)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(BackgroundAgentPreferences.diskMaintenanceEnabled(defaults: reloaded))
        XCTAssertFalse(BackgroundAgentPreferences.updateGuardianEnabled(defaults: reloaded))
        reloaded.set(true, forKey: BackgroundAgentPreferences.updateGuardianKey)
        XCTAssertFalse(BackgroundAgentPreferences.diskMaintenanceEnabled(defaults: reloaded))
        XCTAssertTrue(BackgroundAgentPreferences.updateGuardianEnabled(defaults: reloaded))
    }

    func testGuardianRegistrationReusesStablePathAndRestartsForSignatureChange() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = root.appendingPathComponent("guardian.plist")
        let executable = "/Applications/AppPorts.app/Contents/MacOS/AppPorts"
        let old = UpdateRecoveryAgentInstaller.launchAgentPayload(executablePath: executable, signatureIdentity: "old")
        try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0).write(to: definition)
        var commands: [[String]] = []
        try UpdateRecoveryAgentInstaller.synchronizeConfiguration(enabled: true, definitionURL: definition,
            running: URL(fileURLWithPath: "/tmp/build/AppPorts"), selectExecutable: { running, recorded in
                ContainerMountAgentInstaller.agentExecutablePath(running: running, recorded: recorded,
                    fileExists: { $0 == executable })
            }, signatureIdentity: { _ in "new" }, run: { commands.append($0); return 0 })
        XCTAssertEqual(commands.map { $0[0] }, ["enable", "bootout", "bootstrap", "print"])
        XCTAssertEqual(commands.last?.last, "gui/\(getuid())/\(UpdateRecoveryAgentInstaller.label)")
        let payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: definition), format: nil) as? [String: Any])
        XCTAssertEqual(payload["ProgramArguments"] as? [String], [executable, "--update-agent"])
        XCTAssertEqual(payload["AppPortsSignatureIdentity"] as? String, "new")
        XCTAssertEqual(payload["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(payload["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertNil(payload["StartInterval"])
        commands.removeAll()
        try UpdateRecoveryAgentInstaller.synchronizeConfiguration(enabled: true, definitionURL: definition,
            running: URL(fileURLWithPath: executable), selectExecutable: { _, recorded in recorded },
            signatureIdentity: { _ in "new" }, run: { commands.append($0); return 0 })
        XCTAssertEqual(commands.map { $0[0] }, ["enable", "print", "kickstart"])
        XCTAssertEqual(commands.last, ["kickstart", "gui/\(getuid())/\(UpdateRecoveryAgentInstaller.label)"])
    }

    func testTurningGuardianOffOnlyRemovesItsRegistrationAndDefinition() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = root.appendingPathComponent("guardian.plist")
        let receipt = root.appendingPathComponent("update-receipt.json")
        let bytes = Data("existing recovery materials".utf8)
        try bytes.write(to: receipt)
        try bytes.write(to: definition)
        var commands: [[String]] = []
        try UpdateRecoveryAgentInstaller.synchronizeConfiguration(enabled: false, definitionURL: definition,
            selectExecutable: { _, _ in XCTFail("Disabled agents must not select an executable"); return nil },
            run: { commands.append($0); return 0 })
        XCTAssertEqual(commands.map { $0[0] }, ["print", "bootout"])
        XCTAssertTrue(commands.allSatisfy { $0.last?.hasSuffix("/" + UpdateRecoveryAgentInstaller.label) == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: definition.path))
        XCTAssertEqual(try Data(contentsOf: receipt), bytes)
    }

    func testUnavailableLaunchctlDoesNotReportDisabledOrRemoveDefinition() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = root.appendingPathComponent("guardian.plist")
        let data = Data("keep definition".utf8)
        try data.write(to: definition)
        XCTAssertThrowsError(try ContainerMountAgentInstaller.removeAgent(label: "fixture", definitionURL: definition, run: { _ in 5 }))
        XCTAssertEqual(try Data(contentsOf: definition), data)
        XCTAssertNoThrow(try ContainerMountAgentInstaller.removeAgent(label: "fixture", definitionURL: definition, run: { _ in 113 }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: definition.path))
    }

    func testPausingForAppPortsUpdateKeepsDefinitionAndChecksBootoutFailure() throws {
        var commands: [String] = []
        XCTAssertTrue(try ContainerMountAgentInstaller.suspendAgent(label: "fixture", run: {
            commands.append($0[0]); return 0
        }))
        XCTAssertEqual(commands, ["print", "bootout"])
        var prints = 0
        XCTAssertThrowsError(try ContainerMountAgentInstaller.suspendAgent(label: "fixture", run: {
            if $0[0] == "print" { prints += 1; return prints == 1 ? 0 : 5 }
            return 5
        }))
        XCTAssertFalse(try ContainerMountAgentInstaller.suspendAgent(label: "fixture", run: { _ in 113 }))
    }

    @MainActor
    func testConfigurationFailureIsVisibleAndRetryClearsIt() async throws {
        let attempts = AttemptCounter()
        let sync = AppLibraryAgentSync(synchronize: {
            if await attempts.next() == 1 { throw CocoaError(.fileWriteNoPermission) }
        })
        sync.selectionDidChange()
        XCTAssertTrue(sync.isSynchronizing)
        while sync.isSynchronizing { await Task.yield() }
        XCTAssertNotNil(sync.errorMessage)
        sync.selectionDidChange()
        while sync.isSynchronizing { await Task.yield() }
        XCTAssertNil(sync.errorMessage)
        let count = await attempts.value
        XCTAssertEqual(count, 2)
    }

    func testDeferredTranslationsExplicitlyFallBackToEnglish() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Fixture.bundle/Contents/Resources")
        for (language, strings) in [
            ("en", "\"Background agents\" = \"Background agents\";"),
            ("zh-Hans", "\"Background agents\" = \"后台代理\";"),
            ("fr", "\"existing\" = \"existant\";")
        ] {
            let directory = resources.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try strings.write(to: directory.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.appports.translations", "CFBundleDevelopmentRegion": "zh-Hans"],
            format: .xml, options: 0).write(to: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: resources.deletingLastPathComponent().deletingLastPathComponent()))
        XCTAssertEqual("Background agents".localized(fallbackLanguage: "en", language: "fr", bundle: bundle), "Background agents")
        XCTAssertEqual("Background agents".localized(fallbackLanguage: "en", language: "zh-Hans", bundle: bundle), "后台代理")
    }

    func testGuardianSynchronizationForcesReloadAndWaitsForStaleRunningPIDEvenWhenDefinitionMatches() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = root.appendingPathComponent("guardian.plist")
        let executable = "/Applications/AppPorts.app/Contents/MacOS/AppPorts"
        let payload = UpdateRecoveryAgentInstaller.launchAgentPayload(executablePath: executable, signatureIdentity: nil)
        try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0).write(to: definition)

        var events: [String] = []
        try UpdateRecoveryAgentInstaller.synchronizeConfiguration(
            enabled: true,
            definitionURL: definition,
            running: URL(fileURLWithPath: executable),
            selectExecutable: { _, recorded in recorded },
            signatureIdentity: { _ in nil },
            runningServicePID: { 61264 },
            runningProcessIsCurrent: { _, _ in false },
            waitForExit: { events.append("wait:\($0)") },
            run: { events.append($0[0]); return 0 }
        )
        XCTAssertEqual(events, ["enable", "bootout", "wait:61264", "bootstrap", "print"])

        events.removeAll()
        try UpdateRecoveryAgentInstaller.synchronizeConfiguration(
            enabled: true,
            definitionURL: definition,
            running: URL(fileURLWithPath: executable),
            selectExecutable: { _, recorded in recorded },
            signatureIdentity: { _ in nil },
            runningServicePID: { 61264 },
            runningProcessIsCurrent: { pid, path in pid == 61264 && path == executable },
            waitForExit: { events.append("wait:\($0)") },
            run: { events.append($0[0]); return 0 }
        )
        XCTAssertEqual(events, ["enable", "print"])
    }

    func testParseServicePIDExtractsRunningPIDFromLaunchctlPrint() {
        let sample = """
        gui/501/com.shimoko.AppPorts.update-guardian = {
            state = running
            runs = 1
            pid = 37427
            forks = 0
        }
        """
        XCTAssertEqual(ContainerMountAgentInstaller.parseServicePID(from: sample), 37427)
        XCTAssertNil(ContainerMountAgentInstaller.parseServicePID(from: "state = not running\n"))
        XCTAssertNil(ContainerMountAgentInstaller.parseServicePID(from: "pid = 0\n"))
    }

    func testSynchronizeAgentsUsesFileLockWithoutWriterAdmissionAndWaitsForActiveHolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("operation.lock")
        let holder = OperationLock(fileURL: lockURL, writerAdmissionCheck: {})
        XCTAssertTrue(holder.tryAcquire())

        let state = AttemptCounter()
        let syncTask = Task {
            try await BackgroundAgents.synchronizeAgents(
                makeLock: { OperationLock(fileURL: lockURL, writerAdmissionCheck: {}) },
                diskMaintenance: { },
                updateGuardian: {
                    Task { _ = await state.next() }
                }
            )
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let beforeRelease = await state.value
        XCTAssertEqual(beforeRelease, 0, "Active operation.lock holder must delay LaunchAgent reload")

        holder.release()
        try await syncTask.value
        let deadline = Date().addingTimeInterval(2)
        while await state.value == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let afterRelease = await state.value
        XCTAssertEqual(afterRelease, 1)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundAgents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private actor AttemptCounter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }
}
