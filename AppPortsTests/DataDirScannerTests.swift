import XCTest
@testable import AppPorts

final class DataDirScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var originalLogEnabledValue: Any?
    private var originalLogPath: String?
    private let issue49RelativePaths = [".gradle", ".android", ".pub-cache"]

    private enum Issue49LocalState: CaseIterable {
        case missing
        case directory
        case regularFile
        case unmanagedSymlink
        case danglingSymlink
    }

    private enum Issue49ExternalState: CaseIterable {
        case missing
        case directory
        case regularFile
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLogEnabledValue = UserDefaults.standard.object(forKey: "LogEnabled")
        originalLogPath = UserDefaults.standard.string(forKey: "LogFilePath")
        UserDefaults.standard.set(false, forKey: "LogEnabled")
    }

    override func tearDownWithError() throws {
        if let originalLogEnabledValue {
            UserDefaults.standard.set(originalLogEnabledValue, forKey: "LogEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "LogEnabled")
        }

        if let originalLogPath {
            UserDefaults.standard.set(originalLogPath, forKey: "LogFilePath")
        } else {
            UserDefaults.standard.removeObject(forKey: "LogFilePath")
        }

        try super.tearDownWithError()
    }

    func testIssue49KnownToolDirectoriesAreReportedAsLocalAndMigratable() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let expectedRelativePaths = [".gradle", ".android", ".pub-cache"]
        for relativePath in expectedRelativePaths {
            try createDirectoryWithPayload(at: workspace.homeURL.appendingPathComponent(relativePath))
        }

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanKnownDotFolders()
        let itemsByRelativePath = Dictionary(
            uniqueKeysWithValues: items.map {
                ($0.path.path.replacingOccurrences(of: workspace.homeURL.path + "/", with: ""), $0)
            }
        )

        for relativePath in expectedRelativePaths {
            let item = try XCTUnwrap(itemsByRelativePath[relativePath])
            XCTAssertEqual(item.status, "本地")
            XCTAssertTrue(item.isMigratable)
            XCTAssertEqual(item.type, .dotFolder)
            XCTAssertNil(item.linkedDestination)
        }
    }

    func testIssue49ExternalToolDirectoriesWithoutLocalPathsAreReportedAsPendingRelink() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let expectedRelativePaths = [".gradle", ".android", ".pub-cache"]
        for relativePath in expectedRelativePaths {
            let externalURL = workspace.externalRootURL
                .appendingPathComponent(DataDirType.dotFolder.rawValue)
                .appendingPathComponent(relativePath)
            try createDirectoryWithPayload(at: externalURL)
        }

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanKnownDotFolders(
            externalRootURL: workspace.externalRootURL
        )
        let itemsByRelativePath = Dictionary(
            uniqueKeysWithValues: items.map {
                ($0.path.path.replacingOccurrences(of: workspace.homeURL.path + "/", with: ""), $0)
            }
        )

        for relativePath in expectedRelativePaths {
            let item = try XCTUnwrap(itemsByRelativePath[relativePath])
            let externalURL = workspace.externalRootURL
                .appendingPathComponent(DataDirType.dotFolder.rawValue)
                .appendingPathComponent(relativePath)
            XCTAssertEqual(item.status, "待接回")
            XCTAssertEqual(item.linkedDestination?.standardizedFileURL, externalURL.standardizedFileURL)
            XCTAssertTrue(item.isMigratable)
        }
    }

    func testIssue49KnownToolDirectoriesRemainHiddenWhenMissingLocallyAndExternally() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanKnownDotFolders(
            externalRootURL: workspace.externalRootURL
        )
        let issue49Paths = Set([".gradle", ".android", ".pub-cache"])
        let returnedIssue49Paths = Set(
            items.map { $0.path.path.replacingOccurrences(of: workspace.homeURL.path + "/", with: "") }
                .filter { issue49Paths.contains($0) }
        )

        XCTAssertTrue(returnedIssue49Paths.isEmpty)
    }

    func testIssue49LocalDirectoryTakesPrecedenceWhenExternalMirrorAlsoExists() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localPubCacheURL = workspace.homeURL.appendingPathComponent(".pub-cache")
        let externalPubCacheURL = workspace.externalRootURL
            .appendingPathComponent(DataDirType.dotFolder.rawValue)
            .appendingPathComponent(".pub-cache")
        try createDirectoryWithPayload(at: localPubCacheURL)
        try createDirectoryWithPayload(at: externalPubCacheURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanKnownDotFolders(
            externalRootURL: workspace.externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localPubCacheURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "本地")
        XCTAssertNil(item.linkedDestination)
    }

    func testIssue49ExternalRegularFileDoesNotCreatePendingRelinkItem() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localPubCacheURL = workspace.homeURL.appendingPathComponent(".pub-cache")
        let externalToolRootURL = workspace.externalRootURL.appendingPathComponent(DataDirType.dotFolder.rawValue)
        let externalPubCacheURL = externalToolRootURL.appendingPathComponent(".pub-cache")
        try fileManager.createDirectory(at: externalToolRootURL, withIntermediateDirectories: true)
        try "not a directory".write(to: externalPubCacheURL, atomically: true, encoding: .utf8)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanKnownDotFolders(
            externalRootURL: workspace.externalRootURL
        )

        XCTAssertNil(items.first(where: { $0.path.standardizedFileURL == localPubCacheURL.standardizedFileURL }))
    }

    func testIssue49KnownToolDirectoryStateMatrix() async throws {
        for relativePath in issue49RelativePaths {
            for localState in Issue49LocalState.allCases {
                for externalState in Issue49ExternalState.allCases {
                    try await assertIssue49KnownToolDirectoryState(
                        relativePath: relativePath,
                        localState: localState,
                        externalState: externalState
                    )
                }
            }
        }
    }

    func testIssue49ManagedDotFolderLinkIsReportedAsLinked() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localPubCacheURL = workspace.homeURL.appendingPathComponent(".pub-cache")
        let externalPubCacheURL = workspace.externalRootURL
            .appendingPathComponent(DataDirType.dotFolder.rawValue)
            .appendingPathComponent(".pub-cache")
        try createDirectoryWithPayload(at: externalPubCacheURL)
        try writeManagedLinkMetadata(
            sourcePath: localPubCacheURL,
            destinationPath: externalPubCacheURL,
            dataDirType: DataDirType.dotFolder.rawValue
        )
        try fileManager.createSymbolicLink(at: localPubCacheURL, withDestinationURL: externalPubCacheURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanKnownDotFolders(
            externalRootURL: workspace.externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localPubCacheURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "已链接")
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, externalPubCacheURL.standardizedFileURL)
    }

    func testIssue49UnmanagedDotFolderSymlinkIsReportedAsExistingLink() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localPubCacheURL = workspace.homeURL.appendingPathComponent(".pub-cache")
        let externalPubCacheURL = workspace.externalRootURL
            .appendingPathComponent(DataDirType.dotFolder.rawValue)
            .appendingPathComponent(".pub-cache")
        try createDirectoryWithPayload(at: externalPubCacheURL)
        try fileManager.createSymbolicLink(at: localPubCacheURL, withDestinationURL: externalPubCacheURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanKnownDotFolders(
            externalRootURL: workspace.externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localPubCacheURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "现有软链")
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, externalPubCacheURL.standardizedFileURL)
    }

    func testIssue49DanglingLocalSymlinkIsNotReportedAsPendingRelink() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localPubCacheURL = workspace.homeURL.appendingPathComponent(".pub-cache")
        let danglingTargetURL = workspace.rootURL.appendingPathComponent("MissingPubCacheTarget")
        let externalPubCacheURL = workspace.externalRootURL
            .appendingPathComponent(DataDirType.dotFolder.rawValue)
            .appendingPathComponent(".pub-cache")
        try createDirectoryWithPayload(at: externalPubCacheURL)
        try fileManager.createSymbolicLink(at: localPubCacheURL, withDestinationURL: danglingTargetURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanKnownDotFolders(
            externalRootURL: workspace.externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localPubCacheURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "现有软链")
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, danglingTargetURL.standardizedFileURL)
    }

    func testManagedLinkAtNormalizedDestinationIsReportedAsLinked() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Focus.app", bundleID: "com.example.focus", in: workspace.appsURL)
        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.focus")
        let externalRootURL = workspace.externalRootURL
        let externalDataURL = externalRootURL
            .appendingPathComponent("Application Support/com.example.focus")

        try createDirectoryWithPayload(at: externalDataURL)
        try await DataDirMover(homeDir: workspace.homeURL, store: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).createLink(
            localPath: localDataURL,
            externalPath: externalDataURL
        )

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "Focus.app", path: appURL, status: "本地"),
            externalRootURL: externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localDataURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "已链接")
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, externalDataURL.standardizedFileURL)
    }

    func testManagedLinkOutsideNormalizedRootIsReportedAsNeedsNormalization() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Focus.app", bundleID: "com.example.focus", in: workspace.appsURL)
        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.focus")
        let currentExternalURL = workspace.rootURL
            .appendingPathComponent("ManualStore/com.example.focus")
        let externalRootURL = workspace.externalRootURL

        try createDirectoryWithPayload(at: currentExternalURL)
        try await DataDirMover(homeDir: workspace.homeURL, store: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).createLink(
            localPath: localDataURL,
            externalPath: currentExternalURL
        )

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "Focus.app", path: appURL, status: "本地"),
            externalRootURL: externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localDataURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "待规范")
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, currentExternalURL.standardizedFileURL)
    }

    func testUnmanagedSymlinkIsReportedAsExistingLink() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Focus.app", bundleID: "com.example.focus", in: workspace.appsURL)
        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.focus")
        let externalDataURL = workspace.rootURL
            .appendingPathComponent("ManualStore/com.example.focus")

        try createDirectoryWithPayload(at: externalDataURL)
        try fileManager.createDirectory(at: localDataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: localDataURL, withDestinationURL: externalDataURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "Focus.app", path: appURL, status: "本地")
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localDataURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "现有软链")
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, externalDataURL.standardizedFileURL)
    }

    func testHistoricalLogMatchDoesNotUpgradeUnmanagedSymlinkToManagedLink() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Focus.app", bundleID: "com.example.focus", in: workspace.appsURL)
        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.focus")
        let externalDataURL = workspace.externalRootURL
            .appendingPathComponent("Application Support/com.example.focus")
        let logURL = workspace.rootURL.appendingPathComponent("AppPorts_Log.txt")

        try createDirectoryWithPayload(at: externalDataURL)
        try fileManager.createDirectory(at: localDataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: localDataURL, withDestinationURL: externalDataURL)
        try "步骤3: 符号链接创建成功: \(localDataURL.path) -> \(externalDataURL.path)\n".write(
            to: logURL,
            atomically: true,
            encoding: .utf8
        )
        UserDefaults.standard.set(logURL.path, forKey: "LogFilePath")

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "Focus.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localDataURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "现有软链")
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, externalDataURL.standardizedFileURL)
    }

    func testMirroredExternalDirectoryWithoutLocalPathIsReportedAsPendingRelink() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Focus.app", bundleID: "com.example.focus", in: workspace.appsURL)
        let localDataURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.focus")
        let externalRootURL = workspace.externalRootURL
        let externalDataURL = externalRootURL
            .appendingPathComponent("Library/Application Support/com.example.focus")

        try createDirectoryWithPayload(at: externalDataURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "Focus.app", path: appURL, status: "本地"),
            externalRootURL: externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localDataURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "待接回")
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, externalDataURL.standardizedFileURL)
    }

    func testLocalGroupContainerRootIsNotOfferedAsMigratableData() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let localGroupContainerURL = workspace.homeURL
            .appendingPathComponent("Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat")

        try createDirectoryWithPayload(at: localGroupContainerURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        XCTAssertFalse(try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localGroupContainerURL.standardizedFileURL })).isMigratable)
    }

    // MARK: - Bundle ID 后缀匹配

    func testGenericBundleIDSuffixDoesNotMatchOtherAppsContainers() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Termius.app", bundleID: "com.termius-dmg.mac", in: workspace.appsURL)
        let ownContainerURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.termius-dmg.mac/Data/Documents/Payload")
        let foreignContainerURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.QQMusicMac/Data/Documents/Payload")
        try createDirectoryWithPayload(at: ownContainerURL)
        try createDirectoryWithPayload(at: foreignContainerURL)

        let items = await DataDirScanner(
            homeDir: workspace.homeURL,
            mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("mounts.plist")),
            isSandboxedApplication: { _ in false }
        ).scanLibraryDirs(for: AppItem(name: "Termius.app", path: appURL, status: "本地"))

        XCTAssertNotNil(items.first(where: { $0.path.standardizedFileURL == ownContainerURL.standardizedFileURL }))
        XCTAssertNil(items.first(where: { $0.path.path.contains("QQMusicMac") }), "通用后缀 mac 不应匹配到其他应用的容器")
    }

    func testAppNameRegionDoesNotIncludeUnrelatedLinkedContainersInRepair() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Trae CN.app", bundleID: "cn.trae.app", in: workspace.appsURL)
        let ownDataURL = workspace.homeURL.appendingPathComponent("Library/Containers/cn.trae.app/Data/Documents/Payload")
        let unrelatedURL = workspace.homeURL.appendingPathComponent("Library/Containers/cn.wps.wpslaunchhelper/Data/Library/Application Support/Kingsoft")
        let externalDataURL = workspace.externalRootURL.appendingPathComponent("Kingsoft")
        try createDirectoryWithPayload(at: ownDataURL)
        try createDirectoryWithPayload(at: externalDataURL)
        try fileManager.createDirectory(at: unrelatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: unrelatedURL, withDestinationURL: externalDataURL)

        let items = await DataDirScanner(
            homeDir: workspace.homeURL,
            mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("mounts.plist")),
            isSandboxedApplication: { _ in false }
        ).scanLibraryDirs(for: AppItem(name: "Trae CN.app", path: appURL, status: AppStatus.local))

        XCTAssertTrue(items.contains { $0.path.standardizedFileURL == ownDataURL.standardizedFileURL })
        XCTAssertFalse(items.contains { $0.path.path.contains("cn.wps.wpslaunchhelper") }, "地区词 CN 不能把其他应用的链接送进签名修复的还原列表")
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: unrelatedURL.path), externalDataURL.path)
    }

    func testShortProductNameStillMatchesItsOwnData() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "QQ.app", bundleID: "com.tencent.qq", in: workspace.appsURL)
        let ownDataURL = workspace.homeURL.appendingPathComponent("Library/Application Support/QQ")
        try createDirectoryWithPayload(at: ownDataURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "QQ.app", path: appURL, status: AppStatus.local)
        )
        XCTAssertTrue(items.contains { $0.path.standardizedFileURL == ownDataURL.standardizedFileURL })
    }

    // MARK: - 沙盒应用与挂载迁移

    func testSandboxedAppContainerDataRequiresMountMigration() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Focus.app", bundleID: "com.example.focus", in: workspace.appsURL)
        let containerDataURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.example.focus/Data/Documents/Payload")
        let appSupportURL = workspace.homeURL
            .appendingPathComponent("Library/Application Support/com.example.focus")
        try createDirectoryWithPayload(at: containerDataURL)
        try createDirectoryWithPayload(at: appSupportURL)

        let scanner = DataDirScanner(
            homeDir: workspace.homeURL,
            mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("mounts.plist")),
            isSandboxedApplication: { _ in true }
        )
        let app = AppItem(name: "Focus.app", path: appURL, status: "本地")
        let requiresMount = await scanner.isSandboxed(app)
        let items = await scanner.scanLibraryDirs(for: app, externalRootURL: workspace.externalRootURL)

        XCTAssertTrue(requiresMount)
        let containerItem = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == containerDataURL.standardizedFileURL }))
        XCTAssertTrue(containerItem.requiresMountMigration)
        XCTAssertTrue(containerItem.isMigratable)
        XCTAssertNil(containerItem.migrationWarning, "沙盒应用不再走符号链接迁移，符号链接风险提示不适用")
        XCTAssertEqual(containerItem.status, "本地")

        let appSupportItem = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == appSupportURL.standardizedFileURL }))
        XCTAssertFalse(appSupportItem.requiresMountMigration, "容器外的目录仍然使用符号链接迁移")
    }

    func testNonSandboxedAppContainerDataStillRequiresMountMigration() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Focus.app", bundleID: "com.example.focus", in: workspace.appsURL)
        let containerDataURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.example.focus/Data/Documents/Payload")
        try createDirectoryWithPayload(at: containerDataURL)

        let scanner = DataDirScanner(
            homeDir: workspace.homeURL,
            mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("mounts.plist")),
            isSandboxedApplication: { _ in false }
        )
        let items = await scanner.scanLibraryDirs(
            for: AppItem(name: "Focus.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        // 容器的主人可能是沙盒的小组件/扩展，主应用不沙盒也不能用符号链接。
        let containerItem = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == containerDataURL.standardizedFileURL }))
        XCTAssertTrue(containerItem.requiresMountMigration)
        XCTAssertNil(containerItem.migrationWarning)
    }

    func testMountRecordsAreReportedByMountAndVolumeState() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Focus.app", bundleID: "com.example.focus", in: workspace.appsURL)
        let documentsURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.example.focus/Data/Documents")
        let mountedURL = documentsURL.appendingPathComponent("Mounted")
        let pendingURL = documentsURL.appendingPathComponent("Pending")
        let missingURL = documentsURL.appendingPathComponent("Missing")
        for url in [mountedURL, pendingURL, missingURL] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("mounts.plist"))
        for (url, uuid) in [(mountedURL, "MOUNTED"), (pendingURL, "PENDING"), (missingURL, "MISSING")] {
            try store.upsert(ContainerMountRecord(
                appName: "Focus", bundleIdentifier: "com.example.focus", dataDirType: DataDirType.containers.rawValue,
                mountPointPath: url.standardizedFileURL.path, volumeUUID: uuid, volumeName: "AppPorts-\(uuid)",
                externalRootPath: workspace.externalRootURL.path
            ))
        }

        let mountedPath = mountedURL.resolvingSymlinksInPath().path
        let scanner = DataDirScanner(
            homeDir: workspace.homeURL,
            mountStore: store,
            isMountPoint: { $0.resolvingSymlinksInPath().path == mountedPath },
            isVolumeOnline: { $0 == "PENDING" },
            isSandboxedApplication: { _ in true }
        )
        let items = await scanner.scanLibraryDirs(
            for: AppItem(name: "Focus.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )
        let statuses = Dictionary(uniqueKeysWithValues: items.map { ($0.path.lastPathComponent, $0.status) })

        XCTAssertEqual(statuses["Mounted"], "已挂载")
        XCTAssertEqual(statuses["Pending"], "待挂载")
        XCTAssertEqual(statuses["Missing"], "卷丢失")
        for name in ["Mounted", "Pending", "Missing"] {
            let item = try XCTUnwrap(items.first(where: { $0.path.lastPathComponent == name }))
            XCTAssertTrue(item.requiresMountMigration)
            XCTAssertNil(item.linkedDestination)
        }
    }

    func testManagedGroupContainerRootLinkIsReportedButNotMigratable() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let localGroupContainerURL = workspace.homeURL
            .appendingPathComponent("Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat")
        let externalGroupContainerURL = workspace.externalRootURL
            .appendingPathComponent("Group Containers/5A4RE8SF68.com.tencent.xinWeChat")

        try createDirectoryWithPayload(at: externalGroupContainerURL)
        try writeManagedLinkMetadata(
            sourcePath: localGroupContainerURL,
            destinationPath: externalGroupContainerURL,
            dataDirType: DataDirType.groupContainers.rawValue
        )
        try fileManager.createDirectory(
            at: localGroupContainerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(at: localGroupContainerURL, withDestinationURL: externalGroupContainerURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        let item = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == localGroupContainerURL.standardizedFileURL }))
        XCTAssertEqual(item.status, "已链接")
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, externalGroupContainerURL.standardizedFileURL)
        XCTAssertFalse(item.isMigratable)
        XCTAssertNotNil(item.nonMigratableReason)
    }

    // MARK: - 目录大小缓存

    func testFreshMeasurementIncludesWritesWhileFileRemainsOpen() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let directory = workspace.homeURL.appendingPathComponent("ActiveData")
        try createDirectoryWithPayload(at: directory)
        XCTAssertEqual(fastDirectorySize(at: directory), 7)

        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("payload.txt"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 1, count: 4096))

        let result = measureDirectorySize(at: directory, useCache: false)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.bytes, 4103)
        XCTAssertEqual(fastDirectorySize(at: directory), 4103)
    }

    func testUnreadableDirectoryIsNotReportedOrCachedAsEmpty() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let directory = workspace.homeURL.appendingPathComponent("ProtectedData")
        try createDirectoryWithPayload(at: directory)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        guard !fileManager.isReadableFile(atPath: directory.path) else {
            throw XCTSkip("当前进程可绕过测试目录的文件权限")
        }

        let result = measureDirectorySize(at: directory)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.bytes, 0)
        XCTAssertTrue(result.readIssues.contains(where: \.isPermissionDenied))

        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let retried = measureDirectorySize(at: directory)
        XCTAssertTrue(retried.isComplete)
        XCTAssertEqual(retried.bytes, 7)
    }

    func testPartialDirectorySizeIsNotCachedAsACompleteResult() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let directory = workspace.homeURL.appendingPathComponent("MixedData")
        let protected = directory.appendingPathComponent("Protected")
        try createDirectoryWithPayload(at: directory)
        try createDirectoryWithPayload(at: protected)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: protected.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path) }
        guard !fileManager.isReadableFile(atPath: protected.path) else {
            throw XCTSkip("当前进程可绕过测试目录的文件权限")
        }

        let partial = measureDirectorySize(at: directory)
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.bytes, 7)

        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path)
        let retried = measureDirectorySize(at: directory)
        XCTAssertTrue(retried.isComplete)
        XCTAssertEqual(retried.bytes, 14)
    }

    func testSizeMeasurementDistinguishesMissingAndEmptyDirectories() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let empty = workspace.homeURL.appendingPathComponent("Empty")
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)

        let emptyResult = measureDirectorySize(at: empty)
        let missingResult = measureDirectorySize(at: workspace.homeURL.appendingPathComponent("Missing"))
        XCTAssertEqual(emptyResult.bytes, 0)
        XCTAssertTrue(emptyResult.isComplete)
        XCTAssertEqual(missingResult.bytes, 0)
        XCTAssertFalse(missingResult.isComplete)
    }

    func testSizeMeasurementDoesNotFollowNestedSymlinks() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let local = workspace.homeURL.appendingPathComponent("Local")
        let external = workspace.externalRootURL.appendingPathComponent("ExternalData")
        try createDirectoryWithPayload(at: local)
        try createDirectoryWithPayload(at: external)
        try fileManager.createSymbolicLink(at: local.appendingPathComponent("Linked"), withDestinationURL: external)

        let result = measureDirectorySize(at: local)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.bytes, 7)
    }

    func testNestedDirectoryChangesInvalidateEveryAncestorInBothMountStates() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let documents = workspace.homeURL.appendingPathComponent("Documents")
        let files = documents.appendingPathComponent("xwechat_files")
        let account = files.appendingPathComponent("account")
        try createDirectoryWithPayload(at: account)
        try Data(repeating: 1, count: 100).write(to: documents.appendingPathComponent("other.data"))
        try Data(repeating: 2, count: 20).write(to: files.appendingPathComponent("metadata.data"))

        for mounted in [false, true] {
            XCTAssertEqual(fastDirectorySize(at: account, isMountPoint: { _ in mounted }), 7)
            XCTAssertEqual(fastDirectorySize(at: files, isMountPoint: { _ in mounted }), 27)
            XCTAssertEqual(fastDirectorySize(at: documents, isMountPoint: { _ in mounted }), 127)
        }

        // Restore, unmount, and remount can grow or shrink the same nested path.
        for payloadSize in [4096, 0, 8192] {
            try Data(repeating: 3, count: payloadSize).write(to: account.appendingPathComponent("payload.txt"))
            invalidateSizeCache(for: account)

            for mounted in [false, true] {
                XCTAssertEqual(fastDirectorySize(at: account, isMountPoint: { _ in mounted }), Int64(payloadSize))
                XCTAssertEqual(fastDirectorySize(at: files, isMountPoint: { _ in mounted }), Int64(payloadSize + 20))
                XCTAssertEqual(fastDirectorySize(at: documents, isMountPoint: { _ in mounted }), Int64(payloadSize + 120))
            }
        }
    }

    func testAncestorInvalidationPreservesUnrelatedDirectoryCaches() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let changed = workspace.homeURL.appendingPathComponent("Documents/account")
        let sibling = workspace.homeURL.appendingPathComponent("Documents/other")
        let similarPrefix = workspace.homeURL.appendingPathComponent("DocumentsBackup")
        for directory in [changed, sibling, similarPrefix] {
            try createDirectoryWithPayload(at: directory)
            XCTAssertEqual(fastDirectorySize(at: directory), 7)
            try fileManager.removeItem(at: directory.appendingPathComponent("payload.txt"))
        }

        invalidateSizeCache(for: changed)

        XCTAssertEqual(fastDirectorySize(at: changed), 0)
        XCTAssertEqual(fastDirectorySize(at: sibling), 7)
        XCTAssertEqual(fastDirectorySize(at: similarPrefix), 7)
    }

    /// 未挂载的挂载点就是一个空目录，算出来是 0。这个 0 一旦被缓存，
    /// 卷挂好之后列表仍会一直显示「0 字节」，所以 0 不能进缓存。
    func testEmptyDirectorySizeIsNotCachedAsZero() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let mountPointURL = workspace.homeURL.appendingPathComponent("UnmountedMountPoint")
        try fileManager.createDirectory(at: mountPointURL, withIntermediateDirectories: true)
        XCTAssertEqual(fastDirectorySize(at: mountPointURL), 0)

        // 卷挂上了：同一个路径必须重新算出真实大小，而不是命中缓存的 0。
        try "payload".write(
            to: mountPointURL.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(fastDirectorySize(at: mountPointURL), Int64("payload".utf8.count))
    }

    /// 卷被别的进程卸掉或挂回来时，缓存要跟着挂载状态走，不能沿用上一状态的大小。
    func testSizeCacheFollowsMountState() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let directoryURL = workspace.homeURL.appendingPathComponent("MountedDirectory")
        try createDirectoryWithPayload(at: directoryURL)
        let payloadSize = Int64("payload".utf8.count)

        var mounted = true
        let mountState: (URL) -> Bool = { _ in mounted }

        XCTAssertEqual(fastDirectorySize(at: directoryURL, isMountPoint: mountState), payloadSize)

        // 卷被外部卸载：同一路径现在是空目录，缓存里那份"已挂载"的大小不能继续沿用。
        try fileManager.removeItem(at: directoryURL.appendingPathComponent("payload.txt"))
        mounted = false
        XCTAssertEqual(fastDirectorySize(at: directoryURL, isMountPoint: mountState), 0)

        // 卷挂回来：重新算出真实大小，而不是命中卸载期间算出的 0。
        try "payload".write(
            to: directoryURL.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        mounted = true
        XCTAssertEqual(fastDirectorySize(at: directoryURL, isMountPoint: mountState), payloadSize)
    }

    /// 非 0 结果仍然缓存，避免每次扫描都重新遍历大目录。
    func testNonZeroDirectorySizeIsCached() throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let directoryURL = workspace.homeURL.appendingPathComponent("CachedDirectory")
        try createDirectoryWithPayload(at: directoryURL)
        let firstSize = fastDirectorySize(at: directoryURL)
        XCTAssertGreaterThan(firstSize, 0)

        // 文件被删掉后仍然命中缓存（这正是缓存存在的意义）。
        try fileManager.removeItem(at: directoryURL.appendingPathComponent("payload.txt"))
        XCTAssertEqual(fastDirectorySize(at: directoryURL), firstSize)

        // 缓存失效后回到真实大小。
        invalidateSizeCache(for: directoryURL)
        XCTAssertEqual(fastDirectorySize(at: directoryURL), 0)
    }

    private func makeWorkspace() throws -> (rootURL: URL, homeURL: URL, appsURL: URL, externalRootURL: URL) {
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent("DataDirScannerTests-\(UUID().uuidString)")
        let homeURL = rootURL.appendingPathComponent("Home")
        let appsURL = rootURL.appendingPathComponent("Applications")
        let externalRootURL = rootURL.appendingPathComponent("External")

        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: externalRootURL, withIntermediateDirectories: true)

        return (rootURL, homeURL, appsURL, externalRootURL)
    }

    private func cleanupWorkspace(_ rootURL: URL) {
        try? fileManager.removeItem(at: rootURL)
    }

    private func createAppBundle(named name: String, bundleID: String, in appsURL: URL) throws -> URL {
        let appURL = appsURL.appendingPathComponent(name)
        let contentsURL = appURL.appendingPathComponent("Contents")
        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let executableURL = macOSURL.appendingPathComponent(name.replacingOccurrences(of: ".app", with: ""))
        try "echo test".write(to: executableURL, atomically: true, encoding: .utf8)

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name.replacingOccurrences(of: ".app", with: "")
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: infoPlistURL)

        return appURL
    }

    private func createDirectoryWithPayload(at directoryURL: URL) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "payload".write(
            to: directoryURL.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func assertIssue49KnownToolDirectoryState(
        relativePath: String,
        localState: Issue49LocalState,
        externalState: Issue49ExternalState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let localURL = workspace.homeURL.appendingPathComponent(relativePath)
        let externalURL = workspace.externalRootURL
            .appendingPathComponent(DataDirType.dotFolder.rawValue)
            .appendingPathComponent(relativePath)
        let externalParentURL = externalURL.deletingLastPathComponent()
        let manualTargetURL = workspace.rootURL
            .appendingPathComponent("ManualTargets")
            .appendingPathComponent(relativePath)
        let danglingTargetURL = workspace.rootURL
            .appendingPathComponent("MissingTargets")
            .appendingPathComponent(relativePath)

        switch externalState {
        case .missing:
            break
        case .directory:
            try createDirectoryWithPayload(at: externalURL)
        case .regularFile:
            try fileManager.createDirectory(at: externalParentURL, withIntermediateDirectories: true)
            try "external file".write(to: externalURL, atomically: true, encoding: .utf8)
        }

        switch localState {
        case .missing:
            break
        case .directory:
            try createDirectoryWithPayload(at: localURL)
        case .regularFile:
            try "local file".write(to: localURL, atomically: true, encoding: .utf8)
        case .unmanagedSymlink:
            try createDirectoryWithPayload(at: manualTargetURL)
            try fileManager.createSymbolicLink(at: localURL, withDestinationURL: manualTargetURL)
        case .danglingSymlink:
            try fileManager.createSymbolicLink(at: localURL, withDestinationURL: danglingTargetURL)
        }

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanKnownDotFolders(
            externalRootURL: workspace.externalRootURL
        )
        let item = items.first { $0.path.standardizedFileURL == localURL.standardizedFileURL }
        let caseDescription = "\(relativePath), local=\(localState), external=\(externalState)"

        switch localState {
        case .missing:
            if externalState == .directory {
                let item = try XCTUnwrap(item, caseDescription, file: file, line: line)
                XCTAssertEqual(item.status, "待接回", caseDescription, file: file, line: line)
                XCTAssertEqual(
                    item.linkedDestination?.standardizedFileURL,
                    externalURL.standardizedFileURL,
                    caseDescription,
                    file: file,
                    line: line
                )
            } else {
                XCTAssertNil(item, caseDescription, file: file, line: line)
            }
        case .directory:
            let item = try XCTUnwrap(item, caseDescription, file: file, line: line)
            XCTAssertEqual(item.status, "本地", caseDescription, file: file, line: line)
            XCTAssertNil(item.linkedDestination, caseDescription, file: file, line: line)
        case .regularFile:
            XCTAssertNil(item, caseDescription, file: file, line: line)
        case .unmanagedSymlink:
            let item = try XCTUnwrap(item, caseDescription, file: file, line: line)
            XCTAssertEqual(item.status, "现有软链", caseDescription, file: file, line: line)
            XCTAssertEqual(
                item.linkedDestination?.standardizedFileURL,
                manualTargetURL.standardizedFileURL,
                caseDescription,
                file: file,
                line: line
            )
        case .danglingSymlink:
            let item = try XCTUnwrap(item, caseDescription, file: file, line: line)
            XCTAssertEqual(item.status, "现有软链", caseDescription, file: file, line: line)
            XCTAssertEqual(
                item.linkedDestination?.standardizedFileURL,
                danglingTargetURL.standardizedFileURL,
                caseDescription,
                file: file,
                line: line
            )
        }
    }

    private func writeManagedLinkMetadata(
        sourcePath: URL,
        destinationPath: URL,
        dataDirType: String
    ) throws {
        let metadata: [String: Any] = [
            "schemaVersion": 1,
            "managedBy": "com.shimoko.AppPorts",
            "sourcePath": sourcePath.standardizedFileURL.path,
            "destinationPath": destinationPath.standardizedFileURL.path,
            "dataDirType": dataDirType
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        try data.write(
            to: destinationPath.appendingPathComponent(".appports-link-metadata.plist"),
            options: .atomic
        )
    }

    // MARK: - 微信容器扫描策略测试

    func testUnreadableWeChatContainerReportsIncompleteScanAndCanBeRetried() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let dataURL = workspace.homeURL.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        let accountURL = dataURL.appendingPathComponent("Documents/xwechat_files/account")
        let cacheURL = workspace.homeURL.appendingPathComponent("Library/Caches/com.tencent.xinWeChat")
        try createDirectoryWithPayload(at: accountURL)
        try createDirectoryWithPayload(at: cacheURL)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dataURL.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataURL.path) }
        guard !fileManager.isReadableFile(atPath: dataURL.path) else {
            throw XCTSkip("当前进程可绕过测试目录的文件权限")
        }

        let scanner = DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist")))
        let app = AppItem(name: "WeChat.app", path: appURL, status: "本地")
        let partial = await scanner.scanLibraryDirsWithDiagnostics(for: app)
        XCTAssertTrue(partial.items.contains { $0.path.resolvingSymlinksInPath() == cacheURL.resolvingSymlinksInPath() })
        XCTAssertTrue(partial.readIssues.contains {
            $0.url.resolvingSymlinksInPath() == dataURL.resolvingSymlinksInPath() && $0.isPermissionDenied
        })

        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataURL.path)
        let retried = await scanner.scanLibraryDirsWithDiagnostics(for: app)
        XCTAssertTrue(retried.readIssues.isEmpty)
        XCTAssertTrue(retried.items.contains { $0.path.resolvingSymlinksInPath() == accountURL.resolvingSymlinksInPath() })
    }

    func testWeChatContainerSurfacesLockedSystemDataAtDataLevel() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let containerURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat")
        let dataURL = containerURL.appendingPathComponent("Data")

        try createDirectoryWithPayload(at: dataURL.appendingPathComponent("Documents"))
        try createDirectoryWithPayload(at: dataURL.appendingPathComponent("Library"))
        try createDirectoryWithPayload(at: dataURL.appendingPathComponent("SystemData"))

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        // 仅 Documents 和 Library 出现（作为不可迁移父节点）
        let dataLevelItems = items.filter { $0.path.deletingLastPathComponent().lastPathComponent == "Data" }
        let dataLevelNames = Set(dataLevelItems.map { $0.path.lastPathComponent })
        XCTAssertEqual(dataLevelNames, ["Documents", "Library", "SystemData"])
        for item in dataLevelItems {
            XCTAssertFalse(item.isMigratable)
        }
    }

    func testWeChatXwechatFilesSubdirectoriesAreIndividuallyMigratable() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let xwechatFilesURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files")

        try createDirectoryWithPayload(at: xwechatFilesURL.appendingPathComponent("msg"))
        try createDirectoryWithPayload(at: xwechatFilesURL.appendingPathComponent("file"))
        try createDirectoryWithPayload(at: xwechatFilesURL.appendingPathComponent("video"))

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        let xChildren = items.filter { $0.path.path.contains("xwechat_files/") }
        XCTAssertEqual(xChildren.count, 3)
        for child in xChildren {
            XCTAssertTrue(child.isMigratable)
            XCTAssertEqual(child.status, "本地")
        }
    }

    func testWeChatXwechatFilesItselfIsNotMigratable() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let xwechatFilesURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files")
        try createDirectoryWithPayload(at: xwechatFilesURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        let xDir = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == xwechatFilesURL.standardizedFileURL }))
        XCTAssertFalse(xDir.isMigratable)
        XCTAssertNotNil(xDir.nonMigratableReason)
    }

    func testWeChatApplicationSupportComTencentXinWeChatIsMigratable() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let weChatDataURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat")
        try createDirectoryWithPayload(at: weChatDataURL)

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        let weChatItem = try XCTUnwrap(items.first(where: { $0.path.standardizedFileURL == weChatDataURL.standardizedFileURL }))
        XCTAssertTrue(weChatItem.isMigratable)
        XCTAssertEqual(weChatItem.status, "本地")
    }

    func testWeChatOtherDocumentsChildrenAreVisibleButLocked() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let documentsURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents")
        try createDirectoryWithPayload(at: documentsURL.appendingPathComponent("OtherStuff"))
        try createDirectoryWithPayload(at: documentsURL.appendingPathComponent("RandomDir"))

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        XCTAssertTrue(items.contains { $0.path.lastPathComponent == "OtherStuff" })
        XCTAssertTrue(items.contains { $0.path.lastPathComponent == "RandomDir" })
        for item in items {
            if item.path.path.contains("OtherStuff") { XCTAssertFalse(item.isMigratable) }
            if item.path.path.contains("RandomDir") { XCTAssertFalse(item.isMigratable) }
        }
    }

    func testWeChatOtherLibraryChildrenAreVisibleButLocked() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let libraryURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library")
        try createDirectoryWithPayload(at: libraryURL.appendingPathComponent("Caches"))
        try createDirectoryWithPayload(at: libraryURL.appendingPathComponent("Preferences"))

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        XCTAssertTrue(items.contains { $0.path.lastPathComponent == "Caches" })
        XCTAssertTrue(items.contains { $0.path.lastPathComponent == "Preferences" })
        for item in items {
            if item.path.path.contains("Data/Library/Caches") { XCTAssertFalse(item.isMigratable) }
            if item.path.path.contains("Data/Library/Preferences") { XCTAssertFalse(item.isMigratable) }
        }
    }

    func testWeChatOtherApplicationSupportChildrenAreVisibleButLocked() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let appSupportURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support")
        try createDirectoryWithPayload(at: appSupportURL.appendingPathComponent("com.other.App"))
        try createDirectoryWithPayload(at: appSupportURL.appendingPathComponent("RandomSupport"))

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        XCTAssertTrue(items.contains { $0.path.lastPathComponent == "com.other.App" })
        XCTAssertTrue(items.contains { $0.path.lastPathComponent == "RandomSupport" })
        for item in items {
            if item.path.path.contains("com.other.App") { XCTAssertFalse(item.isMigratable) }
            if item.path.path.contains("RandomSupport") { XCTAssertFalse(item.isMigratable) }
        }
    }

    func testWeChatNonDocumentsNonLibraryDataChildrenAreVisibleButLocked() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let dataURL = workspace.homeURL
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        try createDirectoryWithPayload(at: dataURL.appendingPathComponent("SystemData"))

        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"),
            externalRootURL: workspace.externalRootURL
        )

        XCTAssertTrue(items.contains { $0.path.lastPathComponent == "SystemData" })
        for item in items {
            if item.path.path.contains("SystemData") { XCTAssertFalse(item.isMigratable) }
        }
    }
    func testPersonalFolderShortcutsAreLockedUnmeasuredAndHiddenWithStructure() async throws {
        for bundleID in ["com.tencent.xinWeChat", "com.example.test"] {
            let workspace = try makeWorkspace()
            defer { cleanupWorkspace(workspace.rootURL) }
            let appURL = try createAppBundle(named: "Example.app", bundleID: bundleID, in: workspace.appsURL)
            let data = workspace.homeURL.appendingPathComponent("Library/Containers/\(bundleID)/Data")
            try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
            for name in ["Desktop", "Pictures", "Downloads"] {
                let target = workspace.homeURL.appendingPathComponent(name)
                try createDirectoryWithPayload(at: target)
                try fileManager.createSymbolicLink(at: data.appendingPathComponent(name), withDestinationURL: target)
            }
            let scanner = DataDirScanner(homeDir: workspace.homeURL,
                mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("records.plist")))
            let items = await scanner.scanLibraryDirs(for: AppItem(name: "Example.app", path: appURL, status: "本地"), externalRootURL: workspace.externalRootURL)
            for name in ["Desktop", "Pictures", "Downloads"] {
                let row = try XCTUnwrap(items.first { $0.path.standardizedFileURL.path == data.appendingPathComponent(name).standardizedFileURL.path })
                XCTAssertTrue(row.isUserDirectoryLink)
                XCTAssertFalse(row.isMigratable)
                XCTAssertFalse(row.canRestore)
                XCTAssertNil(row.sizeMeasurementURL)
                XCTAssertEqual(row.size, "—")
                XCTAssertEqual(row.sizeBytes, 0)
                let measured = await scanner.calculateSize(for: row)
                XCTAssertEqual(measured, 0)
                XCTAssertFalse(row.matchesVisibility(showZeroByteDirectories: true, showLockedStructure: false))
                XCTAssertTrue(row.matchesVisibility(showZeroByteDirectories: false, showLockedStructure: true))
                XCTAssertEqual(try String(contentsOf: workspace.homeURL.appendingPathComponent(name + "/payload.txt")), "payload")
            }
        }
    }

    func testEveryContainerStructuralDirectoryIsVisibleButCannotMigrate() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "Example.app", bundleID: "com.example.test", in: workspace.appsURL)
        let container = workspace.homeURL.appendingPathComponent("Library/Containers/com.example.test")
        let relatives = ["", "Data", "Data/Documents", "Data/Library", "Data/Library/Application Scripts",
                         "Data/Library/Application Support", "Data/Library/Caches", "Data/Library/Images",
                         "Data/Library/Logs", "Data/Library/Preferences", "Data/Library/Saved Application State",
                         "Data/SystemData", "Data/tmp"]
        for relative in relatives {
            try createDirectoryWithPayload(at: container.appendingPathComponent(relative))
        }
        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "Example.app", path: appURL, status: "本地"))
        for relative in relatives {
            let url = container.appendingPathComponent(relative).standardizedFileURL
            let item = try XCTUnwrap(items.first { $0.path.standardizedFileURL == url }, relative)
            XCTAssertFalse(item.isMigratable, relative)
            XCTAssertNotNil(item.nonMigratableReason, relative)
        }
    }

    func testChangingLockReasonChangesItemEquality() {
        var original = DataDirItem(name: "Data", path: URL(fileURLWithPath: "/Data"), type: .containers,
                                   priority: .critical, description: "", isMigratable: false,
                                   nonMigratableReason: "System structure")
        let previous = original
        original.nonMigratableReason = "Read failed"
        XCTAssertNotEqual(original, previous)
    }

    func testMissingAndDeepMountRecordsAreMergedByBundleIdentity() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("records.plist"))
        let paths = ["Library/Containers/com.tencent.xinWeChat/Data/Library/Caches",
                     "Library/Containers/com.tencent.xinWeChat/Data/SystemData/hidden/deep/history",
                     "Library/Group Containers/legacy-renamed/Data/deep"]
        for path in paths {
            try store.upsert(ContainerMountRecord(appName: "Old display name", bundleIdentifier: "com.tencent.xinWeChat",
                dataDirType: path.contains("Group Containers") ? DataDirType.groupContainers.rawValue : DataDirType.containers.rawValue,
                mountPointPath: workspace.homeURL.appendingPathComponent(path).path,
                volumeUUID: path, volumeName: "history", externalRootPath: workspace.externalRootURL.path))
        }
        let unrelated = workspace.homeURL.appendingPathComponent("Library/Containers/com.other/Data")
        try store.upsert(ContainerMountRecord(appName: "WeChat", bundleIdentifier: "com.other",
            dataDirType: DataDirType.containers.rawValue, mountPointPath: unrelated.path,
            volumeUUID: "unrelated", volumeName: "other", externalRootPath: workspace.externalRootURL.path))
        let scanner = DataDirScanner(homeDir: workspace.homeURL, mountStore: store,
                                     isMountPoint: { _ in false }, isVolumeOnline: { _ in false })
        let items = await scanner.scanLibraryDirs(for: AppItem(name: "WeChat.app", path: appURL, status: "本地"))
        for path in paths {
            let item = try XCTUnwrap(items.first { $0.path.path == workspace.homeURL.appendingPathComponent(path).path })
            XCTAssertEqual(item.status, DataDirStatus.volumeMissing)
            XCTAssertTrue(item.canRestore)
        }
        XCTAssertFalse(items.contains { $0.path == unrelated })
    }

    func testLockedHistoricalLinkRetainsNeedsNormalizationRecovery() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let source = workspace.homeURL.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents")
        let target = workspace.externalRootURL.appendingPathComponent("old-location")
        try createDirectoryWithPayload(at: target)
        try writeManagedLinkMetadata(sourcePath: source, destinationPath: target, dataDirType: DataDirType.containers.rawValue)
        try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: source, withDestinationURL: target)
        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("scanner-records.plist"))).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"), externalRootURL: workspace.externalRootURL)
        let item = try XCTUnwrap(items.first { $0.path.standardizedFileURL == source.standardizedFileURL })
        XCTAssertEqual(item.status, DataDirStatus.needsNormalization)
        XCTAssertFalse(item.isMigratable)
        XCTAssertTrue(item.canRestore)
        XCTAssertFalse(items.contains { $0.path.path.hasPrefix(source.path + "/") })
    }

    func testIncompleteTransferOutsideDiscoveryDepthRemainsVisibleAndBlocked() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let source = workspace.homeURL.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/SystemData/hidden/deep/operation")
        try createDirectoryWithPayload(at: source)
        let destination = workspace.externalRootURL.appendingPathComponent("operation")
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("records.plist"))
        let transfer = DataTransferRecord(mode: .symlink, direction: .migrate, sourceID: source.path,
            appName: "Old name", bundleIdentifier: "com.tencent.xinWeChat", dataDirType: DataDirType.containers.rawValue,
            originalPath: source.path, activePath: source.path, destinationPath: destination.path,
            sourceIdentity: try DataPathIdentity.capture(source))
        try store.beginTransfer(transfer)
        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: store).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"))
        let item = try XCTUnwrap(items.first { $0.path.standardizedFileURL == source.standardizedFileURL })
        XCTAssertFalse(item.isMigratable)
        XCTAssertTrue(item.matchesVisibility(showZeroByteDirectories: false, showLockedStructure: false))
    }

    func testCompletedRetentionUsesNormalExplanationInsteadOfConflict() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "Synthetic.app", bundleID: "com.example.synthetic", in: workspace.appsURL)
        let source = workspace.homeURL.appendingPathComponent("Library/Containers/com.example.synthetic/Data/Documents/Payload")
        try createDirectoryWithPayload(at: source)
        let destination = workspace.externalRootURL.appendingPathComponent("operation")
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("records.plist"))
        var transfer = DataTransferRecord(mode: .symlink, direction: .migrate, sourceID: source.path,
            appName: "Synthetic", bundleIdentifier: "com.example.synthetic", dataDirType: DataDirType.containers.rawValue,
            originalPath: source.path, activePath: source.path, destinationPath: destination.path,
            sourceIdentity: try DataPathIdentity.capture(source))
        try store.beginTransfer(transfer)
        transfer.phase = .copying
        try store.updateTransfer(transfer)
        transfer.phase = .verified
        transfer.destinationIdentity = try DataPathIdentity.capture(source)
        transfer.baseline = Data("fixture-baseline".utf8)
        try store.updateTransfer(transfer)
        transfer.phase = .switching
        try store.updateTransfer(transfer)
        try store.finalizeTransfer(operationID: transfer.operationID, baseline: transfer.baseline!)
        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: store).scanLibraryDirs(
            for: AppItem(name: "Synthetic.app", path: appURL, status: "本地"))
        let item = try XCTUnwrap(items.first { $0.path.standardizedFileURL == source.standardizedFileURL })
        XCTAssertFalse(item.isMigratable)
        XCTAssertEqual(item.pathPolicy?.reason, .retainedOriginal)
        XCTAssertTrue(item.matchesVisibility(showZeroByteDirectories: false, showLockedStructure: false))
    }

    func testPersistedRemountInterventionReasonIsVisibleAfterRescan() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "Synthetic.app", bundleID: "com.example.synthetic", in: workspace.appsURL)
        let source = workspace.homeURL.appendingPathComponent("Library/Containers/com.example.synthetic/Data/Documents/Payload")
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("records.plist"))
        try store.upsert(ContainerMountRecord(appName: "Synthetic", bundleIdentifier: "com.example.synthetic",
            dataDirType: DataDirType.containers.rawValue, mountPointPath: source.path, volumeUUID: "OFFLINE",
            volumeName: "Synthetic", externalRootPath: workspace.externalRootURL.path))
        try store.setRemountIntervention(volumeUUID: "OFFLINE", reason: "Preserved local files prevent overlay")
        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: store).scanLibraryDirs(
            for: AppItem(name: "Synthetic.app", path: appURL, status: "本地"))
        let item = try XCTUnwrap(items.first { $0.path.standardizedFileURL == source.standardizedFileURL })
        XCTAssertFalse(item.isMigratable)
        XCTAssertEqual(item.nonMigratableReason, "Preserved local files prevent overlay")
        XCTAssertTrue(item.canRestore)
    }

    func testPersistentLinkIndexRetainsMissingDeepHistoricalSourceWithRecovery() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "WeChat.app", bundleID: "com.tencent.xinWeChat", in: workspace.appsURL)
        let source = workspace.homeURL.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/SystemData/a/b/missing")
        let target = workspace.externalRootURL.appendingPathComponent("historic-target")
        try createDirectoryWithPayload(at: target)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("records.plist"))
        try store.upsertManagedLink(ManagedDataLinkRecord(operationID: UUID(), originalPath: source.path,
            destinationPath: target.path, destinationIdentity: try DataPathIdentity.capture(target), appName: "Old display name",
            bundleIdentifier: "com.tencent.xinWeChat", dataDirType: DataDirType.containers.rawValue))
        let items = await DataDirScanner(homeDir: workspace.homeURL, mountStore: store).scanLibraryDirs(
            for: AppItem(name: "WeChat.app", path: appURL, status: "本地"))
        let item = try XCTUnwrap(items.first { $0.path.standardizedFileURL == source.standardizedFileURL })
        XCTAssertEqual(item.status, DataDirStatus.missing)
        XCTAssertFalse(item.isMigratable)
        XCTAssertTrue(item.canRestore)
        XCTAssertEqual(item.linkedDestination?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertTrue(item.matchesVisibility(showZeroByteDirectories: false, showLockedStructure: false))
    }

    func testMountedDataRootDoesNotEnumerateBusinessChildren() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "Example.app", bundleID: "com.example.test", in: workspace.appsURL)
        let data = workspace.homeURL.appendingPathComponent("Library/Containers/com.example.test/Data")
        try createDirectoryWithPayload(at: data.appendingPathComponent("Documents/Business"))
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("records.plist"))
        try store.upsert(ContainerMountRecord(appName: "Example", bundleIdentifier: "com.example.test", dataDirType: DataDirType.containers.rawValue,
            mountPointPath: data.path, volumeUUID: "fixture", volumeName: "fixture", externalRootPath: workspace.externalRootURL.path))
        let scanner = DataDirScanner(homeDir: workspace.homeURL, mountStore: store,
                                     isMountPoint: { $0.lastPathComponent == "Data" }, isVolumeOnline: { _ in true })
        let items = await scanner.scanLibraryDirs(for: AppItem(name: "Example.app", path: appURL, status: "本地"))
        let root = try XCTUnwrap(items.first { $0.path.standardizedFileURL == data.standardizedFileURL })
        XCTAssertTrue(root.canRestore)
        XCTAssertFalse(root.isMigratable)
        XCTAssertFalse(items.contains { $0.path.path.hasPrefix(data.path + "/") })
    }

    func testContradictoryLegacyMountHistoryRemainsVisibleWithDiagnostics() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }
        let appURL = try createAppBundle(named: "Example.app", bundleID: "com.example.test", in: workspace.appsURL)
        let parent = workspace.homeURL.appendingPathComponent("Library/Containers/com.example.test/Data")
        let child = parent.appendingPathComponent("Documents/deep/child")
        let records = [parent, child].map { path in
            ContainerMountRecord(appName: "Example", bundleIdentifier: "com.example.test", dataDirType: DataDirType.containers.rawValue,
                mountPointPath: path.path, volumeUUID: path.lastPathComponent, volumeName: "legacy", externalRootPath: workspace.externalRootURL.path)
        }
        let storeURL = workspace.rootURL.appendingPathComponent("records.plist")
        try PropertyListEncoder().encode(records).write(to: storeURL)
        let scanner = DataDirScanner(homeDir: workspace.homeURL, mountStore: ContainerMountStore(fileURL: storeURL),
                                     isMountPoint: { _ in false }, isVolumeOnline: { _ in false })
        let result = await scanner.scanLibraryDirsWithDiagnostics(for: AppItem(name: "Example.app", path: appURL, status: "本地"))
        XCTAssertFalse(result.readIssues.isEmpty)
        for path in [parent, child] {
            let item = try XCTUnwrap(result.items.first { $0.path.standardizedFileURL == path.standardizedFileURL })
            XCTAssertFalse(item.isMigratable)
            XCTAssertTrue(item.canRestore)
        }
    }

}
