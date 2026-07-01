import XCTest
@testable import AppPorts

final class CustomDirScannerTests: XCTestCase {
    private let fileManager = FileManager.default

    func testConfigUsesExternalParentAndLocalFolderNameForDestination() {
        let localURL = URL(fileURLWithPath: "/Users/ping/develop")
        let externalBaseURL = URL(fileURLWithPath: "/Volumes/ExternalSSD/work")
        let config = CustomDirConfig(localPath: localURL.path, externalBasePath: externalBaseURL.path)

        XCTAssertEqual(
            config.externalDestinationURL,
            externalBaseURL.appendingPathComponent("develop").standardizedFileURL
        )
    }

    func testMigrationPairForNewConfigUsesLocalSourceAndExternalDestination() {
        let localURL = URL(fileURLWithPath: "/Users/ping/develop")
        let externalBaseURL = URL(fileURLWithPath: "/Volumes/ExternalSSD/work")
        let config = CustomDirConfig(localPath: localURL.path, externalBasePath: externalBaseURL.path)
        let pair = CustomDirPair.pendingMigration(for: config)

        XCTAssertEqual(pair.config, config)
        XCTAssertEqual(pair.local.kind, .local)
        XCTAssertEqual(pair.local.url, localURL.standardizedFileURL)
        XCTAssertEqual(pair.local.status, CustomDirStatus.local)
        XCTAssertTrue(pair.local.dataDirItem.isMigratable)
        XCTAssertEqual(pair.external.kind, .external)
        XCTAssertEqual(pair.external.url, externalBaseURL.appendingPathComponent("develop").standardizedFileURL)
        XCTAssertEqual(pair.external.status, CustomDirStatus.missing)
    }

    func testScannerReportsLocalDirectoryAndMissingExternalDestination() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localURL = workspace.homeURL.appendingPathComponent("develop")
        try createDirectoryWithPayload(at: localURL)

        let config = CustomDirConfig(localPath: localURL.path, externalBasePath: workspace.externalBaseURL.path)
        let scanner = CustomDirScanner(fileManager: fileManager)
        let result = await scanner.scan(configs: [config])

