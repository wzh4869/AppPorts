import Darwin
import XCTest
@testable import AppPorts

final class AppSearchExclusionTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var local: URL { root.appendingPathComponent("Local/Example.app") }
    private var externalRoot: URL { root.appendingPathComponent("External") }
    private var external: URL { externalRoot.appendingPathComponent("Example.app") }
    private var destination: URL { AppSearchExclusionService.library(in: externalRoot).appendingPathComponent("Example.app") }
    private var item: AppItem { AppItem(name: "Example.app", path: external, status: AppStatus.linked) }
    private var store: AppSearchRecordStore { AppSearchRecordStore(fileURL: root.appendingPathComponent("records.json")) }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Exclusion-\(UUID())")
        try fm.createDirectory(at: root.appendingPathComponent("Local"), withIntermediateDirectories: true)
        try fm.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try makeApp(external)
    }

    override func tearDownWithError() throws {
        for url in [external, destination] { try? fm.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        try? fm.removeItem(at: root)
    }

    private func service(fileManager: FileManager = .default) -> AppMigrationService {
        AppMigrationService(fileManager: fileManager, dockShortcutUpdater: { _, _ in 0 }, runningApplications: { [] })
    }

    private func makeApp(_ url: URL, identifier: String = "org.example.exclusion") throws {
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
            "CFBundleName": "Example", "CFBundleExecutable": "Example", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1"],
            format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let executable = url.appendingPathComponent("Contents/MacOS/Example")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func link() throws {
        try service().linkApp(appToLink: item, destinationURL: local)
        try AppPortalMaintenance.rememberEntries(at: local, explicitOperation: true, store: store)
    }

    private func writeJournal(source: URL, portals: [AppSearchExclusionService.Journal.Portal] = [],
                              phase: String = "external-moved") throws -> URL {
        let library = AppSearchExclusionService.library(in: externalRoot)
        try AppSearchExclusionService.prepareLibrary(library)
        let journal = AppSearchExclusionService.Journal(source: source,
            destination: library.appendingPathComponent(source.lastPathComponent),
            sourceIdentity: try AppSearchExclusionService.FileIdentity.read(source),
            volumeUUID: try XCTUnwrap(source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString),
            portals: portals, phase: phase)
        let url = library.appendingPathComponent(".appports-exclusion-\(UUID()).json")
        try JSONEncoder().encode(journal).write(to: url)
        return url
    }

    private func journalPortal(at url: URL) throws -> AppSearchExclusionService.Journal.Portal {
        let stageRoot = url.deletingLastPathComponent().appendingPathComponent(".appports-exclusion-\(UUID())")
        return .init(local: url, backup: stageRoot.appendingPathComponent("original"),
                     stage: stageRoot.appendingPathComponent(url.lastPathComponent),
                     identity: try AppSearchExclusionService.FileIdentity.read(url))
    }

    func testInspectPendingDoesNotCreateLibraryOrChangeRecords() throws {
        let recordsURL = root.appendingPathComponent("records.json")
        for hasRecords in [false, true] {
            if hasRecords {
                try store.record(name: "Example", localURL: local, externalURL: external,
                                 expectsLocalEntry: false, explicitOperation: true)
            }
            let originalRecords = try store.records()
            XCTAssertFalse(fm.fileExists(atPath: destination.deletingLastPathComponent().path))

            let report = try inspectWithoutMutatingFixture(app: item, dockNeedsRedirect: { _, _ in false })

            XCTAssertEqual(report.entries.map(\.outcome), [.pending])
            XCTAssertEqual(report.entries.first?.id, external.path)
            XCTAssertNil(report.operationError)
            XCTAssertFalse(fm.fileExists(atPath: destination.deletingLastPathComponent().path))
            XCTAssertFalse(fm.fileExists(atPath: local.path))
            XCTAssertEqual(fm.fileExists(atPath: recordsURL.path), hasRecords)
            XCTAssertEqual(try store.records(), originalRecords)
        }
    }

    func testInspectExcludedAppReportsCompletedOrDockWarningWithoutWrites() throws {
        try AppSearchExclusionService.prepareLibrary(destination.deletingLastPathComponent())
        try fm.moveItem(at: external, to: destination)
        let moved = AppItem(name: "Example.app", path: destination, status: AppStatus.unlinked)
        let scenarios: [(needsRedirect: Bool, fails: Bool, outcome: AppSearchExclusionReport.Outcome)] = [
            (false, false, .completed), (true, false, .dockWarning), (false, true, .dockWarning)
        ]
        for scenario in scenarios {
            var probeCount = 0
            let report = try inspectWithoutMutatingFixture(app: moved, dockNeedsRedirect: { _, target in
                probeCount += 1
                XCTAssertEqual(target, self.destination)
                if scenario.fails { throw NSError(domain: "AppSearchExclusionTests.DockInspection", code: 1) }
                return scenario.needsRedirect
            })

            XCTAssertEqual(report.entries.map(\.outcome), [scenario.outcome])
            XCTAssertGreaterThan(probeCount, 0)
            XCTAssertNil(report.operationError)
            XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("records.json").path))
            XCTAssertFalse(fm.fileExists(atPath: local.path))
        }
    }

    func testInspectRelatedJournalFailsBeforeAndAfterMoveWithoutChanges() throws {
        try link()
        let journal = try writeJournal(source: external, portals: [journalPortal(at: local)])
        let journalBytes = try Data(contentsOf: journal)
        let originalRecords = try store.records()
        for path in [external, destination] {
            if path == destination { try fm.moveItem(at: external, to: destination) }
            let app = AppItem(name: "Example.app", path: path, status: AppStatus.linked)
            let report = try inspectWithoutMutatingFixture(
                app: app, localEntries: AppPortalMaintenance.entries(at: local), dockNeedsRedirect: { _, _ in false })

            XCTAssertEqual(report.entries.map(\.outcome), [.failed])
            XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
            XCTAssertEqual(try store.records(), originalRecords)
            XCTAssertTrue(fm.fileExists(atPath: path.path))
            XCTAssertTrue(fm.fileExists(atPath: local.path))
        }
    }

    func testInspectUnrelatedValidJournalDoesNotBlockPendingOrCompletedApp() throws {
        let other = externalRoot.appendingPathComponent("Pending.app")
        try makeApp(other, identifier: "org.example.pending")
        let journal = try writeJournal(source: other)
        let journalBytes = try Data(contentsOf: journal)
        let scenarios: [(path: URL, outcome: AppSearchExclusionReport.Outcome)] = [
            (external, .pending), (destination, .completed)
        ]
        for scenario in scenarios {
            if scenario.path == destination { try fm.moveItem(at: external, to: destination) }
            let app = AppItem(name: "Example.app", path: scenario.path, status: AppStatus.unlinked)
            let report = try inspectWithoutMutatingFixture(app: app, dockNeedsRedirect: { _, _ in false })

            XCTAssertEqual(report.entries.map(\.outcome), [scenario.outcome])
            XCTAssertNil(report.operationError)
            XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
            XCTAssertTrue(fm.fileExists(atPath: other.path))
        }
    }

    func testInspectExcludedAppRejectsConflictingRememberedVolumeOrBundleIdentity() throws {
        try link()
        var original = try XCTUnwrap(store.records().first)
        try AppSearchExclusionService.prepareLibrary(destination.deletingLastPathComponent())
        try fm.moveItem(at: external, to: destination)
        try fm.removeItem(at: local)
        original.externalPath = destination.path
        original.expectsLocalEntry = false
        let moved = AppItem(name: "Example.app", path: destination, status: AppStatus.unlinked)
        for conflictIsVolume in [true, false] {
            var conflicting = original
            if conflictIsVolume {
                conflicting.volumeUUID = "different-volume"
            } else {
                conflicting.targetBundleIdentifier = "org.unrelated.application"
            }
            let records = try JSONEncoder().encode([conflicting])
            try records.write(to: root.appendingPathComponent("records.json"))

            let report = try inspectWithoutMutatingFixture(app: moved, dockNeedsRedirect: { _, _ in false })

            XCTAssertEqual(report.entries.map(\.outcome), [.failed],
                           "The noindex location cannot override remembered application identity")
            XCTAssertEqual(try store.records(), [conflicting])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("records.json")), records)
        }
    }

    private func inspectWithoutMutatingFixture(
        app: AppItem, localEntries: [AppPortalMaintenance.Entry] = [],
        dockNeedsRedirect: (URL, URL) throws -> Bool
    ) throws -> AppSearchExclusionReport {
        func identities() throws -> [String: AppSearchExclusionService.FileIdentity] {
            try Dictionary(uniqueKeysWithValues: SignatureSnapshot.items(in: root).map {
                ($0.path, try AppSearchExclusionService.FileIdentity.read($0))
            })
        }
        let originalFingerprint = try SignatureSnapshot.fingerprint(of: root)
        let originalIdentities = try identities()

        let report = AppSearchExclusionService.inspect(
            apps: [app], externalRoot: externalRoot, localEntries: localEntries,
            store: store, dockNeedsRedirect: dockNeedsRedirect)

        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: root), originalFingerprint,
                       "Inspection must not create, remove, or change fixture files")
        XCTAssertEqual(try identities(), originalIdentities,
                       "Inspection must not rewrite records or replace existing applications")
        return report
    }

    func testConversionPreservesBundleAndDocumentAndRetargetsExistingPortal() async throws {
        try link()
        let data = try Data(contentsOf: external.appendingPathComponent("Contents/Info.plist"))
        let identity = try AppSearchExclusionService.FileIdentity.read(external)
        let document = externalRoot.appendingPathComponent("Notes.txt")
        try Data("searchable document".utf8).write(to: document)
        try fm.setAttributes([.immutable: true], ofItemAtPath: external.path)
        var dockPaths: [URL] = []
        let mover = AppMigrationService(dockShortcutUpdater: { source, destination in
            dockPaths = [source, destination]; return 1
        }, runningApplications: { [] })
        let result = try await mover.excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [local], store: store)
        XCTAssertEqual(result.destination.path, destination.path)
        XCTAssertEqual(try AppSearchExclusionService.FileIdentity.read(destination), identity)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")), data)
        XCTAssertEqual(try CodeSigner.resolveAppURL(at: local).standardizedFileURL.path, destination.path)
        XCTAssertEqual(try store.records().first?.externalPath, destination.path)
        XCTAssertEqual(try fm.attributesOfItem(atPath: destination.path)[.immutable] as? Bool, true)
        XCTAssertEqual(dockPaths.map(\.path), [external.path, destination.path])
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "searchable document")
        XCTAssertFalse(fm.fileExists(atPath: externalRoot.appendingPathComponent(".metadata_never_index").path))
        XCTAssertFalse(fm.fileExists(atPath: external.path))
    }

    func testConversionWithLockedPkgInfoPreservesSignedOriginalAndInstallsIndependentPortal() async throws {
        defer { unlockOwnedExclusionFixture() }
        let pkgInfoPath = "Contents/PkgInfo"
        let pkgInfo = external.appendingPathComponent(pkgInfoPath)
        let pkgInfoBytes = Data("APPLLOCK".utf8)
        try pkgInfoBytes.write(to: pkgInfo)
        let executable = external.appendingPathComponent("Contents/MacOS/Example")
        let nativeLauncher = try XCTUnwrap(Bundle.main.url(forResource: "StubLauncherBinary", withExtension: nil))
        try fm.removeItem(at: executable)
        try fm.copyItem(at: nativeLauncher, to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try runFixtureCodesign(["--force", "--sign", "-", "--timestamp=none", external.path])
        try link()

        let attributeName = "com.appports.tests.locked-exclusion"
        let marker = Data("preserve real application metadata".utf8)
        for url in [external, pkgInfo] {
            let status = marker.withUnsafeBytes {
                setxattr(url.path, attributeName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            try fm.setAttributes([.immutable: true], ofItemAtPath: url.path)
        }
        try runFixtureCodesign(["--verify", "--strict", external.path])
        let originalIdentity = try AppSearchExclusionService.FileIdentity.read(external)
        let originalPkgInfoIdentity = try AppSearchExclusionService.FileIdentity.read(pkgInfo)
        let originalFingerprint = try SignatureSnapshot.fingerprint(of: external)
        let originalFlags = try fixtureFlags(in: external)

        let result = try await service().excludeFromSearch(
            app: item, externalRoot: externalRoot, localEntries: [local], store: store)

        XCTAssertEqual(result.destination.standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertEqual(destination.deletingLastPathComponent().lastPathComponent, "AppPorts.noindex")
        XCTAssertFalse(fm.fileExists(atPath: external.path))
        XCTAssertEqual(try AppSearchExclusionService.FileIdentity.read(destination), originalIdentity)
        let movedPkgInfo = destination.appendingPathComponent(pkgInfoPath)
        XCTAssertEqual(try AppSearchExclusionService.FileIdentity.read(movedPkgInfo), originalPkgInfoIdentity)
        XCTAssertEqual(try Data(contentsOf: movedPkgInfo), pkgInfoBytes)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: destination), originalFingerprint)
        XCTAssertEqual(try fixtureFlags(in: destination), originalFlags)
        for url in [destination, movedPkgInfo] {
            var actual = Data(count: marker.count)
            let count = actual.withUnsafeMutableBytes {
                getxattr(url.path, attributeName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            XCTAssertEqual(count, marker.count)
            XCTAssertEqual(actual, marker)
        }
        try runFixtureCodesign(["--verify", "--strict", destination.path])

        let portalPkgInfo = local.appendingPathComponent(pkgInfoPath)
        XCTAssertEqual(try Data(contentsOf: portalPkgInfo), pkgInfoBytes)
        XCTAssertEqual(try fm.attributesOfItem(atPath: portalPkgInfo.path)[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try SignatureSnapshot.info(at: portalPkgInfo).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertNotEqual(try AppSearchExclusionService.FileIdentity.read(portalPkgInfo), originalPkgInfoIdentity)
        XCTAssertEqual(try CodeSigner.resolveAppURL(at: local).standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertEqual(try store.records().first?.externalPath, destination.path)
        try runFixtureCodesign(["--verify", "--strict", local.path])
        let pendingJournals = try fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).filter {
            $0.hasPrefix(".appports-exclusion-") && $0.hasSuffix(".json")
        }
        XCTAssertTrue(pendingJournals.isEmpty, "Successful exclusion must retire its recovery journal")
    }

    private func fixtureFlags(in bundle: URL) throws -> [String: UInt32] {
        var result: [String: UInt32] = [:]
        for url in try SignatureSnapshot.items(in: bundle) {
            result[String(url.path.dropFirst(bundle.path.count))] = try SignatureSnapshot.info(at: url).st_flags
        }
        return result
    }

    private func runFixtureCodesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let output = Pipe()
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AppSearchExclusionTests.Codesign", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func unlockOwnedExclusionFixture() {
        guard root.lastPathComponent.hasPrefix("Exclusion-"),
              root.deletingLastPathComponent() == fm.temporaryDirectory.resolvingSymlinksInPath() else {
            XCTFail("Refusing to unlock outside this test's temporary fixture")
            return
        }
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
            // The UUID root belongs to this fixture; -P never follows its symbolic links.
            process.arguments = ["-R", "-P", "nouchg", root.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        } catch {
            XCTFail("Unable to unlock test-owned exclusion fixture: \(error)")
        }
    }

    func testDeletedPortalStaysDeletedAndExcludedAppIsStillScanned() async throws {
        try link()
        try fm.removeItem(at: local)
        try store.reconcileLocalPresence()
        _ = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [], store: store)
        XCTAssertFalse(fm.fileExists(atPath: local.path))
        XCTAssertEqual(try store.records().first?.expectsLocalEntry, false)
        XCTAssertEqual(try store.records().first?.externalPath, destination.path)
        let apps = await AppScanner().scanExternalApps(at: externalRoot, localAppsDir: local.deletingLastPathComponent())
        XCTAssertEqual(apps.map { $0.path.resolvingSymlinksInPath().path }, [destination.resolvingSymlinksInPath().path])
        XCTAssertEqual(apps.first?.containerKind, .standaloneApp)
        XCTAssertEqual(apps.first?.status, AppStatus.unlinked)
    }

    func testSameNameCollisionNeverOverwritesEitherCopy() async throws {
        try makeApp(destination, identifier: "org.example.other")
        do {
            _ = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [], store: store)
            XCTFail("Must reject collision")
        } catch { }
        XCTAssertTrue(fm.fileExists(atPath: external.path))
        XCTAssertEqual(NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String, "org.example.other")
    }

    func testWrongVolumeAndReplacedBundleAreRejected() async throws {
        try link()
        var record = try XCTUnwrap(store.records().first)
        record.volumeUUID = "different-volume"
        try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("records.json"))
        do {
            _ = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [local], store: store)
            XCTFail("Wrong volume must be rejected")
        } catch { }
        XCTAssertTrue(fm.fileExists(atPath: external.path))
        record.volumeUUID = nil
        record.targetBundleIdentifier = "org.replacement"
        try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("records.json"))
        do {
            _ = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [local], store: store)
            XCTFail("Replaced bundle must be rejected")
        } catch { }
        XCTAssertTrue(fm.fileExists(atPath: external.path))
    }

    func testActualReceiptExcludesMASDespiteStaleScanFlags() async throws {
        try fm.createDirectory(at: external.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
        try Data().write(to: external.appendingPathComponent("Contents/_MASReceipt/receipt"))
        XCTAssertNotNil(AppSearchExclusionService.unsupportedReason(for: item))
        XCTAssertEqual(AppSearchExclusionService.destination(for: item, in: externalRoot), external)
        let apps = await AppScanner().scanExternalApps(at: externalRoot, localAppsDir: local.deletingLastPathComponent())
        XCTAssertEqual(apps.first?.isAppStoreApp, true)
    }

    func testMixedSuiteAndIOSKeepOriginalLayout() throws {
        let suite = AppItem(name: "Suite", path: externalRoot, status: AppStatus.unlinked,
                            isFolder: true, containerKind: .appSuiteFolder, appCount: 1)
        XCTAssertNotNil(AppSearchExclusionService.unsupportedReason(for: suite))
        let destination = AppSearchExclusionService.destination(for: suite, in: root)
        XCTAssertEqual(destination, root.appendingPathComponent("Suite"))
        try fm.createDirectory(at: external.appendingPathComponent("Wrapper"), withIntermediateDirectories: true)
        XCTAssertNotNil(AppSearchExclusionService.unsupportedReason(for: item))
    }

    func testLibrarySymlinkIsRejectedWithoutWritingToTarget() throws {
        let unrelated = root.appendingPathComponent("Documents")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: AppSearchExclusionService.library(in: externalRoot), withDestinationURL: unrelated)
        XCTAssertThrowsError(try AppSearchExclusionService.prepareLibrary(AppSearchExclusionService.library(in: externalRoot)))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: unrelated.path).isEmpty)
    }

    func testRunningAppIsRejectedAtExecutionTime() async throws {
        let mover = AppMigrationService(dockShortcutUpdater: { _, _ in XCTFail("No Dock write"); return 0 },
            runningApplications: { [.init(bundleURL: self.external, bundleIdentifier: "org.example.exclusion")] })
        do {
            _ = try await mover.excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [], store: store)
            XCTFail("Running app must be rejected")
        } catch { }
        XCTAssertTrue(fm.fileExists(atPath: external.path))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    func testFailedPortalInstallRollsBackPathsRecordsAndLock() async throws {
        try link()
        try fm.setAttributes([.immutable: true], ofItemAtPath: external.path)
        let originalRecords = try store.records()
        let failing = FailingPortalInstallFileManager(local: local)
        do {
            _ = try await service(fileManager: failing).excludeFromSearch(app: item, externalRoot: externalRoot,
                                                                          localEntries: [local], store: store)
            XCTFail("Install failure must surface")
        } catch { }
        XCTAssertTrue(failing.didFail)
        XCTAssertTrue(fm.fileExists(atPath: external.path))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(try CodeSigner.resolveAppURL(at: local).standardizedFileURL, external)
        XCTAssertEqual(try store.records(), originalRecords)
        XCTAssertEqual(try fm.attributesOfItem(atPath: external.path)[.immutable] as? Bool, true)
    }

    func testRealDockServiceKeepsExistingPinAndUsesNewRealBundle() async throws {
        try link()
        var tiles: [[String: Any]] = [["GUID": 42, "tile-type": "file-tile", "tile-data": [
            "file-data": ["_CFURLString": external.absoluteString, "_CFURLStringType": 15],
            "bundle-identifier": "org.example.exclusion", "file-label": "Example"
        ]]]
        let dock = DockShortcutService(store: .init(read: { tiles }, write: { tiles = $0 }, isManaged: { false }), reload: {})
        let mover = AppMigrationService(dockShortcutUpdater: { try dock.redirectShortcuts(from: $0, to: $1) }, runningApplications: { [] })
        let result = try await mover.excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [local], store: store)
        XCTAssertTrue(result.dockSynchronized)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles.first?["GUID"] as? Int, 42)
        let data = try XCTUnwrap(tiles.first?["tile-data"] as? [String: Any])
        let file = try XCTUnwrap(data["file-data"] as? [String: Any])
        let path = try XCTUnwrap(file["_CFURLString"] as? String)
        XCTAssertEqual(URL(string: path)?.path, destination.path)
        XCTAssertEqual(data["bundle-identifier"] as? String, "org.example.exclusion")
    }

    func testDockWarningOnlyCompletesAfterRealRetrySucceeds() async throws {
        try link()
        var tiles: [[String: Any]] = [["GUID": 42, "tile-type": "file-tile", "tile-data": [
            "file-data": ["_CFURLString": external.absoluteString, "_CFURLStringType": 15],
            "bundle-identifier": "org.example.exclusion", "file-label": "Example"
        ]]]
        var writesAllowed = false
        let dock = DockShortcutService(store: .init(read: { tiles }, write: {
            guard writesAllowed else { throw NSError(domain: "DockRetryTest", code: 1) }
            tiles = $0
        }, isManaged: { false }), reload: {})
        let mover = AppMigrationService(dockShortcutUpdater: { try dock.redirectShortcuts(from: $0, to: $1) },
            dockShortcutRetryUpdater: { try dock.redirectShortcuts(from: $0, to: $1, requiringBundleIdentity: true) }, runningApplications: { [] })
        let first = try await mover.excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [local], store: store)
        XCTAssertFalse(first.dockSynchronized)
        let moved = AppItem(name: "Example.app", path: destination, status: AppStatus.linked)
        let second = try await mover.excludeFromSearch(app: moved, externalRoot: externalRoot, localEntries: [local], store: store)
        XCTAssertFalse(second.dockSynchronized, "Being in .noindex does not prove the Dock update succeeded")
        writesAllowed = true
        let third = try await mover.excludeFromSearch(app: moved, externalRoot: externalRoot, localEntries: [local], store: store)
        XCTAssertTrue(third.dockSynchronized)
        let data = try XCTUnwrap(tiles.first?["tile-data"] as? [String: Any])
        let file = try XCTUnwrap(data["file-data"] as? [String: Any])
        XCTAssertEqual(URL(string: try XCTUnwrap(file["_CFURLString"] as? String))?.path, destination.path)
    }

    func testDockRetryPreservesReusedOriginalPath() async throws {
        _ = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [], store: store)
        try makeApp(external, identifier: "org.user.new-application")
        var redirects: [(URL, URL)] = []
        let mover = AppMigrationService(dockShortcutUpdater: { redirects.append(($0, $1)); return 0 }, runningApplications: { [] })
        let moved = AppItem(name: "Example.app", path: destination, status: AppStatus.unlinked)
        _ = try await mover.excludeFromSearch(app: moved, externalRoot: externalRoot, localEntries: [], store: store)
        XCTAssertEqual(redirects.map { $0.0.path }, [destination.path])
        XCTAssertEqual(redirects.map { $0.1.path }, [destination.path])
    }

    func testDockRetryNeverClaimsUnrelatedSameNamedStalePin() async throws {
        _ = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [], store: store)
        let original: [[String: Any]] = [["GUID": 99, "tile-type": "file-tile", "tile-data": [
            "file-data": ["_CFURLString": external.absoluteString, "_CFURLStringType": 15],
            "bundle-identifier": "org.other.deleted-application", "file-label": "Example"
        ]]]
        var writes = 0
        let dock = DockShortcutService(store: .init(read: { original }, write: { _ in writes += 1 }, isManaged: { false }), reload: {})
        let mover = AppMigrationService(dockShortcutUpdater: { _, _ in XCTFail("Retry must use identity-checked updater"); return 0 },
            dockShortcutRetryUpdater: { try dock.redirectShortcuts(from: $0, to: $1, requiringBundleIdentity: true) }, runningApplications: { [] })
        let moved = AppItem(name: "Example.app", path: destination, status: AppStatus.unlinked)
        let result = try await mover.excludeFromSearch(app: moved, externalRoot: externalRoot, localEntries: [], store: store)
        XCTAssertFalse(result.dockSynchronized)
        XCTAssertEqual(writes, 0)
    }

    func testPendingJournalBlocksAlreadyMovedCopy() async throws {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: external, to: destination)
        try Data("unfinished".utf8).write(to: destination.deletingLastPathComponent().appendingPathComponent(".appports-exclusion-pending.json"))
        let app = AppItem(name: "Example.app", path: destination, status: AppStatus.unlinked)
        do {
            _ = try await service().excludeFromSearch(app: app, externalRoot: externalRoot, localEntries: [], store: store)
            XCTFail("Already moved is not equivalent to a finished transaction")
        } catch { }
        XCTAssertTrue(fm.fileExists(atPath: destination.path))
    }

    func testUnrelatedRecoveryDoesNotHidePreviouslyCompletedApp() async throws {
        try link()
        _ = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [local], store: store)
        let other = externalRoot.appendingPathComponent("Pending.app")
        try makeApp(other, identifier: "org.example.pending")
        let journal = try writeJournal(source: other)
        let journalData = try Data(contentsOf: journal)
        let records = try store.records()
        let identity = try AppSearchExclusionService.FileIdentity.read(destination)
        var retryCount = 0
        let mover = AppMigrationService(dockShortcutUpdater: { _, _ in XCTFail("Must use retry updater"); return 0 },
            dockShortcutRetryUpdater: { _, target in
                XCTAssertEqual(target.path, self.destination.path)
                retryCount += 1
                return 0
            }, runningApplications: { [] })
        let moved = AppItem(name: "Example.app", path: destination, status: AppStatus.linked)
        let result = try await mover.excludeFromSearch(app: moved, externalRoot: externalRoot, localEntries: [local], store: store)
        XCTAssertTrue(result.dockSynchronized)
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(result.destination.path, destination.path)
        XCTAssertEqual(try AppSearchExclusionService.FileIdentity.read(destination), identity)
        XCTAssertEqual(try CodeSigner.resolveAppURL(at: local).standardizedFileURL.path, destination.path)
        XCTAssertEqual(try store.records(), records)
        XCTAssertEqual(try Data(contentsOf: journal), journalData)
    }

    func testUnrelatedRecoveryAllowsConversionAndPreservesRecoveryMaterial() async throws {
        try link()
        let other = externalRoot.appendingPathComponent("Pending.app")
        let otherLocal = local.deletingLastPathComponent().appendingPathComponent("Pending.app")
        try makeApp(other, identifier: "org.example.pending")
        try makeApp(otherLocal, identifier: "org.example.pending.portal")
        let portal = try journalPortal(at: otherLocal)
        try fm.createDirectory(at: portal.stage.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data("recoverable backup".utf8).write(to: portal.backup)
        let journal = try writeJournal(source: other, portals: [portal])
        let journalData = try Data(contentsOf: journal)
        let result = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [local], store: store)
        XCTAssertTrue(result.dockSynchronized)
        XCTAssertEqual(try CodeSigner.resolveAppURL(at: local).standardizedFileURL.path, destination.path)
        XCTAssertEqual(try store.records().first?.externalPath, destination.path)
        XCTAssertTrue(fm.fileExists(atPath: other.path))
        XCTAssertEqual(try Data(contentsOf: journal), journalData)
        XCTAssertEqual(try String(contentsOf: portal.backup, encoding: .utf8), "recoverable backup")
    }

    func testAlreadyExcludedRunningAppKeepsCompletedStatus() async throws {
        try link()
        _ = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [local], store: store)
        let identity = try AppSearchExclusionService.FileIdentity.read(destination)
        let mover = AppMigrationService(dockShortcutUpdater: { _, _ in 0 },
            runningApplications: { [.init(bundleURL: self.destination, bundleIdentifier: "org.example.exclusion")] })
        let moved = AppItem(name: "Example.app", path: destination, status: AppStatus.linked)
        let result = try await mover.excludeFromSearch(app: moved, externalRoot: externalRoot, localEntries: [local], store: store)
        XCTAssertTrue(result.dockSynchronized)
        XCTAssertEqual(try AppSearchExclusionService.FileIdentity.read(destination), identity)
        XCTAssertEqual(try CodeSigner.resolveAppURL(at: local).standardizedFileURL.path, destination.path)
    }

    func testRelatedValidJournalBlocksBeforeAndAfterExternalMove() async throws {
        try link()
        let journal = try writeJournal(source: external, portals: [journalPortal(at: local)])
        let records = try store.records()
        let mover = AppMigrationService(dockShortcutUpdater: { _, _ in XCTFail("No Dock write"); return 0 }, runningApplications: { [] })
        for path in [external, destination] {
            if path == destination { try fm.moveItem(at: external, to: destination) }
            do {
                _ = try await mover.excludeFromSearch(app: .init(name: "Example.app", path: path, status: AppStatus.linked),
                    externalRoot: externalRoot, localEntries: [local], store: store)
                XCTFail("A related journal must block regardless of the current app location")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(journal.path))
            }
            XCTAssertTrue(fm.fileExists(atPath: path.path))
            XCTAssertTrue(fm.fileExists(atPath: journal.path))
            XCTAssertEqual(try store.records(), records)
        }
    }

    func testRecoveryReservesRememberedPortalEvenForDifferentAppName() async throws {
        try link()
        let other = externalRoot.appendingPathComponent("Pending.app")
        try makeApp(other, identifier: "org.example.pending")
        let journal = try writeJournal(source: other, portals: [journalPortal(at: local)])
        do {
            _ = try await service().excludeFromSearch(app: item, externalRoot: externalRoot, localEntries: [], store: store)
            XCTFail("Remembered portals must also be checked for recovery conflicts")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(journal.path))
        }
        XCTAssertTrue(fm.fileExists(atPath: external.path))
        XCTAssertEqual(try CodeSigner.resolveAppURL(at: local).standardizedFileURL.path, external.path)
    }

    func testRecoveryFindsRenamedAppByFileIdentity() async throws {
        let journal = try writeJournal(source: external)
        let renamed = destination.deletingLastPathComponent().appendingPathComponent("Renamed.app")
        try fm.moveItem(at: external, to: renamed)
        do {
            _ = try await service().excludeFromSearch(app: .init(name: "Renamed.app", path: renamed, status: AppStatus.unlinked),
                externalRoot: externalRoot, localEntries: [], store: store)
            XCTFail("A rename cannot turn an unfinished transaction into a completed one")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(journal.path))
        }
        XCTAssertTrue(fm.fileExists(atPath: renamed.path))
    }

    func testInvalidJournalScopeIsNeverAssumedUnrelated() throws {
        let other = externalRoot.appendingPathComponent("Pending.app")
        try makeApp(other, identifier: "org.example.pending")
        let journal = try writeJournal(source: other)
        let original = try Data(contentsOf: journal)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for (key, value) in [("source", "https://example.com/Pending.app"),
                             ("destination", root.appendingPathComponent("Elsewhere/Pending.app").absoluteString),
                             ("volumeUUID", "another-volume"), ("phase", "unknown")] {
            var invalid = valid
            invalid[key] = value
            let bytes = try JSONSerialization.data(withJSONObject: invalid)
            try bytes.write(to: journal)
            XCTAssertEqual(try AppSearchExclusionService.blockingJournal(in: destination.deletingLastPathComponent(),
                affecting: [external, destination])?.standardizedFileURL.path, journal.standardizedFileURL.path,
                "Invalid \(key) must block")
            XCTAssertEqual(try Data(contentsOf: journal), bytes)
        }
        try fm.removeItem(at: journal)
        let realFile = root.appendingPathComponent("journal.json")
        try original.write(to: realFile)
        try fm.createSymbolicLink(at: journal, withDestinationURL: realFile)
        XCTAssertEqual(try AppSearchExclusionService.blockingJournal(in: destination.deletingLastPathComponent(),
            affecting: [external, destination])?.standardizedFileURL.path, journal.standardizedFileURL.path,
            "A symlink journal must block")
        XCTAssertEqual(try Data(contentsOf: realFile), original)
    }

    func testReplacementBetweenCheckAndBackupPreservesRealApplication() async throws {
        try link()
        let replacement = root.appendingPathComponent("Replacement.app")
        try makeApp(replacement, identifier: "org.user.replacement")
        let manager = ReplacingPortalFileManager(local: local, replacement: replacement)
        do {
            _ = try await service(fileManager: manager).excludeFromSearch(app: item, externalRoot: externalRoot,
                                                                        localEntries: [local], store: store)
            XCTFail("Replacement must abort relocation")
        } catch { }
        XCTAssertTrue(manager.didReplace)
        XCTAssertEqual(NSDictionary(contentsOf: local.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String,
                       "org.user.replacement")
        XCTAssertTrue(fm.fileExists(atPath: external.path))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    func testMultipleAppsInLibraryStillDetectLocalUpdate() async throws {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: external, to: destination)
        try makeApp(destination.deletingLastPathComponent().appendingPathComponent("Second.app"), identifier: "org.example.second")
        try makeApp(local)
        let plist = local.appendingPathComponent("Contents/Info.plist")
        var values = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        values["CFBundleVersion"] = "2"
        values["CFBundleShortVersionString"] = "2"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: plist)
        let items = await AppScanner().scanLocalApps(at: local.deletingLastPathComponent(), runningAppURLs: [], externalAppsDir: externalRoot)
        XCTAssertEqual(items.first?.status, AppStatus.pendingMoveOut)
    }

    func testReplacementDuringRollbackIsPreservedWithRecoveryRecord() async throws {
        try link()
        let second = local.deletingLastPathComponent().appendingPathComponent("ZSecond.app")
        try service().linkApp(appToLink: item, destinationURL: second)
        try AppPortalMaintenance.rememberEntries(at: second, explicitOperation: true, store: store)
        let replacement = root.appendingPathComponent("UserReplacement.app")
        try makeApp(replacement, identifier: "org.user.rollback-replacement")
        let manager = ReplacingDuringRollbackFileManager(first: local, second: second, replacement: replacement)
        do {
            _ = try await service(fileManager: manager).excludeFromSearch(app: item, externalRoot: externalRoot,
                localEntries: [local, second], store: store)
            XCTFail("Rollback conflict must be reported")
        } catch { }
        XCTAssertTrue(manager.didReplace)
        XCTAssertEqual(NSDictionary(contentsOf: local.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String,
                       "org.user.rollback-replacement")
        XCTAssertTrue(fm.fileExists(atPath: external.path))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            .contains { $0.hasPrefix(".appports-exclusion-") && $0.hasSuffix(".json") })
    }

    func testNewMigrationAndRestoreUseExcludedCopy() async throws {
        try fm.moveItem(at: external, to: local)
        let app = AppItem(name: "Example.app", path: local, status: AppStatus.local)
        let target = AppSearchExclusionService.destination(for: app, in: externalRoot)
        XCTAssertEqual(target, destination)
        try await service().moveAndLink(appToMove: app, destinationURL: target, isRunning: false,
                                       lockExternal: false, progressHandler: nil)
        XCTAssertEqual(try CodeSigner.resolveAppURL(at: local).standardizedFileURL.path, target.path)
        _ = try await service().moveBack(app: AppItem(name: "Example.app", path: target, status: AppStatus.linked),
                                        localDestinationURL: local, progressHandler: nil)
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertTrue(fm.fileExists(atPath: local.appendingPathComponent("Contents/MacOS/Example").path))
    }
}

