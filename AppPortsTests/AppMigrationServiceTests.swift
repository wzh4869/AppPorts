import XCTest
@testable import AppPorts

final class AppMigrationServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var originalLogEnabledValue: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLogEnabledValue = UserDefaults.standard.object(forKey: "LogEnabled")
        UserDefaults.standard.set(false, forKey: "LogEnabled")
    }

    override func tearDownWithError() throws {
        if let originalLogEnabledValue {
            UserDefaults.standard.set(originalLogEnabledValue, forKey: "LogEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "LogEnabled")
        }

        try super.tearDownWithError()
    }

    func testRegularAppRoundTripMoveDeleteRelinkAndRestore() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Foo.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Foo.app")
        try createAppBundle(at: localAppURL)

        var dockUpdates: [(source: URL, destination: URL)] = []
        let service = AppMigrationService(dockShortcutUpdater: { source, destination in
            try self.assertRealAppBundle(destination)
            dockUpdates.append((source, destination))
            return 1
        })
        let localItem = AppItem(name: "Foo.app", path: localAppURL, status: "本地")

        try await service.moveAndLink(
            appToMove: localItem,
            destinationURL: externalAppURL,
            isRunning: false,
            progressHandler: nil
        )

        try assertStubPortal(localAppURL, pointsTo: externalAppURL)

        try service.deleteLink(app: AppItem(name: "Foo.app", path: localAppURL, status: "已链接"))
        XCTAssertFalse(fileManager.fileExists(atPath: localAppURL.path))

        try service.linkApp(
            appToLink: AppItem(name: "Foo.app", path: externalAppURL, status: "未链接"),
            destinationURL: localAppURL
        )

        try assertStubPortal(localAppURL, pointsTo: externalAppURL)

        try await service.moveBack(
            app: AppItem(name: "Foo.app", path: externalAppURL, status: "已链接"),
            localDestinationURL: localAppURL,
            progressHandler: nil
        )

        try assertRealAppBundle(localAppURL)
        XCTAssertFalse(fileManager.fileExists(atPath: externalAppURL.path))
        XCTAssertEqual(dockUpdates.map(\.source), [localAppURL, localAppURL, externalAppURL])
        XCTAssertEqual(dockUpdates.map(\.destination), [externalAppURL, externalAppURL, localAppURL])
    }

    func testMoveAndLinkRollsBackWhenPortalCreationFails() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Rollback.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Rollback.app")
        try createAppBundle(at: localAppURL)

        var dockUpdateCount = 0
        let service = AppMigrationService(portalCreationOverride: { _, _ in
            throw NSError(domain: "AppPortsTests", code: 99, userInfo: [NSLocalizedDescriptionKey: "forced failure"])
        }, dockShortcutUpdater: { source, destination in
            // Failed migration must never pin the external copy; rollback may refresh
            // the identity only after a complete local application exists again.
            XCTAssertEqual(source, externalAppURL)
            XCTAssertEqual(destination, localAppURL)
            try self.assertRealAppBundle(destination)
            dockUpdateCount += 1
            return 1
        })

        do {
            try await service.moveAndLink(
                appToMove: AppItem(name: "Rollback.app", path: localAppURL, status: "本地"),
                destinationURL: externalAppURL,
                isRunning: false,
                progressHandler: nil
            )
            XCTFail("Expected portal creation failure")
        } catch {
            XCTAssertFalse(fileManager.fileExists(atPath: externalAppURL.path))
            try assertRealAppBundle(localAppURL)
        }
        XCTAssertEqual(dockUpdateCount, 1)
    }

    func testFolderMoveAndRestoreUsesFolderMirror() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localSuiteURL = workspace.localAppsURL.appendingPathComponent("Office")
        let externalSuiteURL = workspace.externalRootURL.appendingPathComponent("Office")
        try fileManager.createDirectory(at: localSuiteURL, withIntermediateDirectories: true)
        try createAppBundle(at: localSuiteURL.appendingPathComponent("Word.app"))
        try createAppBundle(at: localSuiteURL.appendingPathComponent("Excel.app"))
        // 非 app 条目：单文件 + 子目录
        try "manual".write(to: localSuiteURL.appendingPathComponent("Manual.pdf"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: localSuiteURL.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try "license".write(to: localSuiteURL.appendingPathComponent("Documents/License.txt"), atomically: true, encoding: .utf8)

        var dockUpdates: [(source: URL, destination: URL)] = []
        let service = AppMigrationService(dockShortcutUpdater: { source, destination in
            try self.assertRealAppBundle(destination.appendingPathComponent("Word.app"))
            try self.assertRealAppBundle(destination.appendingPathComponent("Excel.app"))
            dockUpdates.append((source, destination))
            return 2
        })
        let suiteItem = AppItem(
            name: "Office",
            path: localSuiteURL,
            status: "本地",
            isFolder: true,
            appCount: 2
        )

        try await service.moveAndLink(
            appToMove: suiteItem,
            destinationURL: externalSuiteURL,
            isRunning: false,
            progressHandler: nil
        )

        // 本地是真实文件夹（非 symlink），内部 app 为 Stub，非 app 为符号链接，含标记文件
        try assertFolderMirror(localSuiteURL, stubAppNames: ["Word.app", "Excel.app"], externalURL: externalSuiteURL)
        try assertSymlink(localSuiteURL.appendingPathComponent("Manual.pdf"), pointsTo: externalSuiteURL.appendingPathComponent("Manual.pdf"))
        try assertSymlink(localSuiteURL.appendingPathComponent("Documents"), pointsTo: externalSuiteURL.appendingPathComponent("Documents"))
        // 内部 app 未被展开到 /Applications 顶层
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.localAppsURL.appendingPathComponent("Word.app").path))
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.localAppsURL.appendingPathComponent("Excel.app").path))
        // 外部为真实套件副本，且不含本地标记文件
        try assertRealAppBundle(externalSuiteURL.appendingPathComponent("Word.app"))
        XCTAssertFalse(fileManager.fileExists(atPath: externalSuiteURL.appendingPathComponent(AppMigrationService.folderPortalMarkerName).path))

        try await service.moveBack(
            app: AppItem(
                name: "Office",
                path: externalSuiteURL,
                status: "已链接",
                isFolder: true,
                appCount: 2
            ),
            localDestinationURL: localSuiteURL,
            progressHandler: nil
        )

        // 还原后本地为真实套件，标记消失，外部已删除
        try assertRealAppBundle(localSuiteURL.appendingPathComponent("Word.app"))
        try assertRealAppBundle(localSuiteURL.appendingPathComponent("Excel.app"))
        XCTAssertEqual(dockUpdates.map(\.source), [localSuiteURL, externalSuiteURL])
        XCTAssertEqual(dockUpdates.map(\.destination), [externalSuiteURL, localSuiteURL])
        XCTAssertFalse(fileManager.fileExists(atPath: localSuiteURL.appendingPathComponent(AppMigrationService.folderPortalMarkerName).path))
        XCTAssertEqual(try String(contentsOf: localSuiteURL.appendingPathComponent("Manual.pdf"), encoding: .utf8), "manual")
        XCTAssertFalse(fileManager.fileExists(atPath: externalSuiteURL.path))
    }

    func testFolderMirrorDeleteLinkRemovesMirrorKeepsExternal() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localSuiteURL = workspace.localAppsURL.appendingPathComponent("Office")
        let externalSuiteURL = workspace.externalRootURL.appendingPathComponent("Office")
        try fileManager.createDirectory(at: localSuiteURL, withIntermediateDirectories: true)
        try createAppBundle(at: localSuiteURL.appendingPathComponent("Word.app"))
        try createAppBundle(at: localSuiteURL.appendingPathComponent("Excel.app"))

        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 })
        try await service.moveAndLink(
            appToMove: AppItem(name: "Office", path: localSuiteURL, status: "本地", isFolder: true, appCount: 2),
            destinationURL: externalSuiteURL,
            isRunning: false,
            progressHandler: nil
        )
        try assertFolderMirror(localSuiteURL, stubAppNames: ["Word.app", "Excel.app"], externalURL: externalSuiteURL)

        // 解链：删除本地镜像，外部真实套件保持完好
        try service.deleteLink(app: AppItem(name: "Office", path: localSuiteURL, status: "已链接", isFolder: true, appCount: 2))
        XCTAssertFalse(fileManager.fileExists(atPath: localSuiteURL.path))
        try assertRealAppBundle(externalSuiteURL.appendingPathComponent("Word.app"))
        try assertRealAppBundle(externalSuiteURL.appendingPathComponent("Excel.app"))
    }

    func testRefreshFolderMirrorSyncsAddedAndRemovedEntries() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localSuiteURL = workspace.localAppsURL.appendingPathComponent("Office")
        let externalSuiteURL = workspace.externalRootURL.appendingPathComponent("Office")
        try fileManager.createDirectory(at: localSuiteURL, withIntermediateDirectories: true)
        try createAppBundle(at: localSuiteURL.appendingPathComponent("Word.app"))
        try createAppBundle(at: localSuiteURL.appendingPathComponent("Excel.app"))

        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 })
        try await service.moveAndLink(
            appToMove: AppItem(name: "Office", path: localSuiteURL, status: "本地", isFolder: true, appCount: 2),
            destinationURL: externalSuiteURL,
            isRunning: false,
            progressHandler: nil
        )
        try assertFolderMirror(localSuiteURL, stubAppNames: ["Word.app", "Excel.app"], externalURL: externalSuiteURL)

        // 模拟外部套件被更新：新增 PowerPoint.app 与 ReadMe.txt，删除 Excel.app
        try createAppBundle(at: externalSuiteURL.appendingPathComponent("PowerPoint.app"))
        try "read me".write(to: externalSuiteURL.appendingPathComponent("ReadMe.txt"), atomically: true, encoding: .utf8)
        try fileManager.removeItem(at: externalSuiteURL.appendingPathComponent("Excel.app"))

        service.refreshFolderMirror(at: localSuiteURL, from: externalSuiteURL)

        // 新增项被镜像，删除项被清理，保留项不变，标记仍在
        try assertStubPortal(localSuiteURL.appendingPathComponent("Word.app"), pointsTo: externalSuiteURL.appendingPathComponent("Word.app"))
        try assertStubPortal(localSuiteURL.appendingPathComponent("PowerPoint.app"), pointsTo: externalSuiteURL.appendingPathComponent("PowerPoint.app"))
        try assertSymlink(localSuiteURL.appendingPathComponent("ReadMe.txt"), pointsTo: externalSuiteURL.appendingPathComponent("ReadMe.txt"))
        XCTAssertFalse(fileManager.fileExists(atPath: localSuiteURL.appendingPathComponent("Excel.app").path))
        XCTAssertTrue(fileManager.fileExists(atPath: localSuiteURL.appendingPathComponent(AppMigrationService.folderPortalMarkerName).path))
    }

    func testRefreshFolderMirrorIgnoresLegacySymlinkFolder() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        // 旧版整体符号链接文件夹（无标记文件）
        let externalSuiteURL = workspace.externalRootURL.appendingPathComponent("Office")
        try fileManager.createDirectory(at: externalSuiteURL, withIntermediateDirectories: true)
        try createAppBundle(at: externalSuiteURL.appendingPathComponent("Word.app"))
        let localSuiteURL = workspace.localAppsURL.appendingPathComponent("Office")
        try fileManager.createSymbolicLink(at: localSuiteURL, withDestinationURL: externalSuiteURL)

        // 应安全跳过：不抛错，不改动符号链接
        AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).refreshFolderMirror(at: localSuiteURL, from: externalSuiteURL)
        try assertWholeAppSymlink(localSuiteURL, pointsTo: externalSuiteURL)
    }

    func testIOSRelinkUsesStubPortal() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Phone.app")
        let localAppURL = workspace.localAppsURL.appendingPathComponent("Phone.app")
        try createAppBundle(at: externalAppURL, wrappedBundle: true)

        try AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).linkApp(
            appToLink: AppItem(name: "Phone.app", path: externalAppURL, status: "未链接"),
            destinationURL: localAppURL
        )

        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
    }

    func testDeleteLinkRejectsRealLocalAppBundle() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Safe.app")
        try createAppBundle(at: localAppURL)

        XCTAssertThrowsError(
            try AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).deleteLink(
                app: AppItem(name: "Safe.app", path: localAppURL, status: "已链接")
            )
        )
        try assertRealAppBundle(localAppURL)
    }

    func testExternalSuiteStatusPrefersFolderLevelSymlink() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let externalSuiteURL = workspace.externalRootURL.appendingPathComponent("Office")
        try fileManager.createDirectory(at: externalSuiteURL, withIntermediateDirectories: true)
        try createAppBundle(at: externalSuiteURL.appendingPathComponent("Word.app"))
        try createAppBundle(at: externalSuiteURL.appendingPathComponent("Excel.app"))

        try AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).linkApp(
            appToLink: AppItem(
                name: "Office",
                path: externalSuiteURL,
                status: "未链接",
                isFolder: true,
                appCount: 2
            ),
            destinationURL: workspace.localAppsURL.appendingPathComponent("Office")
        )

        let scanner = AppScanner()
        let scannedItems = await scanner.scanExternalApps(at: workspace.externalRootURL, localAppsDir: workspace.localAppsURL)
        let officeItem = try XCTUnwrap(scannedItems.first(where: { $0.name == "Office" }))
        XCTAssertEqual(officeItem.status, "已链接")
    }

    func testMoveAndLinkRejectsExistingExternalRealAppForOrdinaryLocalStatus() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Conflict.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Conflict.app")
        try createAppBundle(at: localAppURL, payload: "local-real")
        try createAppBundle(at: externalAppURL, payload: "external-real")

        do {
            try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
                appToMove: AppItem(name: "Conflict.app", path: localAppURL, status: AppStatus.local),
                destinationURL: externalAppURL,
                isRunning: false,
                progressHandler: nil
            )
            XCTFail("Expected existing external real app to be rejected")
        } catch {
            try assertRealAppBundle(localAppURL)
            try assertRealAppBundle(externalAppURL)
            XCTAssertEqual(try String(contentsOf: localAppURL.appendingPathComponent("Contents/Resources/payload.txt")), "local-real")
            XCTAssertEqual(try String(contentsOf: externalAppURL.appendingPathComponent("Contents/Resources/payload.txt")), "external-real")
        }
    }

    func testMoveAndLinkAllowsReplacingExternalRealAppWhenPendingMoveOut() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Replace.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Replace.app")
        try createAppBundle(at: localAppURL, payload: "new-local")
        try createAppBundle(at: externalAppURL, payload: "old-external")
        try updateReviewPlist(localAppURL, values: ["CFBundleShortVersionString": "2.0"])

        try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
            appToMove: AppItem(name: "Replace.app", path: localAppURL, status: AppStatus.pendingMoveOut),
            destinationURL: externalAppURL,
            isRunning: false,
            progressHandler: nil
        )

        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
        try assertRealAppBundle(externalAppURL)
        XCTAssertEqual(try String(contentsOf: externalAppURL.appendingPathComponent("Contents/Resources/payload.txt")), "new-local")
    }

    func testMoveAndLinkAllowsCleaningExistingAppPortsStubPortalAtExternalTarget() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("StubResidue.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("StubResidue.app")
        let staleRealAppURL = workspace.rootURL.appendingPathComponent("OldExternal/StubResidue.app")
        try createAppBundle(at: localAppURL, payload: "fresh-local")
        try createAppBundle(at: staleRealAppURL, payload: "stale-real")
        try createStubPortal(at: externalAppURL, pointingTo: staleRealAppURL)

        try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
            appToMove: AppItem(name: "StubResidue.app", path: localAppURL, status: AppStatus.local),
            destinationURL: externalAppURL,
            isRunning: false,
            progressHandler: nil
        )

        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
        try assertRealAppBundle(externalAppURL)
        XCTAssertEqual(try String(contentsOf: externalAppURL.appendingPathComponent("Contents/Resources/payload.txt")), "fresh-local")
    }

    func testMoveAndLinkAllowsCleaningExistingAppPortsDeepPortalAtExternalTarget() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("DeepResidue.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("DeepResidue.app")
        let staleRealAppURL = workspace.rootURL.appendingPathComponent("OldExternal/DeepResidue.app")
        try createAppBundle(at: localAppURL, payload: "fresh-local")
        try createAppBundle(at: staleRealAppURL, payload: "stale-real")
        try fileManager.createDirectory(at: externalAppURL, withIntermediateDirectories: false)
        try fileManager.createSymbolicLink(
            at: externalAppURL.appendingPathComponent("Contents"),
            withDestinationURL: staleRealAppURL.appendingPathComponent("Contents")
        )

        try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
            appToMove: AppItem(name: "DeepResidue.app", path: localAppURL, status: AppStatus.local),
            destinationURL: externalAppURL,
            isRunning: false,
            progressHandler: nil
        )

        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
        try assertRealAppBundle(externalAppURL)
        XCTAssertEqual(try String(contentsOf: externalAppURL.appendingPathComponent("Contents/Resources/payload.txt")), "fresh-local")
    }

    func testMoveAndLinkAllowsCleaningExistingAppPortsHybridPortalAtExternalTarget() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("HybridResidue.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("HybridResidue.app")
        let staleRealAppURL = workspace.rootURL.appendingPathComponent("OldExternal/HybridResidue.app")
        try createAppBundle(at: localAppURL, payload: "fresh-local")
        try createAppBundle(at: staleRealAppURL, payload: "stale-real")
        try fileManager.createDirectory(
            at: externalAppURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: externalAppURL.appendingPathComponent("Contents/MacOS"),
            withDestinationURL: staleRealAppURL.appendingPathComponent("Contents/MacOS")
        )

        try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
            appToMove: AppItem(name: "HybridResidue.app", path: localAppURL, status: AppStatus.local),
            destinationURL: externalAppURL,
            isRunning: false,
            progressHandler: nil
        )

        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
        try assertRealAppBundle(externalAppURL)
        XCTAssertEqual(try String(contentsOf: externalAppURL.appendingPathComponent("Contents/Resources/payload.txt")), "fresh-local")
    }

    func testFailedCopyRemovesPartialDestinationAndCanBeRetried() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Retry.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Retry.app")
        try createAppBundle(at: localAppURL, payload: "keep-original")
        let unreadableURL = localAppURL.appendingPathComponent("Contents/Resources/blocked.dat")
        try Data("retry-payload".utf8).write(to: unreadableURL)
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableURL.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableURL.path) }

        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 })
        let item = AppItem(name: "Retry.app", path: localAppURL, status: AppStatus.local)
        do {
            try await service.moveAndLink(
                appToMove: item,
                destinationURL: externalAppURL,
                isRunning: false,
                progressHandler: nil
            )
            XCTFail("An unreadable source file must fail the migration")
        } catch {
            try assertRealAppBundle(localAppURL)
            XCTAssertFalse(fileManager.fileExists(atPath: externalAppURL.path), "Partial copies must not block a retry")
            XCTAssertEqual(
                try String(contentsOf: localAppURL.appendingPathComponent("Contents/Resources/payload.txt")),
                "keep-original"
            )
        }

        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableURL.path)
        try await service.moveAndLink(
            appToMove: item,
            destinationURL: externalAppURL,
            isRunning: false,
            progressHandler: nil
        )
        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
        XCTAssertEqual(
            try Data(contentsOf: externalAppURL.appendingPathComponent("Contents/Resources/blocked.dat")),
            Data("retry-payload".utf8)
        )
    }

    func testMigrationOnlyRemovesQuarantineAndPreservesOtherExtendedAttributes() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Metadata.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Metadata.app")
        try createAppBundle(at: localAppURL)
        let resourcePath = "Contents/Resources/payload.txt"
        let resourceURL = localAppURL.appendingPathComponent(resourcePath)
        let marker = "preserved-metadata"
        let attributeName = "com.appports.tests.migration"
        let quarantine = "0081;00000000;AppPortsTests;"
        for url in [localAppURL, resourceURL] {
            XCTAssertEqual(marker.withCString { setxattr(url.path, attributeName, $0, marker.utf8.count, 0, 0) }, 0)
            XCTAssertEqual(quarantine.withCString { setxattr(url.path, "com.apple.quarantine", $0, quarantine.utf8.count, 0, 0) }, 0)
        }

        try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
            appToMove: AppItem(name: "Metadata.app", path: localAppURL, status: AppStatus.local),
            destinationURL: externalAppURL,
            isRunning: false,
            progressHandler: nil
        )

        for url in [externalAppURL, externalAppURL.appendingPathComponent(resourcePath)] {
            var buffer = [UInt8](repeating: 0, count: marker.utf8.count)
            let count = getxattr(url.path, attributeName, &buffer, buffer.count, 0, 0)
            XCTAssertEqual(count, marker.utf8.count, "Unrelated extended attributes must survive migration")
            XCTAssertEqual(String(bytes: buffer, encoding: .utf8), marker)
            XCTAssertEqual(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0), -1)
            XCTAssertEqual(errno, ENOATTR)
        }
    }

    func testSourceDeletionFailureAlwaysKeepsTheCompleteExternalCopy() async throws {
        for useFinderFallback in [false, true] {
            let workspace = try makeWorkspace()
            defer { cleanupWorkspace(workspace.rootURL) }
            let localAppURL = workspace.localAppsURL.appendingPathComponent("ReadOnly.app")
            let externalAppURL = workspace.externalRootURL.appendingPathComponent("ReadOnly.app")
            try createAppBundle(at: localAppURL, payload: "complete-copy")
            let blockedRelativePath = "Contents/Resources/blocked"
            let blockedURL = localAppURL.appendingPathComponent(blockedRelativePath)
            try fileManager.createDirectory(at: blockedURL, withIntermediateDirectories: true)
            try Data("locked-content".utf8).write(to: blockedURL.appendingPathComponent("locked.dat"))
            for index in 0..<30 {
                try Data("payload-\(index)".utf8).write(
                    to: localAppURL.appendingPathComponent("Contents/Resources/normal-\(index).dat")
                )
            }
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blockedURL.path)
            defer {
                for root in [localAppURL, externalAppURL] {
                    try? fileManager.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: root.appendingPathComponent(blockedRelativePath).path
                    )
                }
            }
            let fallback: AppMigrationService.FinderRemover? = useFinderFallback ? { _ in
                throw CocoaError(.fileWriteNoPermission)
            } : nil

            do {
                try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
                    appToMove: AppItem(name: "ReadOnly.app", path: localAppURL, status: AppStatus.local),
                    destinationURL: externalAppURL,
                    isRunning: false,
                    deleteSourceFallback: fallback,
                    progressHandler: nil
                )
                XCTFail("Deleting the read-only source subtree must fail")
            } catch {
                try assertRealAppBundle(externalAppURL)
                for index in 0..<30 {
                    XCTAssertEqual(
                        try Data(contentsOf: externalAppURL.appendingPathComponent("Contents/Resources/normal-\(index).dat")),
                        Data("payload-\(index)".utf8)
                    )
                }
                XCTAssertEqual(
                    try Data(contentsOf: externalAppURL.appendingPathComponent("\(blockedRelativePath)/locked.dat")),
                    Data("locked-content".utf8)
                )
            }
        }
    }

    func testCancelledRestoreCleansReadOnlyCopyAndRestoresTheOriginalPortal() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileCopier.removeCopy(at: workspace.rootURL) }
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Cancelled.app")
        let localAppURL = workspace.localAppsURL.appendingPathComponent("Cancelled.app")
        try createAppBundle(at: externalAppURL, payload: "keep-external-source")
        let largePayload = Data(repeating: 0xA5, count: 6 * 1024 * 1024)
        let largePayloadPath = "Contents/Resources/large.dat"
        try largePayload.write(to: externalAppURL.appendingPathComponent(largePayloadPath))
        try fileManager.createSymbolicLink(at: localAppURL, withDestinationURL: externalAppURL)

        let restoreTask = Task {
            try await AppMigrationService(dockShortcutUpdater: { _, _ in
                XCTFail("A cancelled restore must keep the external Dock target")
                return 0
            }).moveBack(
                app: AppItem(name: "Cancelled.app", path: externalAppURL, status: AppStatus.linked),
                localDestinationURL: localAppURL
            ) { progress in
                guard progress.copiedBytes > 0 else { return }
                // Reproduce a cancellation after directory permissions have become read-only,
                // without depending on filesystem enumeration order or wall-clock timing.
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: localAppURL.path)
                    withUnsafeCurrentTask { $0?.cancel() }
                } catch {
                    XCTFail("Failed to prepare the read-only cancellation: \(error)")
                }
            }
        }

        do {
            try await restoreTask.value
            XCTFail("The cancelled copy must fail the restore")
        } catch is CancellationError {
            // The original cancellation must propagate after cleanup and portal restoration.
        }

        try assertWholeAppSymlink(localAppURL, pointsTo: externalAppURL)
        try assertRealAppBundle(externalAppURL)
        XCTAssertEqual(try Data(contentsOf: externalAppURL.appendingPathComponent(largePayloadPath)), largePayload)
        XCTAssertEqual(
            try String(contentsOf: externalAppURL.appendingPathComponent("Contents/Resources/payload.txt")),
            "keep-external-source"
        )
    }

    func testDockSyncFailureDoesNotUndoCompletedMigrationOrRestore() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localAppURL = workspace.localAppsURL.appendingPathComponent("DockWriteFailure.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("DockWriteFailure.app")
        try createAppBundle(at: localAppURL, payload: "keep-complete-app")
        var attempts = 0
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        })

        try await service.moveAndLink(
            appToMove: AppItem(name: "DockWriteFailure.app", path: localAppURL, status: AppStatus.local),
            destinationURL: externalAppURL, isRunning: false, progressHandler: nil
        )
        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
        try assertRealAppBundle(externalAppURL)

        try await service.moveBack(
            app: AppItem(name: "DockWriteFailure.app", path: externalAppURL, status: AppStatus.linked),
            localDestinationURL: localAppURL, progressHandler: nil
        )
        try assertRealAppBundle(localAppURL)
        XCTAssertEqual(try String(contentsOf: localAppURL.appendingPathComponent("Contents/Resources/payload.txt")), "keep-complete-app")
        XCTAssertFalse(fileManager.fileExists(atPath: externalAppURL.path))
        XCTAssertEqual(attempts, 2)
    }

    func testRepairDockUsesExistingPortalWithoutRequiringVersionChange() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localAppURL = workspace.localAppsURL.appendingPathComponent("Existing.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Existing.app")
        try createAppBundle(at: externalAppURL)
        try AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).linkApp(
            appToLink: AppItem(name: "Existing.app", path: externalAppURL, status: AppStatus.unlinked),
            destinationURL: localAppURL
        )
        var updates = 0
        let service = AppMigrationService(dockShortcutUpdater: { source, destination in
            XCTAssertEqual(source, localAppURL)
            XCTAssertEqual(destination.resolvingSymlinksInPath(), externalAppURL.resolvingSymlinksInPath())
            updates += 1
            return 1
        })

        XCTAssertEqual(try service.repairDockShortcuts(for: AppItem(
            name: "Existing.app", path: localAppURL, status: AppStatus.linked
        )), 1)
        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
        XCTAssertEqual(updates, 1)

        try fileManager.removeItem(at: externalAppURL)
        XCTAssertThrowsError(try service.repairDockShortcuts(for: AppItem(
            name: "Existing.app", path: localAppURL, status: AppStatus.linked
        )))
        XCTAssertEqual(updates, 1, "An offline portal must not redirect Dock to a missing app")
    }

    func testRepairDockRejectsStaleLinkedStatusOnARealLocalApp() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let realAppURL = workspace.localAppsURL.appendingPathComponent("Real.app").resolvingSymlinksInPath()
        try createAppBundle(at: realAppURL)
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in
            XCTFail("A real local app is not an AppPorts portal")
            return 0
        })
        XCTAssertThrowsError(try service.repairDockShortcuts(for: AppItem(
            name: "Real.app", path: realAppURL, status: AppStatus.linked
        )))
    }

    func testRepairDockResolvesLegacyHybridComponents() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localAppURL = workspace.localAppsURL.appendingPathComponent("Legacy.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Legacy.app")
        try createAppBundle(at: externalAppURL)
        try fileManager.createDirectory(at: localAppURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: externalAppURL.appendingPathComponent("Contents/Info.plist"),
            to: localAppURL.appendingPathComponent("Contents/Info.plist")
        )
        try fileManager.createSymbolicLink(
            at: localAppURL.appendingPathComponent("Contents/MacOS"),
            withDestinationURL: externalAppURL.appendingPathComponent("Contents/MacOS")
        )
        let service = AppMigrationService(dockShortcutUpdater: { source, destination in
            XCTAssertEqual(source, localAppURL)
            XCTAssertEqual(destination.resolvingSymlinksInPath(), externalAppURL.resolvingSymlinksInPath())
            return 1
        })
        XCTAssertEqual(try service.repairDockShortcuts(for: AppItem(
            name: "Legacy.app", path: localAppURL, status: AppStatus.linked
        )), 1)
    }

    func testRepairDockFolderKeepsTheCustomLocalSourcePath() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let customAppsURL = workspace.rootURL.appendingPathComponent("My Apps 中文")
        try fileManager.createDirectory(at: customAppsURL, withIntermediateDirectories: true)
        let localSuiteURL = customAppsURL.appendingPathComponent("Office")
        let externalSuiteURL = workspace.externalRootURL.appendingPathComponent("Office")
        try createAppBundle(at: externalSuiteURL.appendingPathComponent("Word.app"))
        try AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).linkApp(
            appToLink: AppItem(name: "Office", path: externalSuiteURL, status: AppStatus.unlinked, isFolder: true, appCount: 1),
            destinationURL: localSuiteURL
        )
        let service = AppMigrationService(dockShortcutUpdater: { source, destination in
            XCTAssertEqual(source, localSuiteURL)
            XCTAssertEqual(destination.path, externalSuiteURL.path)
            return 1
        })
        XCTAssertEqual(try service.repairDockShortcuts(for: AppItem(
            name: "Office", path: localSuiteURL, status: AppStatus.linked, isFolder: true, appCount: 1
        )), 1)
    }

    func testRestoreRepairsLegacyFlattenedDockPaths() async throws {
        for containerKind in [AppContainerKind.appSuiteFolder, .singleAppContainer] {
            let workspace = try makeWorkspace()
            defer { cleanupWorkspace(workspace.rootURL) }
            let customAppsURL = workspace.rootURL.appendingPathComponent("Custom Applications")
            try fileManager.createDirectory(at: customAppsURL, withIntermediateDirectories: true)
            let localSuiteURL = customAppsURL.appendingPathComponent("Office")
            let externalSuiteURL = workspace.externalRootURL.appendingPathComponent("Office")
            let externalAppURL = externalSuiteURL.appendingPathComponent("Word.app")
            let flattenedPortalURL = customAppsURL.appendingPathComponent("Word.app")
            try createAppBundle(at: externalAppURL)
            try createStubPortal(at: flattenedPortalURL, pointingTo: externalAppURL)
            var updates: [(source: URL, destination: URL)] = []
            let service = AppMigrationService(dockShortcutUpdater: { source, destination in
                XCTAssertTrue(self.fileManager.fileExists(atPath: destination.path))
                updates.append((source, destination))
                return 1
            })

            let app = AppItem(
                name: "Office", path: externalSuiteURL, bundleURL: externalAppURL, status: AppStatus.linked,
                isFolder: containerKind == .appSuiteFolder, containerKind: containerKind, appCount: 1
            )
            let destination = service.localDestinationForRestore(
                of: app, defaultDirectory: workspace.localAppsURL, additionalDirectories: [customAppsURL]
            )
            XCTAssertEqual(destination, localSuiteURL, "Restore the complete container in its original custom directory")
            let result = try await service.moveBack(
                app: app, localDestinationURL: destination, progressHandler: nil
            )
            XCTAssertEqual(result.retiredLocalPortalURLs.map { $0.standardizedFileURL.path }, [flattenedPortalURL.standardizedFileURL.path])
            XCTAssertFalse(result.externalSourceRemains)
            var localRows = [AppItem(name: "Word.app", path: flattenedPortalURL, status: AppStatus.linked)]
            var externalRows = [app, AppItem(name: "Word.app", path: externalAppURL, status: AppStatus.linked)]
            AppListTransfer.movedBack(app, localDestination: destination,
                                      externalSourceRemains: result.externalSourceRemains,
                                      retiredLocalURLs: result.retiredLocalPortalURLs)
                .apply(localApps: &localRows, externalApps: &externalRows)
            XCTAssertEqual(localRows.map(\.path), [destination])
            XCTAssertEqual(localRows.first?.status, AppStatus.local)
            XCTAssertTrue(externalRows.isEmpty)
            XCTAssertEqual(updates.map { $0.source.path }, [externalSuiteURL.path, flattenedPortalURL.path])
            XCTAssertEqual(updates.map { $0.destination.path }, [localSuiteURL.path, localSuiteURL.appendingPathComponent("Word.app").path])
            try assertRealAppBundle(localSuiteURL.appendingPathComponent("Word.app"))
            XCTAssertFalse(fileManager.fileExists(atPath: flattenedPortalURL.path))
        }
    }

    func testRestoreRefusesFolderPortalForAnotherExternalSuite() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localSuiteURL = workspace.localAppsURL.appendingPathComponent("Office")
        let requestedSuiteURL = workspace.externalRootURL.appendingPathComponent("Office")
        let existingSuiteURL = workspace.externalRootURL.appendingPathComponent("Another Office")
        try createAppBundle(at: requestedSuiteURL.appendingPathComponent("Word.app"), payload: "requested")
        try createAppBundle(at: existingSuiteURL.appendingPathComponent("Word.app"), payload: "existing")
        try AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).linkApp(
            appToLink: AppItem(name: "Office", path: existingSuiteURL, status: AppStatus.unlinked, isFolder: true, appCount: 1),
            destinationURL: localSuiteURL
        )
        let markerURL = localSuiteURL.appendingPathComponent(AppMigrationService.folderPortalMarkerName)
        let originalMarker = try Data(contentsOf: markerURL)
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in
            XCTFail("A conflicting suite must not update any Dock shortcut")
            return 0
        })
        do {
            try await service.moveBack(
                app: AppItem(name: "Office", path: requestedSuiteURL, status: AppStatus.linked, isFolder: true, appCount: 1),
                localDestinationURL: localSuiteURL, progressHandler: nil
            )
            XCTFail("A folder marker for another external suite is a conflict")
        } catch {
            XCTAssertEqual(try Data(contentsOf: markerURL), originalMarker)
            try assertStubPortal(localSuiteURL.appendingPathComponent("Word.app"), pointsTo: existingSuiteURL.appendingPathComponent("Word.app"))
            try assertRealAppBundle(requestedSuiteURL.appendingPathComponent("Word.app"))
            try assertRealAppBundle(existingSuiteURL.appendingPathComponent("Word.app"))
        }
    }

    func testRestoreUpdatesDockEvenWhenExternalCleanupFails() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let localAppURL = workspace.localAppsURL.appendingPathComponent("Cleanup.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Cleanup.app")
        try createAppBundle(at: externalAppURL)
        try createStubPortal(at: localAppURL, pointingTo: externalAppURL)
        var updates = 0
        let service = AppMigrationService(
            fileManager: CleanupFailingFileManager(protectedURL: externalAppURL),
            dockShortcutUpdater: { source, destination in
                XCTAssertEqual(source, externalAppURL)
                XCTAssertEqual(destination, localAppURL)
                try self.assertRealAppBundle(destination)
                updates += 1
                return 1
            }
        )

        let result = try await service.moveBack(
            app: AppItem(name: "Cleanup.app", path: externalAppURL, status: AppStatus.linked),
            localDestinationURL: localAppURL, progressHandler: nil
        )
        try assertRealAppBundle(localAppURL)
        try assertRealAppBundle(externalAppURL)
        XCTAssertEqual(updates, 1)
        XCTAssertTrue(result.externalSourceRemains)
        XCTAssertTrue(result.retiredLocalPortalURLs.isEmpty)
    }

    private final class CleanupFailingFileManager: FileManager {
        let protectedURL: URL

        init(protectedURL: URL) {
            self.protectedURL = protectedURL
            super.init()
        }

        override func removeItem(at URL: URL) throws {
            if URL == protectedURL { throw CocoaError(.fileWriteNoPermission) }
            try super.removeItem(at: URL)
        }
    }

    func testAppleScriptEscapingHandlesQuotesBackslashesSpacesAndUnicode() {
        let path = "/tmp/AppPorts it's \"quoted\"/中文/Slash\\Name.app"
        let literal = AppMigrationService.appleScriptStringLiteral(path)

        XCTAssertTrue(literal.hasPrefix("\""))
        XCTAssertTrue(literal.hasSuffix("\""))
        XCTAssertTrue(literal.contains("\\\"quoted\\\""))
        XCTAssertTrue(literal.contains("Slash\\\\Name.app"))
        XCTAssertTrue(literal.contains("it's"))

        let script = CodeSigner.ownershipRepairAppleScript(username: "user'name", appPath: path)
        XCTAssertTrue(script.contains("set targetPath to \(literal)"))
        XCTAssertTrue(script.contains("set userName to \"user'name\""))
        XCTAssertTrue(script.contains("quoted form of userName"))
        XCTAssertTrue(script.contains("quoted form of targetPath"))
        XCTAssertFalse(script.contains("'\\(path)'"))
    }

    // MARK: - 还原前把「本地入口记录」换成外部本体

    /// 「修复步骤」等入口给到的是本地那一条记录（path 指向 stub / 符号链接），
    /// 直接拿去还原会变成「入口还原到入口自己」，入口检查认不出，于是报
    /// 「本地已存在同名真实文件，无法覆盖」。这里验证能解析出外部本体记录。
    func testExternalCounterpartResolvesStubPortalToExternalRecord() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Mole.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Mole.app")
        try createAppBundle(at: externalAppURL)

        let service = AppMigrationService()
        try service.linkApp(
            appToLink: AppItem(name: "Mole.app", path: externalAppURL, status: AppStatus.unlinked),
            destinationURL: localAppURL
        )
        try assertStubPortal(localAppURL, pointsTo: externalAppURL)

        let localRecord = AppItem(name: "Mole.app", path: localAppURL, status: AppStatus.linked)
        let externalRecord = AppItem(name: "Mole.app", path: externalAppURL, status: AppStatus.linked)

        let resolved = try XCTUnwrap(service.externalCounterpart(of: localRecord, in: [externalRecord]))
        XCTAssertEqual(resolved.path.standardizedFileURL, externalAppURL.standardizedFileURL)
    }

    func testExternalCounterpartIgnoresRecordsThatAreNotLocalPortals() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localRealURL = workspace.localAppsURL.appendingPathComponent("Real.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Mole.app")
        try createAppBundle(at: externalAppURL)

        let service = AppMigrationService()
        let externalRecord = AppItem(name: "Mole.app", path: externalAppURL, status: AppStatus.linked)

        // 已经是外部本体：不该被改写
        XCTAssertNil(service.externalCounterpart(of: externalRecord, in: [externalRecord]))

        // 本地实体（非入口）：不该被解析到外部
        try createAppBundle(at: localRealURL)
        let localRealRecord = AppItem(name: "Real.app", path: localRealURL, status: AppStatus.local)
        XCTAssertNil(service.externalCounterpart(of: localRealRecord, in: [externalRecord]))

        // 确实是入口，但外部列表里没有对应本体（例如还没扫到）：不猜
        let localLinkURL = workspace.localAppsURL.appendingPathComponent("Link.app")
        try fileManager.createSymbolicLink(at: localLinkURL, withDestinationURL: externalAppURL)
        let linkedRecord = AppItem(name: "Link.app", path: localLinkURL, status: AppStatus.linked)
        XCTAssertNil(service.externalCounterpart(of: linkedRecord, in: []))

        // 文件夹镜像走 folder operation，不在这里处理
        let folderRecord = AppItem(name: "Office", path: localLinkURL, status: AppStatus.linked, isFolder: true)
        XCTAssertNil(service.externalCounterpart(of: folderRecord, in: [externalRecord]))
    }

    /// 回归：拿到本地入口记录时，还原目标会被算成入口自己，moveBack 于是报
    /// 「本地已存在同名真实文件，无法覆盖」。换成外部本体记录后必须能正常还原。
    func testMoveBackAfterResolvingLocalPortalRecordSucceeds() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Mole.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Mole.app")
        try createAppBundle(at: externalAppURL)

        let service = AppMigrationService()
        try service.linkApp(
            appToLink: AppItem(name: "Mole.app", path: externalAppURL, status: AppStatus.unlinked),
            destinationURL: localAppURL
        )
        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
        let localRecord = AppItem(name: "Mole.app", path: localAppURL, status: AppStatus.linked)
        let externalRecord = AppItem(name: "Mole.app", path: externalAppURL, status: AppStatus.linked)

        // 记录根因：传本地入口记录时，还原目标 == 入口自己
        XCTAssertEqual(
            service.localDestinationForRestore(of: localRecord, defaultDirectory: workspace.localAppsURL).standardizedFileURL,
            localAppURL.standardizedFileURL
        )

        // 修复后的路径：先解析成外部本体，再还原
        let resolved = try XCTUnwrap(service.externalCounterpart(of: localRecord, in: [externalRecord]))
        let destination = service.localDestinationForRestore(of: resolved, defaultDirectory: workspace.localAppsURL)
        XCTAssertEqual(destination.standardizedFileURL, localAppURL.standardizedFileURL)

        try await service.moveBack(app: resolved, localDestinationURL: destination, progressHandler: nil)
        try assertRealAppBundle(localAppURL)
        XCTAssertFalse(fileManager.fileExists(atPath: externalAppURL.path))
    }

    func testPendingMoveOutRejectsDifferentDestinationIdentity() async throws {
        let w = try makeWorkspace()
        defer { cleanupWorkspace(w.rootURL) }
        let local = w.localAppsURL.appendingPathComponent("Foo.app")
        let target = w.externalRootURL.appendingPathComponent("Foo.app")
        try createAppBundle(at: local, payload: "new-local")
        try createAppBundle(at: target, payload: "unrelated-original")
        try updateReviewPlist(target, values: ["CFBundleIdentifier": "com.other.app"])
        do {
            try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
                appToMove: AppItem(name: "Foo.app", path: local, status: AppStatus.pendingMoveOut),
                destinationURL: target, isRunning: false, progressHandler: nil)
            XCTFail("A display status must not authorize replacing a different application")
        } catch {}
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Contents/Resources/payload.txt")), "unrelated-original")
    }

    func testRefreshNeverWritesThroughLegacyPortalOrUsesDifferentTarget() throws {
        let w = try makeWorkspace()
        defer { cleanupWorkspace(w.rootURL) }
        let real = w.externalRootURL.appendingPathComponent("Foo.app")
        let other = w.rootURL.appendingPathComponent("Other/Foo.app")
        let local = w.localAppsURL.appendingPathComponent("Foo.app")
        try createAppBundle(at: real)
        try createAppBundle(at: other)
        try updateReviewPlist(other, values: ["CFBundleShortVersionString": "2.0"])
        let original = try Data(contentsOf: real.appendingPathComponent("Contents/Info.plist"))
        try fileManager.createSymbolicLink(at: local, withDestinationURL: real)
        AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).refreshStubPortal(at: local, from: other)
        XCTAssertEqual(try Data(contentsOf: real.appendingPathComponent("Contents/Info.plist")), original)
    }

    func testFolderRefreshPreservesLocalRealFilesAndReplacementApps() throws {
        let w = try makeWorkspace()
        defer { cleanupWorkspace(w.rootURL) }
        let local = w.localAppsURL.appendingPathComponent("Suite")
        let external = w.externalRootURL.appendingPathComponent("Suite")
        try createAppBundle(at: local.appendingPathComponent("Foo.app"), payload: "local-official-update")
        try createAppBundle(at: external.appendingPathComponent("Foo.app"))
        let marker: [String: Any] = ["externalPath": external.path, "createdBy": "AppPorts", "kind": "folderMirror", "version": 1]
        try PropertyListSerialization.data(fromPropertyList: marker, format: .xml, options: 0)
            .write(to: local.appendingPathComponent(AppMigrationService.folderPortalMarkerName))
        let note = local.appendingPathComponent("my-notes.txt")
        try Data("keep me".utf8).write(to: note)
        AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).refreshFolderMirror(at: local, from: external)
        XCTAssertTrue(fileManager.fileExists(atPath: note.path))
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("Foo.app/Contents/Resources/payload.txt")), "local-official-update")
    }

    func testRestoreRejectsRunningAppBeforeChangingEitherCopy() async throws {
        let w = try makeWorkspace()
        defer { cleanupWorkspace(w.rootURL) }
        let external = w.externalRootURL.appendingPathComponent("Live.app")
        let local = w.localAppsURL.appendingPathComponent("Live.app")
        try createAppBundle(at: external, payload: "live-app")
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 },
            runningApplications: { [.init(bundleURL: external, bundleIdentifier: nil)] })
        do {
            _ = try await service.moveBack(app: AppItem(name: "Live.app", path: external, status: "外部"),
                                          localDestinationURL: local, progressHandler: nil)
            XCTFail("Running source must be rejected")
        } catch AppMoverError.appIsRunning {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("Contents/Resources/payload.txt")), "live-app")
        XCTAssertFalse(fileManager.fileExists(atPath: local.path))
    }

    func testRestoreRetainsSourceWhenAppStartsDuringCopy() async throws {
        let w = try makeWorkspace()
        defer { cleanupWorkspace(w.rootURL) }
        let external = w.externalRootURL.appendingPathComponent("Live.app")
        let local = w.localAppsURL.appendingPathComponent("Live.app")
        try createAppBundle(at: external, payload: "live-app")
        var calls = 0
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 }, runningApplications: {
            calls += 1
            return calls > 1 ? [.init(bundleURL: external, bundleIdentifier: nil)] : []
        })
        do {
            _ = try await service.moveBack(app: AppItem(name: "Live.app", path: external, status: "外部"),
                                          localDestinationURL: local, progressHandler: nil)
            XCTFail("Late start must preserve the source")
        } catch AppMoverError.appIsRunning {} catch { XCTFail("Unexpected error: \(error)") }
        for app in [external, local] {
            XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("Contents/Resources/payload.txt")), "live-app")
        }
    }

    private func updateReviewPlist(_ app: URL, values: [String: String]) throws {
        let url = app.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        for (key, value) in values { plist[key] = value }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func makeWorkspace() throws -> (rootURL: URL, localAppsURL: URL, externalRootURL: URL) {
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent("AppPortsTests-\(UUID().uuidString)")
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
        wrappedBundle: Bool = false,
        payload: String = "resource"
    ) throws {
        let contentsURL = appURL.appendingPathComponent("Contents")
        let macOSURL = appURL.appendingPathComponent("Contents/MacOS")
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources")
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let executableName = appURL.deletingPathExtension().lastPathComponent
        let executableURL = macOSURL.appendingPathComponent(executableName)
        try "echo test".write(to: executableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try payload.write(to: resourcesURL.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)

        let plist: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": "com.appports.tests.\(executableName.lowercased())",
            "CFBundleName": executableName,
            "CFBundleDisplayName": executableName,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try "APPL????".write(to: contentsURL.appendingPathComponent("PkgInfo"), atomically: true, encoding: .utf8)

        if wrappedBundle {
            try fileManager.createDirectory(at: appURL.appendingPathComponent("WrappedBundle"), withIntermediateDirectories: true)
        }
    }

    private func createStubPortal(at localURL: URL, pointingTo externalURL: URL) throws {
        let macOSURL = localURL.appendingPathComponent("Contents/MacOS")
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        REAL_APP='\(externalURL.path)'
        open "$REAL_APP"
        """
        try script.write(to: macOSURL.appendingPathComponent("launcher"), atomically: true, encoding: .utf8)
    }

    private func assertDeepPortal(_ localURL: URL, pointsTo externalURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let localValues = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        XCTAssertEqual(localValues.isDirectory, true, file: file, line: line)
        XCTAssertNotEqual(localValues.isSymbolicLink, true, file: file, line: line)

        let localContentsURL = localURL.appendingPathComponent("Contents")
        let contentsValues = try localContentsURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(contentsValues.isSymbolicLink, true, file: file, line: line)

        let destination = try fileManager.destinationOfSymbolicLink(atPath: localContentsURL.path)
        let resolvedDestination = URL(fileURLWithPath: destination, relativeTo: localContentsURL.deletingLastPathComponent()).standardizedFileURL
        XCTAssertEqual(
            resolvedDestination,
            externalURL.appendingPathComponent("Contents").standardizedFileURL,
            file: file,
            line: line
        )
    }

    private func assertStubPortal(_ localURL: URL, pointsTo externalURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let localValues = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        XCTAssertEqual(localValues.isDirectory, true, "stub portal should be a directory", file: file, line: line)
        XCTAssertNotEqual(localValues.isSymbolicLink, true, "stub portal should not be a symlink", file: file, line: line)

        let launcherURL = localURL.appendingPathComponent("Contents/MacOS/launcher")
        XCTAssertTrue(fileManager.fileExists(atPath: launcherURL.path), "launcher script should exist", file: file, line: line)

        // 解析符号链接后比较，规避测试临时目录位于 /var -> /private/var 软链导致的路径差异
        let expectedResolved = externalURL.resolvingSymlinksInPath().path
        let pathFileURL = localURL.appendingPathComponent("Contents/Resources/real_app_path.txt")
        if fileManager.fileExists(atPath: pathFileURL.path) {
            let path = try String(contentsOf: pathFileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            XCTAssertEqual(resolved, expectedResolved, "launcher path file should reference external app", file: file, line: line)
        } else {
            let script = try String(contentsOf: launcherURL, encoding: .utf8)
            XCTAssertTrue(
                script.contains(externalURL.path) || script.contains(expectedResolved),
                "launcher should reference external app",
                file: file,
                line: line
            )
        }
    }

    private func assertWholeAppSymlink(_ localURL: URL, pointsTo externalURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: localURL.path)
        let resolvedDestination = URL(fileURLWithPath: destination, relativeTo: localURL.deletingLastPathComponent()).standardizedFileURL
        XCTAssertEqual(resolvedDestination, externalURL.standardizedFileURL, file: file, line: line)
    }

    private func assertSymlink(_ localURL: URL, pointsTo target: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: localURL.path)
        let resolvedDestination = URL(fileURLWithPath: destination, relativeTo: localURL.deletingLastPathComponent()).standardizedFileURL
        XCTAssertEqual(resolvedDestination, target.standardizedFileURL, file: file, line: line)
    }

    private func assertFolderMirror(
        _ localURL: URL,
        stubAppNames: [String],
        externalURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        XCTAssertEqual(values.isDirectory, true, "mirror should be a real directory", file: file, line: line)
        XCTAssertNotEqual(values.isSymbolicLink, true, "mirror should not be a symlink", file: file, line: line)

        let markerURL = localURL.appendingPathComponent(AppMigrationService.folderPortalMarkerName)
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL.path), "mirror marker should exist", file: file, line: line)
        XCTAssertEqual(
            AppMigrationService.folderMirrorExternalURL(at: localURL),
            externalURL.standardizedFileURL,
            "marker should record external folder path",
            file: file,
            line: line
        )

        for name in stubAppNames {
            try assertStubPortal(
                localURL.appendingPathComponent(name),
                pointsTo: externalURL.appendingPathComponent(name),
                file: file,
                line: line
            )
        }
    }

    private func assertRealAppBundle(_ appURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let appValues = try appURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        XCTAssertEqual(appValues.isDirectory, true, file: file, line: line)
        XCTAssertNotEqual(appValues.isSymbolicLink, true, file: file, line: line)

        let contentsURL = appURL.appendingPathComponent("Contents")
        let contentsValues = try contentsURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        XCTAssertEqual(contentsValues.isDirectory, true, file: file, line: line)
        XCTAssertNotEqual(contentsValues.isSymbolicLink, true, file: file, line: line)
    }
}
