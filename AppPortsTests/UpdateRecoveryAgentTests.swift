import AppKit
import Foundation
import XCTest
@testable import AppPorts

final class UpdateRecoveryAgentTests: XCTestCase {
    func testDefaultEnabledChildDoesNotClaimApplicationRegistrationOrPollWhenIdle() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let process = try fixture.launch()
        defer { Fixture.terminate(process) }
        try await wait { try fixture.observation() != nil }
        let before = try XCTUnwrap(fixture.observation())
        XCTAssertEqual(before["windows"], 0)
        XCTAssertEqual(before["activationPolicy"], -1)
        XCTAssertNil(NSRunningApplication(processIdentifier: process.processIdentifier))
        try await Task.sleep(nanoseconds: 6_200_000_000)
        XCTAssertEqual(try fixture.observation()?["checks"], before["checks"])
        process.terminate()
        try await wait(timeout: 10) { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testDisabledChildExitsBeforeRegisteringWriterOrStartingMonitor() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set(false, forKey: BackgroundAgentPreferences.updateGuardianKey)
        XCTAssertTrue(fixture.defaults.synchronize())
        let process = try fixture.launch()
        defer { Fixture.terminate(process) }
        try await wait { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(try fixture.observation())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".writer-presence").path))
    }

    func testChildReceivesMigrationRecordEventAndStopsWhileRecoveryWaitsForLock() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let process = try fixture.launch()
        defer { Fixture.terminate(process) }
        try await wait { try fixture.observation() != nil }
        let checks = try XCTUnwrap(fixture.observation()?["checks"])
        let lock = OperationLock(fileURL: fixture.root.appendingPathComponent("operation.lock"), writerAdmissionCheck: {})
        XCTAssertTrue(lock.tryAcquire())
        defer { lock.release() }
        let target = try fixture.writePendingUpdate()
        let store = ShipItObservedTaskStore(directory: fixture.root.appendingPathComponent("shipit-recovery"))
        try await wait(timeout: 8) {
            try store.entries().first?.status == .queued && (fixture.observation()?["checks"] ?? 0) > checks
        }
        XCTAssertGreaterThan(try XCTUnwrap(fixture.observation()?["checks"]), checks)
        XCTAssertEqual(try store.entries().first?.status, .queued)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        process.terminate()
        try await wait { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try store.entries().first?.status, .attention)
        XCTAssertEqual(try store.entries().first?.offersRollback, true)
    }

    @MainActor
    func testDisablingGuardianWhileWaitingPersistsPauseAndReenablingResumesSameRow() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let target = try fixture.writePendingUpdate()
        let lock = OperationLock(fileURL: fixture.root.appendingPathComponent("operation.lock"), writerAdmissionCheck: {})
        XCTAssertTrue(lock.tryAcquire())
        defer { lock.release() }
        let store = ShipItObservedTaskStore(directory: fixture.root.appendingPathComponent("shipit-recovery"))
        let history = MigrationTaskHistoryStore(fileURL: fixture.root.appendingPathComponent("history.json"))
        let center = MigrationTaskCenter(historyStore: history, operationState: AppOperationState())
        let observer = ShipItTaskObserver(store: store, taskCenter: center, defaults: fixture.defaults)
        let first = try fixture.launch()
        defer { Fixture.terminate(first) }
        try await wait { try store.entries().first?.status == .queued }
        observer.refresh()
        let id = try XCTUnwrap(center.jobs.first?.id)
        fixture.defaults.set(false, forKey: BackgroundAgentPreferences.updateGuardianKey)
        XCTAssertTrue(fixture.defaults.synchronize())
        first.terminate()
        try await wait { !first.isRunning }
        observer.refresh()
        let paused = try XCTUnwrap(center.jobs.first)
        XCTAssertEqual(paused.id, id)
        XCTAssertTrue(paused.guardianPaused)
        XCTAssertEqual(paused.stateTitle, "已暂停自动处理".localized)
        XCTAssertTrue(paused.message.contains("Fixture"))
        XCTAssertFalse(center.hasAttention)
        XCTAssertNil(paused.recoveryAction)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let reopened = MigrationTaskCenter(historyStore: history, operationState: AppOperationState())
        let coldObserver = ShipItTaskObserver(store: store, taskCenter: reopened, defaults: fixture.defaults)
        coldObserver.refresh()
        XCTAssertTrue(try XCTUnwrap(reopened.jobs.first).guardianPaused)
        fixture.defaults.set(true, forKey: BackgroundAgentPreferences.updateGuardianKey)
        XCTAssertTrue(fixture.defaults.synchronize())
        let second = try fixture.launch()
        defer { Fixture.terminate(second) }
        try await wait { try store.entries().first?.status == .queued }
        coldObserver.refresh()
        XCTAssertEqual(reopened.jobs.map(\.id), [id])
        XCTAssertEqual(reopened.jobs.first?.status, .queued)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testReadinessMatchesOnlyLiveLaunchedBuildAndRegistration() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let worker = try fixture.launch()
        defer { Fixture.terminate(worker) }
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        try await wait {
            GuardianReadiness.matches(pid: worker.processIdentifier, executable: executable, directory: fixture.root)
        }
        XCTAssertFalse(GuardianReadiness.matches(pid: getpid(), executable: executable, directory: fixture.root))
        XCTAssertFalse(GuardianReadiness.matches(pid: worker.processIdentifier, executable: fixture.root, directory: fixture.root))
        worker.terminate()
        try await wait { !worker.isRunning }
        XCTAssertFalse(GuardianReadiness.matches(pid: worker.processIdentifier, executable: executable, directory: fixture.root))
    }

    @MainActor
    func testReadinessRecoversAfterProlongedStartupFailureAndClearsOnExit() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = fixture.root
        let records = root.appendingPathComponent("app-search-records.json")
        try Data("invalid".utf8).write(to: records)
        let worker = try fixture.launch()
        defer { Fixture.terminate(worker) }
        let pid = worker.processIdentifier
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let sync = AppLibraryAgentSync(synchronize: {})
        sync.observeGuardianReadiness {
            GuardianReadiness.matches(pid: pid, executable: executable, directory: root) ? pid : nil
        }
        try await wait {
            let checks = try fixture.observation()?["checks"] ?? 0
            return sync.guardianRetrying && checks >= 1
        }
        // Keep the worker alive past the old 12-second UI timeout. No launchd restart or wake event.
        try await Task.sleep(nanoseconds: 12_100_000_000)
        XCTAssertTrue(worker.isRunning)
        XCTAssertFalse(sync.guardianReady)
        XCTAssertTrue(sync.guardianRetrying)
        XCTAssertFalse(GuardianReadiness.matches(pid: pid, executable: executable, directory: root))
        XCTAssertGreaterThan(try XCTUnwrap(fixture.observation()?["checks"]), 1)
        try Data("[]".utf8).write(to: records, options: .atomic)
        try await wait(timeout: 35) { sync.guardianReady }
        XCTAssertFalse(sync.guardianRetrying)
        XCTAssertNil(sync.errorMessage)
        worker.terminate()
        try await wait { !worker.isRunning && !sync.guardianReady }
    }

    func testChildExitsCleanlyWhenItsAppBundleIsMovedOrRemoved() async throws {
        for mode in ["move", "remove"] {
            let fixture = try Fixture()
            defer { fixture.clean() }
            let installedApp = fixture.root.appendingPathComponent("Installed/AppPorts.app")
            try FileManager.default.createDirectory(at: installedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: installedApp)
            let executable = installedApp.appendingPathComponent("Contents/MacOS/AppPorts")

            let process = try fixture.launch(executableURL: executable)
            defer { Fixture.terminate(process) }
            try await wait { try fixture.observation() != nil }

            if mode == "move" {
                let backupApp = fixture.root.appendingPathComponent("backups/AppPorts-before-replace.app")
                try FileManager.default.createDirectory(at: backupApp.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: installedApp, to: backupApp)
            } else {
                try FileManager.default.removeItem(at: installedApp)
            }

            try await wait(timeout: 5) { !process.isRunning }
            XCTAssertEqual(process.terminationStatus, 0, "Stale update agent must exit cleanly on \(mode)")
        }
    }

    @MainActor
    private func wait(timeout: TimeInterval = 5, until condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            guard Date() < deadline else { throw NSError(domain: "AgentFixtureTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private final class Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        init() throws {
            root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AppPorts-AgentProcess-" + UUID().uuidString).resolvingSymlinksInPath().standardizedFileURL
            suite = "org.appports.update-agent-fixture." + root.lastPathComponent
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Caches"), withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: root.appendingPathComponent("app-search-records.json"))
        }

        func launch(executableURL: URL? = nil) throws -> Process {
            let process = Process()
            process.executableURL = executableURL ?? Bundle.main.executableURL
            process.arguments = [UpdateRecoveryAgentInstaller.launchArgument]
            // A distinct dataset and preferences domain; the sentinel isolates logging too.
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "APPPORTS_TEST_UPDATE_AGENT_ROOT": root.path, "XCTestConfigurationFilePath": root.appendingPathComponent("sentinel").path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }

        func observation() throws -> [String: Int]? {
            let file = root.appendingPathComponent("agent-observation.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Int]
        }

        func writePendingUpdate() throws -> URL {
            let identifier = "org.appports.agent.fixture"
            let cache = root.appendingPathComponent("Caches/" + identifier + ".ShipIt")
            let source = cache.appendingPathComponent("update.fixture/Fixture.app")
            let target = root.appendingPathComponent("External/Fixture.app")
            let local = root.appendingPathComponent("Local/Fixture.app")
            for (app, executable) in [(source, "Fixture"), (local, "launcher")] {
                try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": executable == "launcher" ? identifier + ".appports.stub" : identifier,
                    "CFBundleExecutable": executable, "CFBundleShortVersionString": "2.0", "CFBundleVersion": "2"], format: .xml, options: 0)
                    .write(to: app.appendingPathComponent("Contents/Info.plist"))
                try Data("untouched fixture payload".utf8).write(to: app.appendingPathComponent("Contents/MacOS/" + executable))
            }
            let resources = local.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try target.path.write(to: resources.appendingPathComponent("real_app_path.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let volume = try target.deletingLastPathComponent().resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            let request = ShipItUpdateRecovery.Request(updateBundleURL: source, targetBundleURL: target,
                bundleIdentifier: identifier, launchAfterInstallation: false)
            try JSONEncoder().encode(request).write(to: cache.appendingPathComponent("ShipItState.plist"), options: .atomic)
            try "Detected this as an install request\nInstallation error: Couldn't copy to \(target.path)\nShipIt quitting\n"
                .write(to: cache.appendingPathComponent("ShipIt_stderr.log"), atomically: true, encoding: .utf8)
            let record = AppSearchRecord(name: "Fixture", localPath: local.path, externalPath: target.path, volumeUUID: volume,
                expectsLocalEntry: true, targetBundleIdentifier: identifier)
            try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("app-search-records.json"), options: .atomic)
            return target
        }

        static func terminate(_ process: Process, timeout: TimeInterval = 5) {
            guard process.isRunning else { return }
            process.terminate()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
