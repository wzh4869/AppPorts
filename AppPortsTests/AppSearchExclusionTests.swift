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
