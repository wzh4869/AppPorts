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

    private func createAppBundle(at appURL: URL, payloadSize: Int, bundleID: String? = nil) throws {
        let contentsURL = appURL.appendingPathComponent("Contents")
        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")

        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let executableURL = macOSURL.appendingPathComponent(appURL.deletingPathExtension().lastPathComponent)
        try Data(repeating: 0x41, count: payloadSize).write(to: executableURL)

        let payloadURL = resourcesURL.appendingPathComponent("payload.bin")
        try Data(repeating: 0x42, count: payloadSize).write(to: payloadURL)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID ?? "com.example.\(appURL.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-"))"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }
}
