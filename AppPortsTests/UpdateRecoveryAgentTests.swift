import AppKit
import Foundation
import XCTest
@testable import AppPorts

final class UpdateRecoveryAgentTests: XCTestCase {
    func testDefaultEnabledChildDoesNotClaimApplicationRegistrationOrPollWhenIdle() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let process = try fixture.launch()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        try await wait { try fixture.observation() != nil }
        let before = try XCTUnwrap(fixture.observation())
        XCTAssertEqual(before["windows"], 0)
        XCTAssertEqual(before["activationPolicy"], -1)
        XCTAssertNil(NSRunningApplication(processIdentifier: process.processIdentifier))
        try await Task.sleep(nanoseconds: 6_200_000_000)
        XCTAssertEqual(try fixture.observation()?["checks"], before["checks"])
        process.terminate()
        try await wait { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testDisabledChildExitsBeforeRegisteringWriterOrStartingMonitor() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set(false, forKey: BackgroundAgentPreferences.updateGuardianKey)
        XCTAssertTrue(fixture.defaults.synchronize())
        let process = try fixture.launch()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        try await wait { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(try fixture.observation())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".writer-presence").path))
    }

    func testChildReceivesMigrationRecordEventAndStopsWhileRecoveryWaitsForLock() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let process = try fixture.launch()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
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

        func launch() throws -> Process {
            let process = Process()
            process.executableURL = Bundle.main.executableURL
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

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