private final class FailingPortalInstallFileManager: FileManager {
    let local: URL
    var didFail = false
    init(local: URL) { self.local = local; super.init() }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL == local, srcURL.lastPathComponent == local.lastPathComponent,
           srcURL.deletingLastPathComponent().lastPathComponent.hasPrefix(".appports-exclusion-"), !didFail {
            didFail = true
            throw NSError(domain: "ExclusionTest", code: 1)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class ReplacingPortalFileManager: FileManager {
    let local: URL
    let replacement: URL
    var didReplace = false
    init(local: URL, replacement: URL) { self.local = local; self.replacement = replacement; super.init() }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.path == local.path, dstURL.lastPathComponent == "original", !didReplace {
            didReplace = true
            try super.removeItem(at: local)
            try super.moveItem(at: replacement, to: local)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class ReplacingDuringRollbackFileManager: FileManager {
    let first: URL
    let second: URL
    let replacement: URL
    var didFail = false
    var didReplace = false
    init(first: URL, second: URL, replacement: URL) {
        self.first = first; self.second = second; self.replacement = replacement; super.init()
    }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.path == second.path, srcURL.lastPathComponent == second.lastPathComponent, !didFail {
            didFail = true
            throw NSError(domain: "ExclusionTest", code: 2)
        }
        if didFail, srcURL.path == first.path, dstURL.lastPathComponent.hasPrefix(".appports-cleanup-"), !didReplace {
            didReplace = true
            try super.removeItem(at: first)
            try super.moveItem(at: replacement, to: first)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