        let pair = try XCTUnwrap(result.first)
        XCTAssertEqual(pair.local.status, CustomDirStatus.local)
        XCTAssertEqual(pair.external.status, CustomDirStatus.missing)
        XCTAssertEqual(pair.external.url, workspace.externalBaseURL.appendingPathComponent("develop").standardizedFileURL)
    }

    func testScannerReportsLinkedDirectoryAndExternalLinkedDestination() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localURL = workspace.homeURL.appendingPathComponent("develop")
        let externalURL = workspace.externalBaseURL.appendingPathComponent("develop")
        try createDirectoryWithPayload(at: externalURL)
        try fileManager.createSymbolicLink(at: localURL, withDestinationURL: externalURL)

        let config = CustomDirConfig(localPath: localURL.path, externalBasePath: workspace.externalBaseURL.path)
        let scanner = CustomDirScanner(fileManager: fileManager)
        let result = await scanner.scan(configs: [config])

        let pair = try XCTUnwrap(result.first)
        XCTAssertEqual(pair.local.status, CustomDirStatus.linked)
        XCTAssertEqual(pair.local.linkedDestination, externalURL.standardizedFileURL)
        XCTAssertEqual(pair.external.status, CustomDirStatus.linked)
    }

    func testScannerReportsExternalPendingRelinkWhenLocalPathIsMissing() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localURL = workspace.homeURL.appendingPathComponent("develop")
        let externalURL = workspace.externalBaseURL.appendingPathComponent("develop")
        try createDirectoryWithPayload(at: externalURL)

        let config = CustomDirConfig(localPath: localURL.path, externalBasePath: workspace.externalBaseURL.path)
        let scanner = CustomDirScanner(fileManager: fileManager)
        let result = await scanner.scan(configs: [config])

        let pair = try XCTUnwrap(result.first)
        XCTAssertEqual(pair.local.status, CustomDirStatus.missing)
        XCTAssertEqual(pair.external.status, CustomDirStatus.pendingRelink)
    }

    func testValidatorRejectsLocalDirectoryOutsideCurrentUserHome() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let outsideHomeURL = workspace.rootURL.appendingPathComponent("Outside/develop")
        try fileManager.createDirectory(at: outsideHomeURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try CustomDirValidator.validateLocalDirectory(
                outsideHomeURL,
                existingConfigs: [],
                homeURL: workspace.homeURL,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(error as? CustomDirValidationError, .localOutsideHome)
        }
    }

    func testValidatorRejectsCurrentUserHomeItself() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        XCTAssertThrowsError(
            try CustomDirValidator.validateLocalDirectory(
                workspace.homeURL,
                existingConfigs: [],
                homeURL: workspace.homeURL,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(error as? CustomDirValidationError, .localIsHome)
        }
    }

    func testValidatorRejectsLocalSymlink() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let realURL = workspace.homeURL.appendingPathComponent("real")
        let linkURL = workspace.homeURL.appendingPathComponent("linked")
        try createDirectoryWithPayload(at: realURL)
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        XCTAssertThrowsError(
            try CustomDirValidator.validateLocalDirectory(
                linkURL,
                existingConfigs: [],
                homeURL: workspace.homeURL,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(error as? CustomDirValidationError, .localIsSymlink)
        }
    }

    func testValidatorRejectsLocalDirectoryInsideSymlinkedParent() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let realParentURL = workspace.rootURL.appendingPathComponent("RealParent")
        let realChildURL = realParentURL.appendingPathComponent("project")
        let linkedParentURL = workspace.homeURL.appendingPathComponent("linked")
        let linkedChildURL = linkedParentURL.appendingPathComponent("project")
        try createDirectoryWithPayload(at: realChildURL)
        try fileManager.createSymbolicLink(at: linkedParentURL, withDestinationURL: realParentURL)

        XCTAssertThrowsError(
            try CustomDirValidator.validateLocalDirectory(
                linkedChildURL,
                existingConfigs: [],
                homeURL: workspace.homeURL,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(error as? CustomDirValidationError, .localIsSymlink)
        }
    }

    func testLocalOpenPanelGuardRejectsSymlinkDirectoryBeforeNavigation() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let realURL = workspace.rootURL.appendingPathComponent("RealPanelTarget")
        let linkURL = workspace.homeURL.appendingPathComponent("panel-linked")
        try createDirectoryWithPayload(at: realURL)
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        let guardrail = CustomDirLocalOpenPanelGuard(
            homeURL: workspace.homeURL,
            existingConfigs: [],
            fileManager: fileManager
        )

        XCTAssertFalse(guardrail.shouldEnable(linkURL))
        XCTAssertEqual(guardrail.validationError(for: linkURL) as? CustomDirValidationError, .localIsSymlink)
    }

    func testValidatorRejectsNestedManagedLocalDirectories() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let parentURL = workspace.homeURL.appendingPathComponent("aaa")
        let childURL = parentURL.appendingPathComponent("bbb")
        try fileManager.createDirectory(at: childURL, withIntermediateDirectories: true)

        let childConfig = CustomDirConfig(localPath: childURL.path, externalBasePath: workspace.externalBaseURL.path)
        XCTAssertThrowsError(
            try CustomDirValidator.validateLocalDirectory(
                parentURL,
                existingConfigs: [childConfig],
                homeURL: workspace.homeURL,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(error as? CustomDirValidationError, .localOverlapsManagedDirectory)
        }

        let parentConfig = CustomDirConfig(localPath: parentURL.path, externalBasePath: workspace.externalBaseURL.path)
        XCTAssertThrowsError(
            try CustomDirValidator.validateLocalDirectory(
                childURL,
                existingConfigs: [parentConfig],
                homeURL: workspace.homeURL,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(error as? CustomDirValidationError, .localOverlapsManagedDirectory)
        }
    }

    func testValidatorRejectsExternalBaseInsideCurrentUserHome() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localURL = workspace.homeURL.appendingPathComponent("develop")
        let externalBaseURL = workspace.homeURL.appendingPathComponent("ExternalInHome")
        try createDirectoryWithPayload(at: localURL)
        try fileManager.createDirectory(at: externalBaseURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try CustomDirValidator.validate(
                localURL: localURL,
                externalBaseURL: externalBaseURL,
                existingConfigs: [],
                homeURL: workspace.homeURL,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(error as? CustomDirValidationError, .externalInsideHome)
        }
    }

    func testValidationErrorsHaveSpecificUserFacingMessages() {
        LanguageManager.shared.language = "zh-Hans"
        defer { LanguageManager.shared.language = "system" }

        XCTAssertEqual(
            CustomDirValidationError.localOutsideHome.errorDescription,
            "本地目录必须位于当前用户目录下"
        )
        XCTAssertEqual(
            CustomDirValidationError.localIsHome.errorDescription,
            "不能迁移整个用户目录"
        )
        XCTAssertEqual(
            CustomDirValidationError.localIsSymlink.errorDescription,
            "不能迁移软链接目录，请选择真实文件夹"
        )
        XCTAssertEqual(
            CustomDirValidationError.localOverlapsManagedDirectory.errorDescription,
            "该目录与已管理目录存在包含关系"
        )
        XCTAssertEqual(
            CustomDirValidationError.externalInsideHome.errorDescription,
            "外部目标不能位于当前用户目录内"
        )
        XCTAssertEqual(
            CustomDirValidationError.externalOverlapsManagedDirectory.errorDescription,
            "外部目标与已管理目录存在包含关系"
        )
    }

    private func makeWorkspace() throws -> (rootURL: URL, homeURL: URL, externalBaseURL: URL) {
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent("CustomDirScannerTests-\(UUID().uuidString)")
        let homeURL = rootURL.appendingPathComponent("Home")
        let externalBaseURL = rootURL.appendingPathComponent("External")

        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: externalBaseURL, withIntermediateDirectories: true)

        return (rootURL, homeURL, externalBaseURL)
    }

    private func cleanupWorkspace(_ rootURL: URL) {
        try? fileManager.removeItem(at: rootURL)
    }

    private func createDirectoryWithPayload(at directoryURL: URL) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "payload".write(
            to: directoryURL.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
