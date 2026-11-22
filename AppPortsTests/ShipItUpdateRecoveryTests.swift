import AppKit
import Foundation
import Darwin
import XCTest
@testable import AppPorts

final class ShipItUpdateRecoveryTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private final class ActivityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ShipItUpdateRecovery.Activity = .applicationRunning
        init(_ value: ShipItUpdateRecovery.Activity = .applicationRunning) { self.value = value }
        func read() -> ShipItUpdateRecovery.Activity { lock.lock(); defer { lock.unlock() }; return value }
        func stopped() { lock.lock(); defer { lock.unlock() }; value = .idle }
    }

    private final class Fixture {
        let stateDomain = "org.appports.shipit-state-tests." + UUID().uuidString
        let root: URL
        let caches: URL
        let target: URL
        let local: URL
        let source: URL
        let state: URL
        let log: URL
        let store: AppSearchRecordStore
        let identifier: String

        deinit {
            for key in [ShipItInstallerState.ownedBundleKey, ShipItInstallerState.attemptsKey, "unrelated"] {
                CFPreferencesSetValue(key as CFString, nil, stateDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            }
            CFPreferencesSynchronize(stateDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }

        init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ShipIt-\(UUID().uuidString)"),
             identifier: String = "org.appports.shipit.fixture", externalDirectory: URL? = nil) throws {
            self.root = root.resolvingSymlinksInPath().standardizedFileURL
            self.identifier = identifier
            caches = self.root.appendingPathComponent("Caches")
            let cache = caches.appendingPathComponent(identifier + ".ShipIt")
            source = cache.appendingPathComponent("update.fixture/Fixture.app")
            state = cache.appendingPathComponent("ShipItState.plist")
            log = cache.appendingPathComponent("ShipIt_stderr.log")
            target = (externalDirectory ?? self.root.appendingPathComponent("External")).appendingPathComponent("Fixture.app")
            local = self.root.appendingPathComponent("Local/Fixture.app")
            store = AppSearchRecordStore(fileURL: self.root.appendingPathComponent("Records/search.json"))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.bundle(at: source, identifier: identifier, executable: "Fixture")
            try Self.bundle(at: local, identifier: identifier + ".appports.stub", executable: "launcher")
            let resources = local.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try target.path.write(to: resources.appendingPathComponent("real_app_path.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try store.record(name: "Fixture", localURL: local, externalURL: target, expectsLocalEntry: true, explicitOperation: true)
            try FileManager.default.removeItem(at: target)
            try writeRequest()
        }

        func writeRequest(relaunch: Bool = true, failure: Bool = true) throws {
            let request: [String: Any] = ["targetBundleURL": target.absoluteString + "/",
                "updateBundleURL": source.absoluteString + "/", "bundleIdentifier": identifier,
                "launchAfterInstallation": relaunch, "useUpdateBundleName": true]
            try JSONSerialization.data(withJSONObject: request).write(to: state)
            let text = "Detected this as an install request\n" + (failure
                ? "Installation error: Couldn't copy to \(target.path)\nShipIt quitting\n"
                : "Beginning installation\n")
            try text.write(to: log, atomically: true, encoding: .utf8)
        }

        func writeResumedFailureLog(targetURL: URL? = nil) throws {
            let destination = targetURL ?? target
            let text = """
            2026-11-15 09:45:49.156 ShipIt[89927:14259545] Detected this as an install request
            2026-11-15 09:45:49.156 ShipIt[89927:14259545] Moving bundle from file:///private/tmp/owned/Fixture.app to \(destination.absoluteString)/
            2026-11-15 09:45:49.158 ShipIt[89927:14259545] Resuming installation attempt 2
            2026-11-15 09:45:49.540 ShipIt[89927:14259545] Couldn't abort install and restore owned bundle to previous location \(destination.absoluteString)/, error NSError { domain: SQRLInstallerErrorDomain, code: -7 }
            2026-11-15 09:45:50.571 ShipIt[89927:14259545] Installation error: Error Domain=NSOSStatusErrorDomain Code=-67068 "(null)"
            2026-11-15 09:45:50.571 ShipIt[89927:14259545] ShipIt quitting
            """
            try text.write(to: log, atomically: true, encoding: .utf8)
        }

        func prependOldLog() throws {
            let latest = try Data(contentsOf: log)
            let history = String(repeating: "Could not read update request\n", count: 40_000)
            try (Data(history.utf8) + latest).write(to: log)
        }

        // Older guardians left these exact request bytes in ShipIt's cache after success.
        func restoreLegacyRequest(_ candidate: ShipItUpdateRecovery.Candidate) throws {
            try candidate.requestBytes.write(to: state)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: state.path)
        }

        func backdateLegacyReceipt(_ candidate: ShipItUpdateRecovery.Candidate, to completion: Date) throws {
            try restoreLegacyRequest(candidate)
            let url = root.appendingPathComponent("Receipts/" + candidate.key + ".json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json.removeValue(forKey: "handledInstallStart")
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: completion], ofItemAtPath: url.path)
        }

        func writeRepeatedFailure(startedAt date: Date, destination: URL? = nil) throws {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let header = formatter.string(from: date) + " ShipIt[72038:3431032] "
            let failure = header + "Detected this as an install request\n" +
                "Installation error: Couldn't copy to " + (destination ?? target).path + "\nShipIt quitting\n"
            try failure.write(to: log, atomically: true, encoding: .utf8)
        }

        func recovery(busy: @escaping @Sendable (String, URL) async throws -> ShipItUpdateRecovery.Activity = { _, _ in .idle },
                      refresh: @escaping @Sendable (AppSearchRecord) async throws -> Void = { _ in },
                      launch: @escaping @Sendable (URL) async throws -> Void = { _ in },
                      validate: @escaping @Sendable (URL, String) throws -> Void = { try Fixture.validate($0, $1) },
                      sameDeveloper: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in },
                      quit: @escaping @Sendable (String, URL) async -> Void = { _, _ in },
                      stopInstaller: @escaping @Sendable (ShipItUpdateRecovery.Candidate) throws -> Void = { _ in },
                      clearState: (@Sendable (ShipItUpdateRecovery.Candidate) throws -> Void)? = nil) -> ShipItUpdateRecovery {
            let domain = stateDomain
            return ShipItUpdateRecovery(records: store, caches: caches, directory: root.appendingPathComponent("Receipts"),
                launchLocks: root.appendingPathComponent("LaunchLocks"),
                operationLock: OperationLock(fileURL: root.appendingPathComponent("Records/operation.lock")),
                validate: validate, busy: busy, refresh: refresh, launch: launch,
                sameDeveloper: sameDeveloper, quit: quit,
                clearInstallerState: clearState ?? { try ShipItInstallerState.clear(for: $0, domain: domain) },
                stopInstaller: stopInstaller)
        }

        static func refreshPortal(_ record: AppSearchRecord, in root: URL) throws {
            let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 },
                transferStore: AppTransferStore(directoryURL: root.appendingPathComponent("Transfers")),
                signatureFactStore: SignatureFactStore(backupDirectoryURL: root.appendingPathComponent("Signatures")),
                writerAdmissionCheck: {}, runningApplications: { [] })
            guard service.refreshStubPortal(at: URL(fileURLWithPath: record.localPath),
                from: URL(fileURLWithPath: record.externalPath), force: true) else { throw CocoaError(.fileWriteUnknown) }
        }

        func makeOldTarget(version: String = "1") throws {
            try Self.bundle(at: target, identifier: identifier, executable: "Fixture")
            let url = target.appendingPathComponent("Contents/Info.plist")
            var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            plist["CFBundleVersion"] = version; plist["CFBundleShortVersionString"] = version
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        }

        func seedInstallerState(target: URL? = nil) throws {
            let data = try NSKeyedArchiver.archivedData(withRootObject: (target ?? self.target) as NSURL, requiringSecureCoding: true)
            CFPreferencesSetValue(ShipItInstallerState.ownedBundleKey as CFString, data as CFData,
                stateDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSetValue(ShipItInstallerState.attemptsKey as CFString, NSNumber(value: 3),
                stateDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSetValue("unrelated" as CFString, "preserve" as CFString,
                stateDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(stateDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }

        func state(_ key: String) -> CFPropertyList? {
            CFPreferencesCopyValue(key as CFString, stateDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }

        static func bundle(at url: URL, identifier: String, executable: String) throws {
            let macos = url.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                         "CFBundleVersion": "2", "CFBundleShortVersionString": "2.0"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            try Data("fixture payload".utf8).write(to: macos.appendingPathComponent(executable))
        }

        static func validate(_ url: URL, _ identifier: String) throws {
            // Only the OS signature boundary is substituted for these deliberately unsigned fixtures.
            guard try SignatureAppVersion.read(at: url).bundleIdentifier == identifier,
                  try Data(contentsOf: url.appendingPathComponent("Contents/MacOS/Fixture")) == Data("fixture payload".utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    func testFailedUpdateCopiesCacheAndRelaunchesOnlyOnceAcrossColdRetry() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launches = Calls(), refreshes = Calls()
        let recovery = fixture.recovery(refresh: { _ in _ = refreshes.next() }, launch: { _ in _ = launches.next() })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        let recovered = try await recovery.recover(candidate)
        XCTAssertTrue(recovered)
        try Fixture.validate(fixture.target, fixture.identifier)
        try Fixture.validate(fixture.source, fixture.identifier)
        XCTAssertEqual(launches.value, 1)
        XCTAssertEqual(refreshes.value, 1)
        let repeated = try await fixture.recovery(launch: { _ in _ = launches.next() }).recover(candidate)
        XCTAssertFalse(repeated)
        XCTAssertEqual(launches.value, 1)
    }

    func testCompletedLegacyRequestRetiresWithoutReinstallingOrRelaunching() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let worker = fixture.recovery()
        let candidate = try XCTUnwrap(worker.candidates().first)
        let installed = try await worker.recover(candidate)
        XCTAssertTrue(installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        try fixture.restoreLegacyRequest(candidate)
        let identity = try DataPathIdentity.capture(fixture.target)
        let stops = Calls()
        let upgraded = fixture.recovery(refresh: { _ in XCTFail("Already refreshed") },
            launch: { _ in XCTFail("Already launched") }, stopInstaller: { _ in _ = stops.next() })
        let pending = try XCTUnwrap(upgraded.candidates().first)
        XCTAssertEqual(pending.key, candidate.key)
        let retired = try await upgraded.recover(pending)
        XCTAssertTrue(retired)
        XCTAssertEqual(stops.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        XCTAssertTrue(identity.matchesFilesystemObject(try .capture(fixture.target)))
        try Fixture.validate(fixture.source, fixture.identifier)
        XCTAssertTrue(try upgraded.candidates().isEmpty)
    }

    func testRetiresOnlyMatchingLaunchdRegistrationAndAllowsNextSubmission() async throws {
        guard ProcessInfo.processInfo.environment["APPPORTS_SHIPIT_VALIDATION_ROOT"] != nil else {
            throw XCTSkip("Opt-in temporary launchd registration")
        }
        let fixture = try Fixture(identifier: "org.appports.retirement." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let label = fixture.identifier + ".ShipIt"
        let domain = "gui/\(getuid())"
        let job = domain + "/" + label
        let definition = fixture.root.appendingPathComponent("fixture.plist")
        func launchctl(_ args: [String]) throws -> ShellCommandResult {
            try ProcessCommandRunner.runSynchronously(executable: "/bin/launchctl", arguments: args, timeout: 5)
        }
        func register(request: URL, retryFailure: Bool = false) throws {
            var plist: [String: Any] = ["Label": label, "ProgramArguments": [retryFailure ? "/usr/bin/false" : "/usr/bin/true", label, request.path]]
            if retryFailure {
                plist["KeepAlive"] = ["SuccessfulExit": false]
                plist["RunAtLoad"] = true
                plist["ThrottleInterval"] = 60
            }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: definition)
            let bootstrap = try launchctl(["bootstrap", domain, definition.path])
            XCTAssertEqual(bootstrap.status, 0, bootstrap.combinedText)
        }
        let worker = fixture.recovery(stopInstaller: { try ShipItUpdateRecovery.stopInstallerJob($0) })
        let candidate = try XCTUnwrap(worker.candidates().first)
        try fixture.seedInstallerState()
        try register(request: fixture.root.appendingPathComponent("unrelated.plist"))
        defer { _ = try? launchctl(["bootout", job]) }
        do {
            _ = try await worker.recover(candidate)
            XCTFail("A job for another request must remain registered")
        } catch ShipItUpdateRecovery.RollbackError.changed {}
        XCTAssertEqual(try launchctl(["print", job]).status, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.state), candidate.requestBytes)
        XCTAssertNotNil(fixture.state(ShipItInstallerState.ownedBundleKey))
        XCTAssertEqual(try launchctl(["bootout", job]).status, 0)

        try register(request: fixture.state, retryFailure: true)
        let deadline = Date().addingTimeInterval(5)
        while try !launchctl(["print", job]).stdoutText.contains("last exit code = 1"), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(try launchctl(["print", job]).stdoutText.contains("last exit code = 1"))
        let finished = try await worker.recover(candidate)
        XCTAssertTrue(finished)
        XCTAssertEqual(try launchctl(["print", job]).status, 113)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        try fixture.writeRequest(relaunch: false, failure: false)
        try register(request: fixture.state)
        XCTAssertTrue(try worker.candidates().isEmpty)
        XCTAssertEqual(try launchctl(["print", job]).status, 0)
    }

    func testRelaunchPreparingNextUpdateKeepsItsRequestAndCanInstallIt() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let next = fixture.source.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("update.next/Fixture.app")
        try Fixture.bundle(at: next, identifier: fixture.identifier, executable: "Fixture")
        let plist = next.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: String])
        info["CFBundleShortVersionString"] = "3.0"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        let firstWorker = fixture.recovery(launch: { _ in
            var request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.state)) as? [String: Any])
            request["updateBundleURL"] = next.absoluteString
            request["launchAfterInstallation"] = false
            try JSONSerialization.data(withJSONObject: request).write(to: fixture.state, options: .atomic)
            try fixture.writeRepeatedFailure(startedAt: Date())
        })
        let first = try XCTUnwrap(firstWorker.candidates().first)
        let finished = try await firstWorker.recover(first)
        XCTAssertTrue(finished)
        let secondWorker = fixture.recovery()
        let second = try XCTUnwrap(secondWorker.candidates().first)
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertEqual(second.request.updateBundleURL, next)
        let updated = try await secondWorker.recover(second)
        XCTAssertTrue(updated)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "3.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
    }

    @MainActor
    func testSecondFailedInstallOfUnchangedRequestGetsANewRecoveryAndTask() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launches = Calls()
        let recovery = fixture.recovery(launch: { _ in _ = launches.next() })
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let history = MigrationTaskHistoryStore(fileURL: fixture.root.appendingPathComponent("history.json"))
        let center = MigrationTaskCenter(historyStore: history, operationState: state)
        func scan() async {
            let checked = expectation(description: "Finished checking the isolated ShipIt cache")
            let monitor = ShipItRecoveryMonitor(recovery: recovery, operationState: state,
                didCheck: { checked.fulfill() }, taskCenter: center)
            monitor.start()
            await fulfillment(of: [checked], timeout: 5)
            await monitor.stop()
        }

        let first = try XCTUnwrap(recovery.candidates().first)
        await scan()
        let completedAt = Date().addingTimeInterval(-120)
        try fixture.backdateLegacyReceipt(first, to: completedAt)
        let owned = fixture.root.appendingPathComponent("Owned.app")
        try FileManager.default.moveItem(at: fixture.target, to: owned)
        XCTAssertTrue(try recovery.candidates().isEmpty, "Losing the target alone cannot reopen the request")
        try fixture.writeRepeatedFailure(startedAt: completedAt.addingTimeInterval(-1))
        XCTAssertTrue(try recovery.candidates().isEmpty, "Rewriting an older failure also updates the log mtime")
        let nextStart = completedAt.addingTimeInterval(60)
        try fixture.writeRepeatedFailure(startedAt: nextStart, destination: fixture.root.appendingPathComponent("Other.app"))
        XCTAssertTrue(try recovery.candidates().isEmpty)
        try fixture.writeRepeatedFailure(startedAt: nextStart)
        try fixture.prependOldLog()
        try FileManager.default.moveItem(at: owned, to: fixture.target)
        XCTAssertEqual(try recovery.candidates().map(\.key), [first.key], "A healthy copy only needs its existing receipt retired")
        try FileManager.default.moveItem(at: fixture.target, to: owned)
        let second = try XCTUnwrap(fixture.recovery().candidates().first)
        XCTAssertEqual(first.requestBytes, second.requestBytes)
        XCTAssertNotEqual(first.key, second.key)
        let stale = try await recovery.recover(first)
        XCTAssertFalse(stale)
        await scan()
        try Fixture.validate(fixture.target, fixture.identifier)
        let jobs = history.load()
        XCTAssertEqual(Set(jobs.compactMap(\.observedKey)), Set([first.key, second.key]))
        XCTAssertEqual(jobs.map(\.observedResult), [.recovered, .recovered])
        try FileManager.default.removeItem(at: fixture.target)
        try fixture.prependOldLog()
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
        XCTAssertEqual(launches.value, 1, "Reusing the request must not restart the application again")
    }

    func testNewFailureDuringAutomaticRelaunchDoesNotCauseARelaunchLoop() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let earlier = Date().addingTimeInterval(-120)
        try fixture.writeRepeatedFailure(startedAt: earlier)
        let launches = Calls()
        let recovery = fixture.recovery(launch: { _ in
            _ = launches.next()
            try fixture.writeRepeatedFailure(startedAt: earlier.addingTimeInterval(60))
            try FileManager.default.moveItem(at: fixture.target, to: fixture.root.appendingPathComponent("Owned.app"))
        })
        let first = try XCTUnwrap(recovery.candidates().first)
        let recovered = try await recovery.recover(first)
        XCTAssertTrue(recovered)
        let second = try XCTUnwrap(recovery.candidates().first)
        let repaired = try await recovery.recover(second)
        XCTAssertTrue(repaired)
        XCTAssertEqual(launches.value, 1)
        try Fixture.validate(fixture.target, fixture.identifier)
        try FileManager.default.removeItem(at: fixture.target)
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
    }

    func testLaterStartHonorsOutstandingRollbackOnCompletedReceipt() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()
        let first = try XCTUnwrap(recovery.candidates().first)
        let recovered = try await recovery.recover(first)
        XCTAssertTrue(recovered)
        try recovery.requestRollback(first)
        try fixture.backdateLegacyReceipt(first, to: Date().addingTimeInterval(-120))
        try fixture.writeRepeatedFailure(startedAt: Date().addingTimeInterval(-60))
        try FileManager.default.removeItem(at: fixture.target)
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
        XCTAssertEqual(try recovery.pendingRollbacks().map { $0.candidate.key }, [first.key])
    }

    func testNormalUpdateAndDeletedPortalNeverQualify() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeRequest(failure: false)
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
        try fixture.writeRequest()
        XCTAssertEqual(try fixture.recovery().candidates().count, 1)
        try FileManager.default.removeItem(at: fixture.local)
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
    }

    func testOfflineRecordDoesNotBlockConnectedVolumeAndWrongVolumeSkips() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let disconnected = try Fixture(); defer { try? FileManager.default.removeItem(at: disconnected.root) }
        var offline = try XCTUnwrap(disconnected.store.records().first)
        let healthy = try XCTUnwrap(fixture.store.records().first)
        let recordsURL = fixture.root.appendingPathComponent("Records/search.json")
        try FileManager.default.removeItem(at: disconnected.target.deletingLastPathComponent())
        try JSONEncoder().encode([offline, healthy]).write(to: recordsURL, options: .atomic)
        XCTAssertEqual(try fixture.recovery().candidates().map(\.record.localPath), [healthy.localPath])
        offline = healthy
        offline.volumeUUID = "different-volume"
        try JSONEncoder().encode([offline]).write(to: recordsURL, options: .atomic)
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
    }

    func testExistingTargetAndDanglingLinkAreNeverOverwritten() async throws {
        for link in [false, true] {
            let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let recovery = fixture.recovery()
            let candidate = try XCTUnwrap(recovery.candidates().first)
            if link {
                try FileManager.default.createSymbolicLink(at: fixture.target, withDestinationURL: fixture.root.appendingPathComponent("Missing"))
            } else { try Data("user content".utf8).write(to: fixture.target) }
            let result = try await recovery.recover(candidate)
            XCTAssertFalse(result)
            if link { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.target.path), fixture.root.appendingPathComponent("Missing").path) }
            else { XCTAssertEqual(try Data(contentsOf: fixture.target), Data("user content".utf8)) }
        }
    }

    func testRunningUpdaterDefersWithoutCreatingTarget() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery(busy: { _, _ in .updaterRunning })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        let result = try await recovery.recover(candidate)
        XCTAssertFalse(result)
        XCTAssertFalse(try SignatureSnapshot.entryExists(fixture.target))
    }

    func testStateChangedBeforeCommitDefersAndRetainsCache() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let checks = Calls()
        let recovery = fixture.recovery(busy: { _, _ in
            if checks.next() == 2 { try fixture.writeRequest(relaunch: false) }
            return .idle
        })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        _ = try await recovery.recover(candidate)
        XCTAssertFalse(try SignatureSnapshot.entryExists(fixture.target))
        try Fixture.validate(fixture.source, fixture.identifier)
    }

    func testColdRetryFinishesPortalAfterCommitWithoutRecopying() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = fixture.recovery(refresh: { _ in throw CocoaError(.fileWriteNoPermission) })
        let candidate = try XCTUnwrap(first.candidates().first)
        do { _ = try await first.recover(candidate); XCTFail("Expected interrupted portal maintenance") } catch {}
        let installed = try DataPathIdentity.capture(fixture.target)
        let launches = Calls()
        let second = fixture.recovery(launch: { _ in _ = launches.next() })
        let result = try await second.recover(candidate)
        XCTAssertTrue(result)
        XCTAssertEqual(try DataPathIdentity.capture(fixture.target), installed)
        XCTAssertEqual(launches.value, 1)
    }

    func testOtherUpdaterDuringRefreshDefersLaunchUntilNextAttempt() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refreshed = Calls(), launches = Calls()
        let first = fixture.recovery(busy: { _, _ in refreshed.value > 0 ? .updaterRunning : .idle },
                                     refresh: { _ in _ = refreshed.next() }, launch: { _ in _ = launches.next() })
        let candidate = try XCTUnwrap(first.candidates().first)
        let deferred = try await first.recover(candidate)
        XCTAssertFalse(deferred)
        try Fixture.validate(fixture.target, fixture.identifier)
        XCTAssertEqual(launches.value, 0)
        let second = fixture.recovery(launch: { _ in _ = launches.next() })
        let completed = try await second.recover(candidate)
        XCTAssertTrue(completed)
        XCTAssertEqual(launches.value, 1)
    }

    func testAlreadyRunningInstalledApplicationCompletesWithoutReopeningAfterExit() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = fixture.recovery(refresh: { _ in throw CocoaError(.fileWriteNoPermission) })
        let candidate = try XCTUnwrap(first.candidates().first)
        do { _ = try await first.recover(candidate); XCTFail("Expected interrupted maintenance") } catch {}
        let launches = Calls()
        let second = fixture.recovery(busy: { _, _ in .applicationRunning }, launch: { _ in _ = launches.next() })
        let completed = try await second.recover(candidate)
        XCTAssertTrue(completed)
        let third = fixture.recovery(launch: { _ in _ = launches.next() })
        let repeated = try await third.recover(candidate)
        XCTAssertFalse(repeated)
        XCTAssertEqual(launches.value, 0)
    }

    func testLaunchKeepsGlobalLockUntilCompletionIsRecorded() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let checks = Calls()
        let recovery = fixture.recovery(launch: { _ in
            let other = OperationLock(fileURL: fixture.root.appendingPathComponent("Records/operation.lock"))
            if !other.tryAcquire() { _ = checks.next() }
            other.release()
        })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        let completed = try await recovery.recover(candidate)
        XCTAssertTrue(completed)
        XCTAssertEqual(checks.value, 1)
        XCTAssertTrue(try recovery.candidates().isEmpty)
    }

    func testFailedStageValidationColdRetriesOwnStageAndPreservesCache() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = fixture.recovery(validate: { url, identifier in
            try Fixture.validate(url, identifier)
            if url.lastPathComponent.hasPrefix(".appports-shipit-") { throw CocoaError(.fileReadCorruptFile) }
        })
        let candidate = try XCTUnwrap(first.candidates().first)
        do { _ = try await first.recover(candidate); XCTFail("Expected staging failure") } catch {}
        XCTAssertFalse(try SignatureSnapshot.entryExists(fixture.target))
        let completed = try await fixture.recovery().recover(candidate)
        XCTAssertTrue(completed)
        try Fixture.validate(fixture.target, fixture.identifier)
        try Fixture.validate(fixture.source, fixture.identifier)
    }

    func testInvalidSignatureAndDifferentIdentifierNeverInstall() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery(validate: { try ShipItUpdateRecovery.validateApplication(at: $0, identifier: $1) })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        do { _ = try await recovery.recover(candidate); XCTFail("Unsigned app must not install") } catch {}
        XCTAssertFalse(try SignatureSnapshot.entryExists(fixture.target))
        try Fixture.validate(fixture.source, fixture.identifier)
    }

    @MainActor
    func testMonitorAutomaticallyRecoversAfterForegroundOperationFinishes() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let token = try XCTUnwrap(state.begin())
        let launched = expectation(description: "Automatically starts the recovered app")
        let recovery = fixture.recovery(launch: { _ in launched.fulfill() })
        let monitor = ShipItRecoveryMonitor(recovery: recovery, interval: 20_000_000, operationState: state)
        monitor.start()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(try SignatureSnapshot.entryExists(fixture.target))
        state.finish(token)
        await fulfillment(of: [launched], timeout: 5)
        await monitor.stop()
        XCTAssertFalse(state.isBusy)
        try Fixture.validate(fixture.target, fixture.identifier)
        XCTAssertTrue(try recovery.candidates().isEmpty)
    }

    @MainActor
    func testMonitorRecoversResumedFailureWithTargetBeforeFinalErrorLine() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeResumedFailureLog()
        try fixture.prependOldLog()
        let launched = expectation(description: "Resumed failure is automatically recovered")
        let recovery = fixture.recovery(launch: { _ in launched.fulfill() })
        let monitor = ShipItRecoveryMonitor(recovery: recovery, interval: 20_000_000,
            operationState: AppOperationState(notificationCenter: NotificationCenter()))
        monitor.start()
        await fulfillment(of: [launched], timeout: 5)
        await monitor.stop()
        try Fixture.validate(fixture.target, fixture.identifier)
        try Fixture.validate(fixture.source, fixture.identifier)
        XCTAssertTrue(try recovery.candidates().isEmpty)
    }

    private func eventFixture() throws -> Fixture {
        // The host does not deliver FSEvents for /var/folders temporary directories.
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts-ShipItEventTests-\(UUID().uuidString)")
        return try Fixture(root: root)
    }

    @MainActor
    func testListenerStartFailureRetriesWithoutAnEventAndPublishesOnce() async throws {
        let fixture = try eventFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeRequest(failure: false)
        let first = expectation(description: "First check finished")
        let second = expectation(description: "Startup retry finished")
        let recovery = expectation(description: "Recovered after real file event")
        let checks = Calls(), starts = Calls(), publications = Calls()
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(launch: { _ in recovery.fulfill() }),
            debounce: 20_000_000, eventLatency: 0.02, didCheck: {
                switch checks.next() {
                case 1: first.fulfill()
                case 2: second.fulfill()
                default: break
                }
            }, startEvents: { stream, identifiers in
                starts.next() > 1 && stream.start(identifiers: identifiers)
            }, didStartListening: {
                _ = publications.next()
            })
        monitor.start()
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(publications.value, 0)
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(publications.value, 1)
        XCTAssertGreaterThanOrEqual(starts.value, 2)
        try fixture.writeRequest(failure: true)
        await fulfillment(of: [recovery], timeout: 5)
        await monitor.stop()
        XCTAssertEqual(publications.value, 1)
    }

    @MainActor
    func testStoppingDuringListenerBackoffCancelsRetry() async throws {
        let fixture = try eventFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeRequest(failure: false)
        let first = expectation(description: "Listener failed to start")
        let starts = Calls()
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(), didCheck: { first.fulfill() },
            startEvents: { _, _ in _ = starts.next(); return false },
            didStartListening: { XCTFail("A stopped listener cannot publish readiness") })
        monitor.start()
        await fulfillment(of: [first], timeout: 5)
        await monitor.stop()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(starts.value, 1)
    }

    @MainActor
    func testIdleMonitorDoesNotPollAndIgnoresUnrelatedWrites() async throws {
        let fixture = try eventFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeRequest(failure: false)
        let checks = Calls(), initial = expectation(description: "Initial check")
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(), interval: 20_000_000,
            debounce: 20_000_000, eventLatency: 0.02, didCheck: {
                if checks.next() == 1 { initial.fulfill() }
            })
        monitor.start()
        await fulfillment(of: [initial], timeout: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        let settled = checks.value
        let unrelated = fixture.caches.appendingPathComponent("unrelated.ShipIt")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("noise".utf8).write(to: unrelated.appendingPathComponent("ShipIt_stderr.log"))
        try Data("extraction".utf8).write(to: fixture.source.appendingPathComponent("unrelated-payload"))
        try await Task.sleep(nanoseconds: 500_000_000)
        await monitor.stop()
        XCTAssertEqual(checks.value, settled)
        XCTAssertFalse(try SignatureSnapshot.entryExists(fixture.target))
    }

    @MainActor
    func testExistingLogAppendTriggersRecoveryAndThenReturnsToIdle() async throws {
        let fixture = try eventFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeRequest(failure: false)
        let checks = Calls(), initial = expectation(description: "Initial check"), launched = expectation(description: "Event recovery")
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(launch: { _ in launched.fulfill() }),
            interval: 20_000_000, debounce: 20_000_000, eventLatency: 0.02, didCheck: {
                if checks.next() == 1 { initial.fulfill() }
            })
        monitor.start()
        await fulfillment(of: [initial], timeout: 5)
        let log = try FileHandle(forWritingTo: fixture.log)
        try log.seekToEnd()
        try log.write(contentsOf: Data("Installation error: Couldn't copy to \(fixture.target.path)\nShipIt quitting\n".utf8))
        try log.close()
        await fulfillment(of: [launched], timeout: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        let settled = checks.value
        try await Task.sleep(nanoseconds: 300_000_000)
        await monitor.stop()
        XCTAssertGreaterThan(settled, 1)
        XCTAssertEqual(checks.value, settled)
        try Fixture.validate(fixture.target, fixture.identifier)
        try Fixture.validate(fixture.source, fixture.identifier)
    }

    @MainActor
    func testNewOrRecreatedShipItDirectoryTriggersRecovery() async throws {
        for initiallyPresent in [false, true] {
            let fixture = try eventFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let cache = fixture.state.deletingLastPathComponent()
            let saved = fixture.root.appendingPathComponent("SavedCache")
            try FileManager.default.copyItem(at: cache, to: saved)
            if initiallyPresent { try fixture.writeRequest(failure: false) }
            else { try FileManager.default.removeItem(at: cache) }
            let checks = Calls(), initial = expectation(description: "Initial check"), launched = expectation(description: "New cache recovery")
            let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(launch: { _ in launched.fulfill() }),
                interval: 20_000_000, debounce: 20_000_000, eventLatency: 0.02, didCheck: {
                    if checks.next() == 1 { initial.fulfill() }
                })
            monitor.start()
            await fulfillment(of: [initial], timeout: 5)
            if initiallyPresent { try FileManager.default.removeItem(at: cache) }
            try FileManager.default.copyItem(at: saved, to: cache)
            await fulfillment(of: [launched], timeout: 5)
            await monitor.stop()
            try Fixture.validate(fixture.target, fixture.identifier)
        }
    }

    @MainActor
    func testFileEventReplacesRetainedOldAppAfterNormalQuit() async throws {
        let fixture = try eventFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget()
        try fixture.seedInstallerState()
        try fixture.writeRequest(failure: false)
        let activity = ActivityBox(), checks = Calls(), quits = Calls()
        let initial = expectation(description: "Initial check"), launched = expectation(description: "Replaced old app")
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(busy: { _, _ in activity.read() },
            launch: { _ in launched.fulfill() }, quit: { _, _ in _ = quits.next(); activity.stopped() }),
            interval: 20_000_000, debounce: 20_000_000, eventLatency: 0.02,
            didCheck: { if checks.next() == 1 { initial.fulfill() } })
        monitor.start()
        await fulfillment(of: [initial], timeout: 5)
        let oldIdentity = try DataPathIdentity.capture(fixture.target)
        try fixture.writeResumedFailureLog()
        await fulfillment(of: [launched], timeout: 5)
        await monitor.stop()
        XCTAssertEqual(quits.value, 1)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "2.0")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.target.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".appports-shipit-backup-") })
        XCTAssertEqual(try DataPathIdentity.capture(backup), oldIdentity)
        XCTAssertNil(fixture.state(ShipItInstallerState.ownedBundleKey))
        XCTAssertNil(fixture.state(ShipItInstallerState.attemptsKey))
    }

    @MainActor
    func testOnlyManagedApplicationExitTriggersACheck() async throws {
        let app = NSRunningApplication.current
        let identifier = try XCTUnwrap(app.bundleIdentifier)
        for managed in [false, true] {
            let fixture = try Fixture(identifier: managed ? identifier : "org.appports.fixture")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try fixture.writeRequest(failure: false)
            let center = NotificationCenter(), checks = Calls(), initial = expectation(description: "Initial check")
            let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(), interval: 20_000_000,
                debounce: 20_000_000, workspaceCenter: center,
                didCheck: { if checks.next() == 1 { initial.fulfill() } })
            monitor.start()
            await fulfillment(of: [initial], timeout: 5)
            // Only the workspace notification is simulated; no application is terminated.
            center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: app])
            try await Task.sleep(nanoseconds: 200_000_000)
            await monitor.stop()
            XCTAssertEqual(checks.value, managed ? 2 : 1)
        }
    }

    @MainActor
    func testPendingUpdateRetriesAfterInstallerStopsWithoutAnotherFileEvent() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let activity = ActivityBox(.updaterRunning), initial = expectation(description: "Deferred check")
        let checks = Calls(), launched = expectation(description: "Retry recovery")
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(busy: { _, _ in activity.read() },
            launch: { _ in launched.fulfill() }), interval: 20_000_000, debounce: 20_000_000, eventLatency: 0.02,
            didCheck: { if checks.next() == 1 { initial.fulfill() } })
        monitor.start()
        await fulfillment(of: [initial], timeout: 5)
        XCTAssertFalse(try SignatureSnapshot.entryExists(fixture.target))
        activity.stopped()
        await fulfillment(of: [launched], timeout: 5)
        await monitor.stop()
        try Fixture.validate(fixture.target, fixture.identifier)
    }

    @MainActor
    func testWorkspaceNotificationsTriggerCoalescedChecksAndStopUnsubscribes() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeRequest(failure: false)
        let center = NotificationCenter(), checks = Calls(), initial = expectation(description: "Initial check")
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(), interval: 20_000_000,
            debounce: 20_000_000, eventLatency: 0.02, workspaceCenter: center,
            didCheck: { if checks.next() == 1 { initial.fulfill() } })
        monitor.start()
        await fulfillment(of: [initial], timeout: 5)
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let before = checks.value
            for _ in 0..<10 { center.post(name: name, object: nil) }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while checks.value == before, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(checks.value, before + 1)
        }
        await monitor.stop()
        let stopped = checks.value
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try fixture.writeRequest()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(checks.value, stopped)
        XCTAssertFalse(try SignatureSnapshot.entryExists(fixture.target))
    }

    @MainActor
    func testStoppingMonitorCancelsRecoveryAndReleasesOperationToken() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let waiting = expectation(description: "Recovery waiting")
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(busy: { _, _ in
            waiting.fulfill()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .idle
        }), operationState: state)
        monitor.start()
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertTrue(state.isBusy)
        await monitor.stop()
        XCTAssertFalse(state.isBusy)
        XCTAssertFalse(try SignatureSnapshot.entryExists(fixture.target))
    }

    func testResumedFailureForOtherTargetOrPreviousAttemptIsIgnored() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeResumedFailureLog(targetURL: fixture.root.appendingPathComponent("Other.app"))
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
        try fixture.writeResumedFailureLog()
        var text = try String(contentsOf: fixture.log, encoding: .utf8)
        text += "\nDetected this as an install request\nBeginning installation\nShipIt quitting\n"
        try text.write(to: fixture.log, atomically: true, encoding: .utf8)
        try fixture.prependOldLog()
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
    }

    func testIncompleteStartMarkerAtTailBoundaryDoesNotAuthorizeRecovery() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = "Detected this as an install request"
        let failure = "\nInstallation error: Couldn't copy to \(fixture.target.path)\nShipIt quitting\n"
        let filler = String(repeating: " ", count: 1_048_576 - marker.utf8.count - failure.utf8.count)
        let attempt = marker + filler + failure
        try ("older history\n" + attempt).write(to: fixture.log, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.recovery().candidates().count, 1)
        try ("older history\n" + attempt + "\n").write(to: fixture.log, atomically: true, encoding: .utf8)
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
        try failure.write(to: fixture.log, atomically: true, encoding: .utf8)
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
    }

    func testRetainedOldVersionIsBackedUpAndInstallerStateCleared() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget(version: "0.2.1-rc.2")
        try fixture.seedInstallerState()
        var log = try String(contentsOf: fixture.log, encoding: .utf8)
        log = log.replacingOccurrences(of: "Installation error: Couldn't copy to", with: "Too many attempts to install, aborting update; target:")
        try log.write(to: fixture.log, atomically: true, encoding: .utf8)
        let oldIdentity = try DataPathIdentity.capture(fixture.target)
        let recovery = fixture.recovery()
        let candidate = try XCTUnwrap(recovery.candidates().first)
        let completed = try await recovery.recover(candidate)
        XCTAssertTrue(completed)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "2.0")
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".appports-shipit-backup-") }
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try DataPathIdentity.capture(backup), oldIdentity)
        XCTAssertEqual(try SignatureAppVersion.read(at: backup).shortVersion, "0.2.1-rc.2")
        XCTAssertNil(fixture.state(ShipItInstallerState.ownedBundleKey))
        XCTAssertNil(fixture.state(ShipItInstallerState.attemptsKey))
        XCTAssertEqual(fixture.state("unrelated") as? String, "preserve")
        try Fixture.validate(fixture.source, fixture.identifier)
    }

    func testOldApplicationGetsOneNormalQuitRequestAndWaitsIfDeclined() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget()
        let activity = ActivityBox(), quits = Calls(), launches = Calls()
        let recovery = fixture.recovery(busy: { _, _ in activity.read() }, launch: { _ in _ = launches.next() },
            quit: { _, _ in _ = quits.next() })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        let first = try await recovery.recover(candidate)
        let second = try await recovery.recover(candidate)
        XCTAssertFalse(first); XCTAssertFalse(second)
        XCTAssertEqual(quits.value, 1)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "1")
        XCTAssertEqual(launches.value, 0)
        activity.stopped()
        let completed = try await recovery.recover(candidate)
        XCTAssertTrue(completed)
        XCTAssertEqual(launches.value, 1)
    }

    func testAcceptedNormalQuitInstallsAfterExit() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget()
        let activity = ActivityBox(), quits = Calls()
        let recovery = fixture.recovery(busy: { _, _ in activity.read() }, quit: { _, _ in
            _ = quits.next(); activity.stopped()
        })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        let completed = try await recovery.recover(candidate)
        XCTAssertTrue(completed)
        XCTAssertEqual(quits.value, 1)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "2.0")
    }

    func testSameNewerUnknownOrWrongApplicationNeverQualifiesForReplacement() throws {
        for version in ["2.0", "3", "unknown"] {
            let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            try fixture.makeOldTarget(version: version)
            XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
        }
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Fixture.bundle(at: fixture.target, identifier: "org.unrelated.application", executable: "Fixture")
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
    }

    func testPublisherMismatchCannotQuitOrReplaceOldApplication() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget()
        let quits = Calls()
        let recovery = fixture.recovery(sameDeveloper: { _, _ in throw CocoaError(.fileReadCorruptFile) },
            quit: { _, _ in _ = quits.next() })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        do { _ = try await recovery.recover(candidate); XCTFail("Mismatched publisher") } catch {}
        XCTAssertEqual(quits.value, 0)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "1")
    }

    func testOtherTargetInstallerPreferencesArePreserved() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.seedInstallerState(target: fixture.root.appendingPathComponent("Other.app"))
        let prior = fixture.state(ShipItInstallerState.ownedBundleKey) as? Data
        let launches = Calls()
        let recovery = fixture.recovery(launch: { _ in _ = launches.next() })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        do { _ = try await recovery.recover(candidate); XCTFail("Another target's state cannot be cleared") } catch {}
        XCTAssertEqual(fixture.state(ShipItInstallerState.ownedBundleKey) as? Data, prior)
        XCTAssertEqual((fixture.state(ShipItInstallerState.attemptsKey) as? NSNumber)?.intValue, 3)
        XCTAssertEqual(launches.value, 0)
    }

    func testAutomaticRollbackResumesAfterRestartButLetsACorrectedDownloadInstall() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget()
        let payload = fixture.source.appendingPathComponent("Contents/MacOS/Fixture")
        try Data("damaged".utf8).write(to: payload)
        let blocked = fixture.recovery(validate: { url, identifier in
            do { try Fixture.validate(url, identifier) }
            catch { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecCSSignatureFailed)) }
        })
        let candidate = try XCTUnwrap(blocked.candidates().first)
        do { _ = try await blocked.recover(candidate); XCTFail("Rejected download") }
        catch let rejected as ShipItUpdateRecovery.RejectedUpdate {
            XCTAssertTrue(try blocked.pendingRollbacks().isEmpty)
            let result = try await blocked.recover(candidate, previousRejection: rejected.identity)
            XCTAssertFalse(result)
        }
        XCTAssertEqual(try blocked.pendingRollbacks().map(\.automatic), [true])
        // The updater repairs the package in place. The request and the bundle inode can both be reused.
        try Data("fixture payload".utf8).write(to: payload)
        let restarted = fixture.recovery()
        do { _ = try await restarted.rollback(candidate, automatic: true); XCTFail("Recheck the corrected download") }
        catch ShipItUpdateRecovery.RollbackError.newDownload {}
        XCTAssertTrue(try restarted.pendingRollbacks().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        let installed = try await restarted.recover(candidate)
        XCTAssertTrue(installed)
    }

    func testRejectedDownloadWithoutAProvenOldCopyIsPreserved() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let worker = fixture.recovery(validate: { try ShipItUpdateRecovery.validateApplication(at: $0, identifier: $1) })
        let candidate = try XCTUnwrap(worker.candidates().first)
        do { _ = try await worker.recover(candidate); XCTFail("Unsigned download") }
        catch let rejected as ShipItUpdateRecovery.RejectedUpdate {
            do { _ = try await worker.recover(candidate, previousRejection: rejected.identity); XCTFail("No verified old copy") }
            catch ShipItUpdateRecovery.RollbackError.oldApplicationMissing {}
        }
        XCTAssertTrue(try worker.pendingRollbacks().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.state.path))
    }

    func testRepeatedPublisherMismatchWaitsForRunningOldAppAndResumesAfterRestart() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget()
        let old = try DataPathIdentity.capture(fixture.target)
        let activity = ActivityBox()
        let publisher: @Sendable (URL, URL) throws -> Void = { _, _ in
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecCSReqFailed))
        }
        let worker = fixture.recovery(busy: { _, _ in activity.read() }, sameDeveloper: publisher,
                                      quit: { _, _ in XCTFail("Do not quit a running app for automatic rollback") })
        let candidate = try XCTUnwrap(worker.candidates().first)
        do { _ = try await worker.recover(candidate); XCTFail("First mismatch") }
        catch let rejected as ShipItUpdateRecovery.RejectedUpdate {
            let installed = try await worker.recover(candidate, previousRejection: rejected.identity)
            XCTAssertFalse(installed)
        }
        do { _ = try await worker.rollback(candidate, automatic: true); XCTFail("Keep the running old app") }
        catch ShipItUpdateRecovery.RollbackError.busy {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        activity.stopped()
        let restarted = fixture.recovery(sameDeveloper: publisher)
        XCTAssertEqual(try restarted.pendingRollbacks().map(\.automatic), [true])
        let version = try await restarted.rollback(candidate, automatic: true)
        XCTAssertEqual(version, "1")
        XCTAssertEqual(try DataPathIdentity.capture(fixture.target), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertTrue(try restarted.pendingRollbacks().isEmpty)
    }

    @MainActor
    func testGuardianAutomaticallyRestoresSignedOldApplicationAndCleansRejectedDownload() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["APPPORTS_SHIPIT_VALIDATION_ROOT"], let old = env["APPPORTS_SHIPIT_OLD_SIGNED_FIXTURE"],
              let new = env["APPPORTS_SHIPIT_SIGNED_FIXTURE"] else { throw XCTSkip("Requires signed DeepSeek bundles") }
        let fixture = try Fixture(root: URL(fileURLWithPath: output).appendingPathComponent("Rejected-" + UUID().uuidString),
                                  identifier: "com.deepseek.dsh")
        let native = FileManager.default.temporaryDirectory.appendingPathComponent(fixture.identifier + ".ShipIt." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: native); try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let parked = native.appendingPathComponent("Fixture.app")
        try SignatureSnapshot.copy(from: URL(fileURLWithPath: old), to: parked)
        let version = try SignatureAppVersion.read(at: parked)
        try FileManager.default.removeItem(at: fixture.source)
        try SignatureSnapshot.copy(from: URL(fileURLWithPath: new), to: fixture.source)
        let resource = fixture.source.appendingPathComponent("Contents/Resources/app.asar")
        try Data("signature test".utf8).write(to: resource, options: .atomic)
        let log = "Detected this as an install request\nMoving bundle from \(fixture.target.absoluteString) to \(parked.absoluteString)\nInstallation error: \(fixture.target.path)\nShipIt quitting\n"
        try log.write(to: fixture.log, atomically: true, encoding: .utf8)
        let sibling = fixture.source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("other-download")
        try Data("keep".utf8).write(to: sibling)
        let root = fixture.root
        let worker = fixture.recovery(refresh: { record in
            try Fixture.refreshPortal(record, in: root)
        }, validate: { try ShipItUpdateRecovery.validateApplication(at: $0, identifier: $1) },
                                      sameDeveloper: { try ShipItUpdateRecovery.requireSameDeveloper(old: $0, new: $1) })
        let candidate = try XCTUnwrap(worker.candidates().first)
        let observed = ShipItObservedTaskStore(directory: worker.directory)
        let finished = expectation(description: "Guardian completed rollback without a user action")
        let monitor = ShipItRecoveryMonitor(recovery: worker, interval: 50_000_000, didCheck: {
            if (try? observed.entries().first?.result) == .rolledBack { finished.fulfill() }
        }, observedStore: observed)
        finished.assertForOverFulfill = false
        monitor.start()
        await fulfillment(of: [finished], timeout: 100)
        await monitor.stop()
        XCTAssertEqual(try observed.entries().map(\.candidate), [candidate])
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target), version)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.local).shortVersion, version.shortVersion)
        XCTAssertEqual(AppPortalMaintenance.entries(at: fixture.local).first?.externalURL.path, fixture.target.path)
        let restored = fixture.target, identifier = fixture.identifier
        try await Task.detached { try ShipItUpdateRecovery.validateApplication(at: restored, identifier: identifier) }.value
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: native.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        XCTAssertTrue(try worker.pendingRollbacks().isEmpty)
    }

    func testLegacyCompletedReceiptOnlyCleansInstallerStateWithoutRelaunch() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launches = Calls()
        let first = fixture.recovery(launch: { _ in _ = launches.next() })
        let candidate = try XCTUnwrap(first.candidates().first)
        _ = try await first.recover(candidate)
        let receipt = fixture.root.appendingPathComponent("Receipts/" + candidate.key + ".json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        json.removeValue(forKey: "installerStateCleaned")
        try fixture.restoreLegacyRequest(candidate)
        try JSONSerialization.data(withJSONObject: json).write(to: receipt)
        try fixture.seedInstallerState()
        let second = fixture.recovery(launch: { _ in _ = launches.next() })
        XCTAssertEqual(try second.candidates().count, 1)
        let completed = try await second.recover(candidate)
        XCTAssertTrue(completed)
        XCTAssertEqual(launches.value, 1)
        XCTAssertNil(fixture.state(ShipItInstallerState.ownedBundleKey))
        XCTAssertNil(fixture.state(ShipItInstallerState.attemptsKey))
        XCTAssertTrue(try second.candidates().isEmpty)
    }

    func testColdRetryAfterExchangePreservesOldBackupWithoutRecopying() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget()
        let activity = ActivityBox()
        let first = fixture.recovery(busy: { _, _ in activity.read() })
        let candidate = try XCTUnwrap(first.candidates().first)
        _ = try await first.recover(candidate)
        let receipt = fixture.root.appendingPathComponent("Receipts/" + candidate.key + ".json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        let stage = try XCTUnwrap(URL(string: try XCTUnwrap(json["stage"] as? String)))
        let oldIdentity = try DataPathIdentity.capture(fixture.target)
        XCTAssertEqual(renamex_np(stage.path, fixture.target.path, UInt32(RENAME_SWAP)), 0)
        let installedIdentity = try DataPathIdentity.capture(fixture.target)
        let second = fixture.recovery()
        let completed = try await second.recover(candidate)
        XCTAssertTrue(completed)
        XCTAssertEqual(try DataPathIdentity.capture(fixture.target), installedIdentity)
        let replacement = try XCTUnwrap(json["replacement"] as? [String: Any])
        let backup = try XCTUnwrap(URL(string: try XCTUnwrap(replacement["backup"] as? String)))
        XCTAssertEqual(try DataPathIdentity.capture(backup), oldIdentity)
    }

    func testNumericPrereleaseAndBuildVersionOrdering() {
        XCTAssertEqual(ShipItUpdateRecovery.compareVersion("0.2.2-rc.3", "0.2.1-rc.2"), .orderedDescending)
        XCTAssertEqual(ShipItUpdateRecovery.compareVersion("0.2.2-rc.10", "0.2.2-rc.3"), .orderedDescending)
        XCTAssertEqual(ShipItUpdateRecovery.compareVersion("0.2.2", "0.2.2-rc.3"), .orderedDescending)
        XCTAssertEqual(ShipItUpdateRecovery.compareVersion("2.0+new", "2.0.0+old"), .orderedSame)
        XCTAssertNil(ShipItUpdateRecovery.compareVersion("unknown", "2.0"))
    }

    @MainActor
    func testFailedInterventionRollsBackRetainedOldAppAndUpdatesSameTask() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget(version: "1")
        let original = try DataPathIdentity.capture(fixture.target)
        let recovery = fixture.recovery(refresh: { _ in throw CocoaError(.fileWriteUnknown) })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        do { _ = try await recovery.recover(candidate); XCTFail("Portal failure must leave an unfinished intervention") }
        catch { }
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.target.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".appports-shipit-backup-") })
        XCTAssertEqual(try DataPathIdentity.capture(backup), original)
        let history = MigrationTaskHistoryStore(fileURL: fixture.root.appendingPathComponent("TaskHistory.json"))
        let operationState = AppOperationState(notificationCenter: NotificationCenter())
        let center = MigrationTaskCenter(historyStore: history, operationState: operationState)
        let job = center.updateObserved(key: candidate.key, title: "Update Fixture", resources: MigrationResources(paths: [fixture.target]),
            status: .attention, message: "Intervention failed")
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(), operationState: operationState, taskCenter: center)
        await monitor.rollback(candidate)
        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertEqual(center.jobs.first?.id, job.id)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.observedResult, .rolledBack)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recovery().rollbackURL(candidate).path))
        XCTAssertFalse(operationState.isBusy)
        XCTAssertEqual(history.load().first?.observedResult, .rolledBack)
    }

    func testMissingTargetRollbackRestoresNativeOldCopyAndRemovesOnlyUpdateMaterials() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let native = FileManager.default.temporaryDirectory.appendingPathComponent(fixture.identifier + ".ShipIt." + UUID().uuidString)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: native) }
        try fixture.makeOldTarget(version: "1")
        let resources = fixture.target.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "updaterCacheDirName: 'fixture-download-cache'\n".write(to: resources.appendingPathComponent("app-update.yml"), atomically: true, encoding: .utf8)
        let downloads = fixture.caches.appendingPathComponent("fixture-download-cache")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("download".utf8).write(to: downloads.appendingPathComponent("update.zip"))
        let business = fixture.root.appendingPathComponent("Business/session.json")
        try FileManager.default.createDirectory(at: business.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep sessions".utf8).write(to: business)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let old = native.appendingPathComponent("Fixture.app")
        try FileManager.default.moveItem(at: fixture.target, to: old)
        let log = """
        Detected this as an install request
        Moving bundle from \(fixture.target.absoluteString) to \(old.absoluteString)
        Installation error: Permission denied at \(fixture.target.path)
        ShipIt quitting
        """
        try log.write(to: fixture.log, atomically: true, encoding: .utf8)
        try fixture.prependOldLog()
        let recovery = fixture.recovery()
        let candidate = try XCTUnwrap(recovery.candidates().first)
        let version = try await recovery.rollback(candidate)
        XCTAssertEqual(version, "1")
        try Fixture.validate(fixture.target, fixture.identifier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: native.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: business), Data("keep sessions".utf8))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path)
        XCTAssertEqual(remaining, ["Fixture.app"])
    }

    func testRollbackRetainsOldApplicationUntilCleanupSucceedsAndColdRetryCompletes() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget(version: "1")
        let recovery = fixture.recovery()
        let candidate = try XCTUnwrap(recovery.candidates().first)
        // The real install switches versions; its original inode becomes the recorded backup.
        let recoveredBeforeRollback = try await recovery.recover(candidate)
        XCTAssertTrue(recoveredBeforeRollback)
        try fixture.restoreLegacyRequest(candidate)
        let failedCleanup = fixture.recovery(clearState: { _ in throw CocoaError(.fileWriteUnknown) })
        do { _ = try await failedCleanup.rollback(candidate); XCTFail("Preference failure must not report a clean rollback") }
        catch { }
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.rollbackURL(candidate).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty, "An interrupted rollback must not reinstall this update")
        XCTAssertEqual(try fixture.recovery().pendingRollbacks().map(\.candidate), [candidate])
        let version = try await fixture.recovery().rollback(candidate)
        XCTAssertEqual(version, "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.rollbackURL(candidate).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testRollbackAfterRequestRetirementPreservesNextUpdateAndCanRestoreOldApp() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget(version: "1")
        let worker = fixture.recovery()
        let candidate = try XCTUnwrap(worker.candidates().first)
        let recovered = try await worker.recover(candidate)
        XCTAssertTrue(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        try fixture.writeRequest(relaunch: false, failure: false)
        let newRequest = try Data(contentsOf: fixture.state)
        XCTAssertThrowsError(try worker.requestRollback(candidate))
        XCTAssertEqual(try Data(contentsOf: fixture.state), newRequest)
        try FileManager.default.removeItem(at: fixture.state)
        let restored = try await fixture.recovery().rollback(candidate)
        XCTAssertEqual(restored, "1")
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "1")
    }

    func testRollbackWithoutACompleteOldAppPreservesUpdateCache() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()
        let candidate = try XCTUnwrap(recovery.candidates().first)
        do { _ = try await recovery.rollback(candidate); XCTFail("Missing old copy cannot be guessed") }
        catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.rollbackURL(candidate).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.rollbackIntentURL(candidate).path))
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
        XCTAssertEqual(try fixture.recovery().pendingRollbacks().map(\.candidate), [candidate])
        let resumed = try await fixture.recovery().recover(candidate)
        XCTAssertFalse(resumed, "Restart must honor the user's rollback request even without an old copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
    }

    func testCleanRollbackFinishesAfterInstallationReceiptWasDeleted() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget(version: "1")
        let recovery = fixture.recovery(refresh: { _ in throw CocoaError(.fileWriteUnknown) })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        do { _ = try await recovery.recover(candidate); XCTFail("Leave an installation receipt") } catch { }
        let savedCopy = fixture.root.appendingPathComponent("BeforeCleanup.json")
        let worker = fixture.recovery()
        _ = try await worker.rollback(candidate, report: { step in
            if step == .cleaning { try? FileManager.default.copyItem(at: worker.rollbackURL(candidate), to: savedCopy) }
        })
        // Recreate the durable state at the last cleanup boundary; the real worker already removed all material.
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: savedCopy)) as? [String: Any])
        saved["cleanupComplete"] = true
        try JSONSerialization.data(withJSONObject: saved).write(to: worker.rollbackURL(candidate))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Receipts/" + candidate.key + ".json").path))
        let version = try await fixture.recovery().rollback(candidate)
        XCTAssertEqual(version, "1")
        XCTAssertTrue(try fixture.recovery().pendingRollbacks().isEmpty)
    }

    func testRollbackRejectsInvalidOldSignatureWithoutDeletingUpdate() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget(version: "1")
        let recovery = fixture.recovery(validate: { _, _ in throw CocoaError(.fileReadCorruptFile) })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        do { _ = try await recovery.rollback(candidate); XCTFail("Unverified old app cannot be restored") } catch { }
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
    }

    @MainActor
    func testMonitorPublishesSuccessfulInterventionInTaskCenter() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let history = MigrationTaskHistoryStore(fileURL: fixture.root.appendingPathComponent("history.json"))
        let center = MigrationTaskCenter(historyStore: history, operationState: state)
        let checked = expectation(description: "Recovery task completed")
        let monitor = ShipItRecoveryMonitor(recovery: fixture.recovery(), operationState: state,
            didCheck: { checked.fulfill() }, taskCenter: center)
        monitor.start()
        await fulfillment(of: [checked], timeout: 5)
        await monitor.stop()
        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertEqual(center.jobs.first?.status, .completed)
        XCTAssertEqual(center.jobs.first?.observedResult, .recovered)
        XCTAssertEqual(history.load().first?.observedResult, .recovered)
        XCTAssertFalse(state.isBusy)
    }

    @MainActor
    func testRollbackChoiceIsSavedBeforeWaitingForForegroundOperation() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()
        let candidate = try XCTUnwrap(recovery.candidates().first)
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let token = try XCTUnwrap(state.begin()); defer { state.finish(token) }
        let monitor = ShipItRecoveryMonitor(recovery: recovery, operationState: state)
        await monitor.rollback(candidate)
        XCTAssertTrue(try fixture.recovery().candidates().isEmpty)
        XCTAssertEqual(try fixture.recovery().pendingRollbacks().map(\.candidate), [candidate])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testRollbackRefusesAnAppThatDoesNotExitNormally() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makeOldTarget(version: "1")
        let quits = Calls()
        let recovery = fixture.recovery(busy: { _, _ in .applicationRunning }, quit: { _, _ in _ = quits.next() })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        do { _ = try await recovery.rollback(candidate); XCTFail("A running app must not be replaced or cleaned") }
        catch { }
        XCTAssertEqual(quits.value, 1)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target).shortVersion, "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testIndependentSignedUpdateRollbackAndPortalRefresh() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["APPPORTS_SHIPIT_VALIDATION_ROOT"],
              let new = environment["APPPORTS_SHIPIT_SIGNED_FIXTURE"],
              let old = environment["APPPORTS_SHIPIT_OLD_SIGNED_FIXTURE"] else {
            throw XCTSkip("Opt-in signed old/new bundle rollback validation")
        }
        let fixture = try Fixture(root: URL(fileURLWithPath: output).appendingPathComponent("Rollback-\(UUID().uuidString)"), identifier: "com.deepseek.dsh")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.source)
        try SignatureSnapshot.copy(from: URL(fileURLWithPath: new), to: fixture.source)
        try SignatureSnapshot.copy(from: URL(fileURLWithPath: old), to: fixture.target)
        let version = try SignatureAppVersion.read(at: fixture.target)
        let failed = fixture.recovery(refresh: { _ in throw CocoaError(.fileWriteUnknown) },
            validate: { try ShipItUpdateRecovery.validateApplication(at: $0, identifier: $1) },
            sameDeveloper: { try ShipItUpdateRecovery.requireSameDeveloper(old: $0, new: $1) })
        let candidate = try XCTUnwrap(failed.candidates().first)
        do { _ = try await failed.recover(candidate); XCTFail("Leave the real installed update pending portal refresh") } catch { }
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target), try SignatureAppVersion.read(at: fixture.source))
        let root = fixture.root
        let recovery = fixture.recovery(refresh: { record in
            try Fixture.refreshPortal(record, in: root)
        }, validate: { try ShipItUpdateRecovery.validateApplication(at: $0, identifier: $1) })
        _ = try await recovery.rollback(candidate)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target), version)
        try ShipItUpdateRecovery.validateApplication(at: fixture.target, identifier: fixture.identifier)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.local).shortVersion, version.shortVersion)
        XCTAssertEqual(AppPortalMaintenance.entries(at: fixture.local).first?.externalURL.path, fixture.target.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path), ["Fixture.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertTrue(try recovery.pendingRollbacks().isEmpty)
    }

    func testIndependentReplayOfRepeatedShipItFailureWithSignedBundle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["APPPORTS_SHIPIT_VALIDATION_ROOT"],
              let receiptPath = environment["APPPORTS_SHIPIT_REPLAY_RECEIPT"] else {
            throw XCTSkip("Opt-in replay of a completed request and a subsequent failure on another volume")
        }
        // The incident receipt, log and signed bundle are read-only inputs.
        let receiptURL = URL(fileURLWithPath: receiptPath)
        let old = try JSONDecoder().decode(ShipItUpdateRecovery.Receipt.self, from: Data(contentsOf: receiptURL))
        let completedAt = try XCTUnwrap(receiptURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let original = old.candidate
        let log = original.stateURL.deletingLastPathComponent().appendingPathComponent("ShipIt_stderr.log")
        let logTail = String(decoding: try SignatureRecordFile.tail(at: log, maxBytes: 1_048_576), as: UTF8.self)
        let external = URL(fileURLWithPath: output).appendingPathComponent("Repeat-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: external) }
        let fixture = try Fixture(identifier: original.request.bundleIdentifier, externalDirectory: external)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertNotEqual(try DataPathIdentity.capture(fixture.caches).volumeUUID, try DataPathIdentity.capture(external).volumeUUID)
        try FileManager.default.removeItem(at: fixture.source)
        try SignatureSnapshot.copy(from: original.request.updateBundleURL, to: fixture.source)
        let root = fixture.root, launches = Calls()
        let recovery = fixture.recovery(refresh: { try Fixture.refreshPortal($0, in: root) },
            launch: { _ in _ = launches.next() },
            validate: { try ShipItUpdateRecovery.validateApplication(at: $0, identifier: $1) })
        let first = try XCTUnwrap(recovery.candidates().first)
        let firstResult = try await recovery.recover(first)
        XCTAssertTrue(firstResult)
        try fixture.backdateLegacyReceipt(first, to: completedAt)
        try FileManager.default.moveItem(at: fixture.target, to: external.appendingPathComponent("Owned.app"))
        let replay = logTail.replacingOccurrences(of: original.request.targetBundleURL.absoluteString,
                                                  with: first.request.targetBundleURL.absoluteString)
            .replacingOccurrences(of: original.request.targetBundleURL.path, with: fixture.target.path)
        try replay.write(to: fixture.log, atomically: true, encoding: .utf8)
        let second = try XCTUnwrap(recovery.candidates().first)
        XCTAssertEqual(first.requestBytes, second.requestBytes)
        XCTAssertNotEqual(first.key, second.key)
        let secondResult = try await recovery.recover(second)
        XCTAssertTrue(secondResult)
        try ShipItUpdateRecovery.validateApplication(at: fixture.target, identifier: fixture.identifier)
        XCTAssertEqual(try SignatureAppVersion.read(at: fixture.target), try SignatureAppVersion.read(at: fixture.source))
        XCTAssertEqual(AppPortalMaintenance.entries(at: fixture.local).first?.externalURL.path, fixture.target.path)
        XCTAssertTrue(try recovery.candidates().isEmpty)
        XCTAssertEqual(launches.value, 1, "The repeated recovery repairs the portal without relaunching ShipIt")
    }

    func testIndependentExternalVolumeWithRealSignedCache() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["APPPORTS_SHIPIT_VALIDATION_ROOT"],
              let source = environment["APPPORTS_SHIPIT_SIGNED_FIXTURE"] else {
            throw XCTSkip("Opt-in signed bundle / external volume validation")
        }
        let fixture = try Fixture(root: URL(fileURLWithPath: output).appendingPathComponent("Fixture-\(UUID().uuidString)"), identifier: "com.deepseek.dsh")
        try FileManager.default.removeItem(at: fixture.source)
        try SignatureSnapshot.copy(from: URL(fileURLWithPath: source), to: fixture.source)
        let launches = Calls()
        let recovery = fixture.recovery(launch: { _ in _ = launches.next() }, validate: { try ShipItUpdateRecovery.validateApplication(at: $0, identifier: $1) })
        let candidate = try XCTUnwrap(recovery.candidates().first)
        let result = try await recovery.recover(candidate)
        XCTAssertTrue(result)
        try ShipItUpdateRecovery.validateApplication(at: fixture.target, identifier: fixture.identifier)
        try ShipItUpdateRecovery.validateApplication(at: fixture.source, identifier: fixture.identifier)
        XCTAssertEqual(launches.value, 1)
        // Keep the independently restored app and receipts for review; do not start the user's app.
        let report = "Recovered: \(fixture.target.path)\nCache retained: \(fixture.source.path)\nSignature: verified\nLaunch: substituted, real application not started\n"
        try report.write(to: fixture.root.appendingPathComponent("RESULT.txt"), atomically: true, encoding: .utf8)
    }
}
