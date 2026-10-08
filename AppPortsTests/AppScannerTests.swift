import XCTest
@testable import AppPorts

final class AppScannerTests: XCTestCase {
    private let fileManager = FileManager.default

    func testDisplayedSizeForWholeAppSymlinkUsesLocalPortalFootprint() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Cherry Studio.app")
        let localAppURL = workspace.localAppsURL.appendingPathComponent("Cherry Studio.app")
        try createAppBundle(at: externalAppURL, payloadSize: 4096)
        try fileManager.createSymbolicLink(at: localAppURL, withDestinationURL: externalAppURL)

        let scanner = AppScanner()
        let linkedLocalItem = AppItem(name: "Cherry Studio.app", path: localAppURL, status: "已链接")

        let displayedSize = await scanner.calculateDisplayedSize(for: linkedLocalItem, isLocalEntry: true)
        let logicalSize = await scanner.calculateDirectorySize(at: localAppURL)

        XCTAssertGreaterThan(logicalSize, 0)
        XCTAssertLessThan(displayedSize, logicalSize)
    }

    func testDisplayedSizeForDeepWrapperUsesWrapperFootprint() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Notion.app")
        let localAppURL = workspace.localAppsURL.appendingPathComponent("Notion.app")
        try createAppBundle(at: externalAppURL, payloadSize: 4096)

        try fileManager.createDirectory(at: localAppURL, withIntermediateDirectories: false)
        try fileManager.createSymbolicLink(
            at: localAppURL.appendingPathComponent("Contents"),
            withDestinationURL: externalAppURL.appendingPathComponent("Contents")
        )

        let scanner = AppScanner()
        let linkedLocalItem = AppItem(name: "Notion.app", path: localAppURL, status: "已链接")

        let displayedSize = await scanner.calculateDisplayedSize(for: linkedLocalItem, isLocalEntry: true)
        let logicalSize = await scanner.calculateDirectorySize(at: localAppURL)

        XCTAssertGreaterThan(logicalSize, 0)
        XCTAssertLessThan(displayedSize, logicalSize)
    }

    func testDisplayedSizeForExternalEntryKeepsLogicalContentSize() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Cherry Studio.app")
        try createAppBundle(at: externalAppURL, payloadSize: 4096)

        let scanner = AppScanner()
        let externalItem = AppItem(name: "Cherry Studio.app", path: externalAppURL, status: "已链接")

        let displayedSize = await scanner.calculateDisplayedSize(for: externalItem, isLocalEntry: false)
        let logicalSize = await scanner.calculateDirectorySize(at: externalAppURL)

        XCTAssertEqual(displayedSize, logicalSize)
    }

    func testLocalScanPrefersSingleAppContainerOverStandaloneDuplicate() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let standaloneAppURL = workspace.localAppsURL.appendingPathComponent("Adobe Photoshop 2026.app")
        let containerURL = workspace.localAppsURL.appendingPathComponent("Adobe Photoshop 2026")
        let nestedAppURL = containerURL.appendingPathComponent("Adobe Photoshop 2026.app")

        try createAppBundle(at: standaloneAppURL, payloadSize: 1024, bundleID: "com.example.photoshop")
        try createAppBundle(at: nestedAppURL, payloadSize: 1024, bundleID: "com.example.photoshop")

        let items = await AppScanner().scanLocalApps(at: workspace.localAppsURL, runningAppURLs: Set<URL>())

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.containerKind, .singleAppContainer)
        XCTAssertEqual(item.path.standardizedFileURL, containerURL.standardizedFileURL)
        XCTAssertEqual(item.displayURL.standardizedFileURL, nestedAppURL.standardizedFileURL)
        XCTAssertTrue(item.usesFolderOperation)
        XCTAssertEqual(item.displayName, "Adobe Photoshop 2026.app")
    }

    func testExternalScanPrefersSingleAppContainerOverStandaloneDuplicate() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let standaloneAppURL = workspace.externalRootURL.appendingPathComponent("Adobe Illustrator 2026.app")
        let containerURL = workspace.externalRootURL.appendingPathComponent("Adobe Illustrator 2026")
        let nestedAppURL = containerURL.appendingPathComponent("Adobe Illustrator 2026.app")

        try createAppBundle(at: standaloneAppURL, payloadSize: 1024, bundleID: "com.example.illustrator")
        try createAppBundle(at: nestedAppURL, payloadSize: 1024, bundleID: "com.example.illustrator")
        try fileManager.createSymbolicLink(
            at: workspace.localAppsURL.appendingPathComponent("Adobe Illustrator 2026"),
            withDestinationURL: containerURL
        )

        let items = await AppScanner().scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.containerKind, .singleAppContainer)
        XCTAssertEqual(item.status, "已链接")
        XCTAssertEqual(item.path.standardizedFileURL, containerURL.standardizedFileURL)
        XCTAssertEqual(item.displayURL.standardizedFileURL, nestedAppURL.standardizedFileURL)
    }

    func testFilePathScanKeepsSameIdentityCopiesForExclusionInspection() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let root = workspace.rootURL.resolvingSymlinksInPath()
        let externalRoot = workspace.externalRootURL.resolvingSymlinksInPath()
        let localDirectory = workspace.localAppsURL.resolvingSymlinksInPath()
        let original = externalRoot.appendingPathComponent("Example.app")
        let excluded = AppSearchExclusionService.library(in: externalRoot).appendingPathComponent("Example.app")
        let originalPath = original.standardizedFileURL.path
        let excludedPath = excluded.standardizedFileURL.path
        let local = localDirectory.appendingPathComponent("Example.app")
        let identifier = "org.appports.scanner.duplicate"
        try createAppBundle(at: original, payloadSize: 16, bundleID: identifier, version: "1")
        try createAppBundle(at: excluded, payloadSize: 32, bundleID: identifier, version: "2")
        try createScannerStub(at: local, pointingTo: excluded, bundleID: identifier)
        let before = try scannerFixtureSnapshot(at: root)
        let recordsURL = root.appendingPathComponent("state/records.json")
        let store = AppSearchRecordStore(fileURL: recordsURL)
        let scanner = AppScanner(backupDirectoryURL: root.appendingPathComponent("signature-backups"), adHocProbe: { _ in false })

        let defaultItems = await scanner.scanExternalApps(at: externalRoot, localAppsDir: localDirectory)
        XCTAssertEqual(defaultItems.map { $0.path.standardizedFileURL.path }, [excludedPath])
        XCTAssertEqual(defaultItems.first?.status, AppStatus.linked)

        let copies = await scanner.scanExternalApps(at: externalRoot, localAppsDir: localDirectory, grouping: .filePath)
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(Set(copies.map { $0.path.standardizedFileURL.path }), Set([originalPath, excludedPath]))
        let originalItem = try XCTUnwrap(copies.first { $0.path.standardizedFileURL.path == originalPath })
        let excludedItem = try XCTUnwrap(copies.first { $0.path.standardizedFileURL.path == excludedPath })
        let localEntries = AppPortalMaintenance.entries(at: local)
        XCTAssertEqual(localEntries.count, 1)
        var inspectedDockTargets: [String] = []
        let report = AppSearchExclusionService.inspect(
            apps: copies, externalRoot: externalRoot, localEntries: localEntries, store: store,
            dockNeedsRedirect: { source, target in
                // The root path is still occupied; only the excluded copy's own pins may be checked.
                XCTAssertEqual(source.standardizedFileURL.path, excludedPath)
                XCTAssertEqual(target.standardizedFileURL.path, excludedPath)
                inspectedDockTargets.append(target.standardizedFileURL.path)
                return false
            }
        )

        XCTAssertNil(report.operationError)
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.entries.first { $0.id == originalItem.id }?.outcome, .failed)
        XCTAssertEqual(report.entries.first { $0.id == excludedItem.id }?.outcome, .completed)
        XCTAssertEqual(inspectedDockTargets, [excludedPath])
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: recordsURL.path))
        XCTAssertEqual(try scannerFixtureSnapshot(at: root), before)
    }

    func testFilePathScanRetainsDifferentNamesWithoutCreatingLibraryOrRecords() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let root = workspace.rootURL.resolvingSymlinksInPath()
        let externalRoot = workspace.externalRootURL.resolvingSymlinksInPath()
        let first = externalRoot.appendingPathComponent("Example.app")
        let second = externalRoot.appendingPathComponent("Example Preview.app")
        for app in [first, second] {
            try createAppBundle(at: app, payloadSize: 16, bundleID: "org.appports.scanner.duplicate")
        }
        let before = try scannerFixtureSnapshot(at: root)
        let recordsURL = root.appendingPathComponent("state/records.json")
        let scanner = AppScanner(backupDirectoryURL: root.appendingPathComponent("signature-backups"), adHocProbe: { _ in false })
        let copies = await scanner.scanExternalApps(
            at: externalRoot, localAppsDir: workspace.localAppsURL.resolvingSymlinksInPath(), grouping: .filePath
        )
        let report = AppSearchExclusionService.inspect(
            apps: copies, externalRoot: externalRoot, store: AppSearchRecordStore(fileURL: recordsURL),
            dockNeedsRedirect: { _, _ in
                XCTFail("Pending copies must not inspect or update Dock")
                return false
            }
        )

        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(Set(copies.map { $0.path.standardizedFileURL.path }), Set([first.path, second.path]))
        XCTAssertNil(report.operationError)
        XCTAssertEqual(report.entries.map(\.outcome), [.pending, .pending])
        XCTAssertFalse(fileManager.fileExists(atPath: AppSearchExclusionService.library(in: externalRoot).path))
        XCTAssertFalse(fileManager.fileExists(atPath: recordsURL.path))
        XCTAssertEqual(try scannerFixtureSnapshot(at: root), before)
    }

    @MainActor
    func testFilePathScansMergeRepeatedLocalDiscoveriesOncePerStoredPath() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let root = workspace.rootURL.resolvingSymlinksInPath()
        let externalRoot = workspace.externalRootURL.resolvingSymlinksInPath()
        let firstLocal = workspace.localAppsURL.resolvingSymlinksInPath()
        let secondLocal = root.appendingPathComponent("CustomApplications")
        let original = externalRoot.appendingPathComponent("Example.app")
        let excluded = AppSearchExclusionService.library(in: externalRoot).appendingPathComponent("Example.app")
        let identifier = "org.appports.scanner.duplicate"
        for app in [original, excluded] { try createAppBundle(at: app, payloadSize: 16, bundleID: identifier) }
        try createScannerStub(at: firstLocal.appendingPathComponent("Original Shortcut.app"), pointingTo: original, bundleID: identifier)
        try createScannerStub(at: secondLocal.appendingPathComponent("Excluded Shortcut.app"), pointingTo: excluded, bundleID: identifier)
        let before = try scannerFixtureSnapshot(at: root)
        let scanner = AppScanner(backupDirectoryURL: root.appendingPathComponent("signature-backups"), adHocProbe: { _ in false })
        let view = ContentView()
        var merged: [AppItem] = []

        for localDirectory in [firstLocal, secondLocal, firstLocal, secondLocal] {
            let copies = await scanner.scanExternalApps(at: externalRoot, localAppsDir: localDirectory, grouping: .filePath)
            XCTAssertEqual(copies.count, 2, "Direct discovery and a local stub must collapse only their shared path")
            merged = view.mergeExternalApps(merged, with: copies)
        }

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map { $0.path.standardizedFileURL.path }), Set([original.path, excluded.path]))
        XCTAssertTrue(merged.allSatisfy { $0.status == AppStatus.linked })
        XCTAssertEqual(try scannerFixtureSnapshot(at: root), before)
    }

    func testLocalScanDetectsLinkedSingleAppContainerSymlink() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let externalFolderURL = workspace.externalRootURL.appendingPathComponent("Adobe Lightroom")
        let localFolderURL = workspace.localAppsURL.appendingPathComponent("Adobe Lightroom")
        let nestedAppURL = externalFolderURL.appendingPathComponent("Adobe Lightroom.app")

        try createAppBundle(at: nestedAppURL, payloadSize: 1024, bundleID: "com.example.lightroom")
        try fileManager.createSymbolicLink(at: localFolderURL, withDestinationURL: externalFolderURL)

        let items = await AppScanner().scanLocalApps(at: workspace.localAppsURL, runningAppURLs: Set<URL>())

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.containerKind, .singleAppContainer)
        XCTAssertEqual(item.status, "已链接")
        XCTAssertEqual(item.path.standardizedFileURL, localFolderURL.standardizedFileURL)
        XCTAssertEqual(item.displayURL.standardizedFileURL, nestedAppURL.standardizedFileURL)
    }

    func testExternalScanIncludesLinkedSingleAppContainerNestedUnderSelectedRoot() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let nestedSuitesURL = workspace.externalRootURL.appendingPathComponent("Suites")
        let externalFolderURL = nestedSuitesURL.appendingPathComponent("Adobe Premiere Pro")
        let localFolderURL = workspace.localAppsURL.appendingPathComponent("Adobe Premiere Pro")
        let nestedAppURL = externalFolderURL.appendingPathComponent("Adobe Premiere Pro.app")

        try fileManager.createDirectory(at: nestedSuitesURL, withIntermediateDirectories: true)
        try createAppBundle(at: nestedAppURL, payloadSize: 1024, bundleID: "com.example.premiere")
        try fileManager.createSymbolicLink(at: localFolderURL, withDestinationURL: externalFolderURL)

        let items = await AppScanner().scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.containerKind, .singleAppContainer)
        XCTAssertEqual(item.status, "已链接")
        XCTAssertEqual(item.path.standardizedFileURL, externalFolderURL.standardizedFileURL)
        XCTAssertEqual(item.displayURL.standardizedFileURL, nestedAppURL.standardizedFileURL)
    }

    func testExternalSuiteDoesNotCountSameNamedLocalAppLinkedElsewhereAsPartiallyLinked() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let officeSuiteURL = workspace.externalRootURL.appendingPathComponent("Microsoft Office")
        let officeWordURL = officeSuiteURL.appendingPathComponent("Word.app")
        let officeExcelURL = officeSuiteURL.appendingPathComponent("Excel.app")

        let unrelatedRootURL = workspace.rootURL.appendingPathComponent("UnrelatedExternal")
        let unrelatedWordURL = unrelatedRootURL.appendingPathComponent("Word.app")
        let localWordURL = workspace.localAppsURL.appendingPathComponent("Word.app")

        try fileManager.createDirectory(at: unrelatedRootURL, withIntermediateDirectories: true)
        try createAppBundle(at: officeWordURL, payloadSize: 1024, bundleID: "com.microsoft.word")
        try createAppBundle(at: officeExcelURL, payloadSize: 1024, bundleID: "com.microsoft.excel")
        try createAppBundle(at: unrelatedWordURL, payloadSize: 1024, bundleID: "com.microsoft.word")
        try fileManager.createSymbolicLink(at: localWordURL, withDestinationURL: unrelatedWordURL)

        let items = await AppScanner().scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.containerKind, .appSuiteFolder)
        XCTAssertEqual(item.path.standardizedFileURL, officeSuiteURL.standardizedFileURL)
        XCTAssertEqual(item.status, "未链接")
    }

    func testLocalScanMarksNewerLocalAppAsPendingMoveOut() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Newer.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("ExternalName.app")

        try createAppBundle(at: localAppURL, payloadSize: 1024, bundleID: "com.example.newer", version: "2.0")
        try createAppBundle(at: externalAppURL, payloadSize: 1024, bundleID: "com.example.newer", version: "1.0")

        let items = await AppScanner().scanLocalApps(
            at: workspace.localAppsURL,
            runningAppURLs: Set<URL>(),
            externalAppsDir: workspace.externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.name == "Newer.app" }))
        XCTAssertEqual(item.status, AppStatus.pendingMoveOut)
        XCTAssertEqual(item.version, "2.0")
    }

    func testLocalScanDoesNotMarkPendingMoveOutWhenExternalVersionIsSameHigherMissingOrInvalid() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let cases: [(name: String, localVersion: String?, externalVersion: String?)] = [
            ("Same", "2.0", "2.0"),
            ("HigherExternal", "2.0", "3.0"),
            ("MissingExternal", "2.0", nil),
            ("InvalidExternal", "2.0", "2.beta"),
            ("MissingLocal", nil, "1.0"),
            ("InvalidLocal", "2.beta", "1.0")
        ]

        for testCase in cases {
            let localAppURL = workspace.localAppsURL.appendingPathComponent("\(testCase.name).app")
            let externalAppURL = workspace.externalRootURL.appendingPathComponent("\(testCase.name).app")
            let bundleID = "com.example.\(testCase.name.lowercased())"

            try createAppBundle(at: localAppURL, payloadSize: 1024, bundleID: bundleID, version: testCase.localVersion)
            try createAppBundle(at: externalAppURL, payloadSize: 1024, bundleID: bundleID, version: testCase.externalVersion)
        }

        let items = await AppScanner().scanLocalApps(
            at: workspace.localAppsURL,
            runningAppURLs: Set<URL>(),
            externalAppsDir: workspace.externalRootURL
        )

        for testCase in cases {
            let item = try XCTUnwrap(items.first(where: { $0.name == "\(testCase.name).app" }))
            XCTAssertEqual(item.status, AppStatus.local, "\(testCase.name) should stay local")
        }
    }

    func testLocalScanDoesNotMarkPendingMoveOutForSameNameDifferentBundleID() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("SameName.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("SameName.app")

        try createAppBundle(at: localAppURL, payloadSize: 1024, bundleID: "com.example.local", version: "2.0")
        try createAppBundle(at: externalAppURL, payloadSize: 1024, bundleID: "com.example.external", version: "1.0")

        let items = await AppScanner().scanLocalApps(
            at: workspace.localAppsURL,
            runningAppURLs: Set<URL>(),
            externalAppsDir: workspace.externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.name == "SameName.app" }))
        XCTAssertEqual(item.status, AppStatus.local)
    }

    func testExternalFolderMirrorTracksDeletedChildrenWithoutTreatingLocalFolderAsMovable() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let external = workspace.externalRootURL.appendingPathComponent("Suite")
        let local = workspace.localAppsURL.appendingPathComponent("Suite")
        try createAppBundle(at: external.appendingPathComponent("One.app"), payloadSize: 16)
        try createAppBundle(at: external.appendingPathComponent("Two.app"), payloadSize: 16)
        try makeFolderMirror(at: local, pointingTo: external, children: ["One.app", "Two.app"])
        let scanner = AppScanner()
        var items = await scanner.scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)
        XCTAssertEqual(try XCTUnwrap(items.first(where: { $0.name == "Suite" })).status, AppStatus.linked)

        try fileManager.removeItem(at: local.appendingPathComponent("Two.app"))
        items = await scanner.scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)
        XCTAssertEqual(try XCTUnwrap(items.first(where: { $0.name == "Suite" })).status, AppStatus.partialLinked)
        let localItems = await scanner.scanLocalApps(at: workspace.localAppsURL, runningAppURLs: [])
        let localItem = try XCTUnwrap(localItems.first(where: { $0.name == "Suite" }))
        XCTAssertNotEqual(localItem.status, AppStatus.local)
        XCTAssertNotEqual(localItem.status, AppStatus.pendingMoveOut)

        try fileManager.removeItem(at: local.appendingPathComponent("One.app"))
        items = await scanner.scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)
        XCTAssertEqual(try XCTUnwrap(items.first(where: { $0.name == "Suite" })).status, AppStatus.unlinked)
        XCTAssertTrue(fileManager.fileExists(atPath: local.path))
    }

    func testExternalFolderMirrorNewChildIsPartialAndIndependentSameNameChildDoesNotCount() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let external = workspace.externalRootURL.appendingPathComponent("Suite")
        let local = workspace.localAppsURL.appendingPathComponent("Suite")
        try createAppBundle(at: external.appendingPathComponent("One.app"), payloadSize: 16)
        try makeFolderMirror(at: local, pointingTo: external, children: ["One.app"])
        try createAppBundle(at: external.appendingPathComponent("Two.app"), payloadSize: 16)
        let scanner = AppScanner()
        var items = await scanner.scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)
        XCTAssertEqual(try XCTUnwrap(items.first(where: { $0.name == "Suite" })).status, AppStatus.partialLinked)
        try createAppBundle(at: local.appendingPathComponent("Two.app"), payloadSize: 16, bundleID: "org.unrelated.two")
        items = await scanner.scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)
        XCTAssertEqual(try XCTUnwrap(items.first(where: { $0.name == "Suite" })).status, AppStatus.partialLinked)
    }

    func testExternalWholeSuiteSymlinkRemainsLinked() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let external = workspace.externalRootURL.appendingPathComponent("Suite")
        let local = workspace.localAppsURL.appendingPathComponent("Suite")
        try createAppBundle(at: external.appendingPathComponent("One.app"), payloadSize: 16)
        try createAppBundle(at: external.appendingPathComponent("Two.app"), payloadSize: 16)
        try fileManager.createSymbolicLink(at: local, withDestinationURL: external)
        let items = await AppScanner().scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)
        XCTAssertEqual(try XCTUnwrap(items.first(where: { $0.name == "Suite" })).status, AppStatus.linked)
    }

    func testServiceCreatedMirrorResolvesCanonicalTargetPaths() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let external = workspace.externalRootURL.appendingPathComponent("Suite")
        let local = workspace.localAppsURL.appendingPathComponent("Suite")
        try createAppBundle(at: external.appendingPathComponent("One.app"), payloadSize: 16)
        try createAppBundle(at: external.appendingPathComponent("Two.app"), payloadSize: 16)
        try AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).linkApp(
            appToLink: AppItem(name: "Suite", path: external, status: AppStatus.unlinked, isFolder: true, appCount: 2),
            destinationURL: local)
        let scanner = AppScanner()
        let items = await scanner.scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)
        XCTAssertEqual(try XCTUnwrap(items.first(where: { $0.name == "Suite" })).status, AppStatus.linked)
        try fileManager.removeItem(at: local.appendingPathComponent("One.app"))
        let afterDeletion = await scanner.scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)
        XCTAssertEqual(try XCTUnwrap(afterDeletion.first(where: { $0.name == "Suite" })).status, AppStatus.partialLinked)
    }

    private func makeFolderMirror(at local: URL, pointingTo external: URL, children: [String]) throws {
        try fileManager.createDirectory(at: local, withIntermediateDirectories: true)
        let marker: [String: Any] = ["externalPath": external.standardizedFileURL.path, "createdBy": "AppPorts", "kind": "folderMirror", "version": 1]
        try PropertyListSerialization.data(fromPropertyList: marker, format: .xml, options: 0)
            .write(to: local.appendingPathComponent(AppMigrationService.folderPortalMarkerName))
        for child in children {
            try fileManager.createSymbolicLink(at: local.appendingPathComponent(child), withDestinationURL: external.appendingPathComponent(child))
        }
    }

    private func createScannerStub(at local: URL, pointingTo target: URL, bundleID: String) throws {
        let contents = local.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        let macos = contents.appendingPathComponent("MacOS")
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": bundleID + ".appports.stub", "CFBundleExecutable": "launcher",
            "AppPortsTargetBundleIdentifier": bundleID
        ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("test launcher".utf8).write(to: macos.appendingPathComponent("launcher"))
        try target.path.write(to: resources.appendingPathComponent("real_app_path.txt"), atomically: true, encoding: .utf8)
    }

    private struct ScannerFixtureFile: Equatable {
        let identity: AppSearchExclusionService.FileIdentity
        let contents: Data?
    }

    private func scannerFixtureSnapshot(at root: URL) throws -> [String: ScannerFixtureFile] {
        let enumerator = try XCTUnwrap(fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
        let urls = [root] + enumerator.allObjects.compactMap { $0 as? URL }
        var result: [String: ScannerFixtureFile] = [:]
        for url in urls {
            let identity = try AppSearchExclusionService.FileIdentity.read(url)
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            result[url.path] = ScannerFixtureFile(identity: identity, contents: isDirectory ? nil : try Data(contentsOf: url))
        }
        return result
    }

    private func makeWorkspace() throws -> (rootURL: URL, localAppsURL: URL, externalRootURL: URL) {
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent("AppScannerTests-\(UUID().uuidString)")
        let localAppsURL = rootURL.appendingPathComponent("Applications")
        let externalRootURL = rootURL.appendingPathComponent("External")

        try fileManager.createDirectory(at: localAppsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: externalRootURL, withIntermediateDirectories: true)

        return (rootURL, localAppsURL, externalRootURL)
    }

    private func cleanupWorkspace(_ rootURL: URL) {
        try? fileManager.removeItem(at: rootURL)
    }

    private func createAppBundle(
        at appURL: URL,
        payloadSize: Int,
        bundleID: String? = nil,
        version: String? = nil
    ) throws {
        let contentsURL = appURL.appendingPathComponent("Contents")
        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")

        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let executableURL = macOSURL.appendingPathComponent(appURL.deletingPathExtension().lastPathComponent)
        try Data(repeating: 0x41, count: payloadSize).write(to: executableURL)

        let payloadURL = resourcesURL.appendingPathComponent("payload.bin")
        try Data(repeating: 0x42, count: payloadSize).write(to: payloadURL)

        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID ?? "com.example.\(appURL.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-"))"
        ]
        if let version {
            plist["CFBundleShortVersionString"] = version
        }
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }
}
