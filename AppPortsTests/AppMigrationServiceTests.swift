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

        let service = AppMigrationService()
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
    }

    func testMoveAndLinkRollsBackWhenPortalCreationFails() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localAppURL = workspace.localAppsURL.appendingPathComponent("Rollback.app")
        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Rollback.app")
        try createAppBundle(at: localAppURL)

        let service = AppMigrationService(portalCreationOverride: { _, _ in
            throw NSError(domain: "AppPortsTests", code: 99, userInfo: [NSLocalizedDescriptionKey: "forced failure"])
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

        let service = AppMigrationService()
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

        let service = AppMigrationService()
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

        let service = AppMigrationService()
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
        AppMigrationService().refreshFolderMirror(at: localSuiteURL, from: externalSuiteURL)
        try assertWholeAppSymlink(localSuiteURL, pointsTo: externalSuiteURL)
    }

    func testIOSRelinkUsesStubPortal() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let externalAppURL = workspace.externalRootURL.appendingPathComponent("Phone.app")
        let localAppURL = workspace.localAppsURL.appendingPathComponent("Phone.app")
        try createAppBundle(at: externalAppURL, wrappedBundle: true)

        try AppMigrationService().linkApp(
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
            try AppMigrationService().deleteLink(
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

        try AppMigrationService().linkApp(
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
            try await AppMigrationService().moveAndLink(
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

        try await AppMigrationService().moveAndLink(
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

        try await AppMigrationService().moveAndLink(
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

        try await AppMigrationService().moveAndLink(
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

        try await AppMigrationService().moveAndLink(
            appToMove: AppItem(name: "HybridResidue.app", path: localAppURL, status: AppStatus.local),
            destinationURL: externalAppURL,
            isRunning: false,
            progressHandler: nil
        )

        try assertStubPortal(localAppURL, pointsTo: externalAppURL)
        try assertRealAppBundle(externalAppURL)
        XCTAssertEqual(try String(contentsOf: externalAppURL.appendingPathComponent("Contents/Resources/payload.txt")), "fresh-local")
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
