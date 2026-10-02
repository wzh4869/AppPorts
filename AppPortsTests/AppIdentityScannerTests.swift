import XCTest
@testable import AppPorts

final class AppIdentityScannerTests: XCTestCase {
    func testNativeStubFindsOriginalContainer() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        let real = try fixture.native("External/鸣潮.app", id: "com.kurogame.mingchao")
        let portal = try fixture.stub("Apps/鸣潮.app", id: "com.kurogame.mingchao", target: real)
        let own = try fixture.container("com.kurogame.mingchao")
        let result = await fixture.scanner().scanLibraryDirs(for: fixture.app(portal))
        XCTAssertTrue(result.contains { $0.path.standardizedFileURL.path == own.standardizedFileURL.path })
    }

    func testLocalIOSWrapperFindsContainerAfterRestore() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        let app = try fixture.ios("Apps/bh3.app")
        let own = try fixture.container("com.miHoYo.bh3")
        let result = await fixture.scanner().scanLibraryDirs(for: fixture.app(app))
        XCTAssertTrue(result.contains { $0.path.standardizedFileURL.path == own.standardizedFileURL.path })
    }

    func testIOSStubFindsOriginalContainer() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        let real = try fixture.ios("External/bh3.app")
        let portal = try fixture.stub("Apps/bh3.app", id: "com.miHoYo.bh3", target: real, legacy: true)
        let own = try fixture.container("com.miHoYo.bh3")
        let result = await fixture.scanner().scanLibraryDirs(for: fixture.app(portal))
        XCTAssertTrue(result.contains { $0.path.standardizedFileURL.path == own.standardizedFileURL.path })
    }

    func testStubSuffixDoesNotAssociateUnrelatedContainers() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.cleanup() }
        let real = try fixture.native("External/鸣潮.app", id: "com.kurogame.mingchao")
        let portal = try fixture.stub("Apps/鸣潮.app", id: "com.kurogame.mingchao", target: real)
        _ = try fixture.container("com.unrelated.stubgame")
        let result = await fixture.scanner().scanLibraryDirs(for: fixture.app(portal))
        XCTAssertTrue(result.isEmpty)
    }

    func testWPSNativeAndBothStubFormatsReturnSameDirectories() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        let real = try f.native("External/wpsoffice.app", id: "com.kingsoft.wpsoffice.mac")
        _ = try f.container("com.kingsoft.wpsoffice.mac")
        _ = try f.container("com.unrelated.stubgame")
        let support = try f.directory("Home/Library/Application Support/wpsoffice")
        let scanner = f.scanner()
        let original = await scanner.scanLibraryDirs(for: f.app(real))
        XCTAssertTrue(original.contains { $0.path.standardizedFileURL.path == support.standardizedFileURL.path })
        XCTAssertFalse(original.isEmpty)
        for legacy in [true, false] {
            let portal = try f.stub("Apps/\(legacy)/wpsoffice.app", id: "com.kingsoft.wpsoffice.mac", target: real, legacy: legacy)
            let result = await scanner.scanLibraryDirsWithDiagnostics(for: f.app(portal))
            XCTAssertEqual(Set(result.items.map(\.path)), Set(original.map(\.path)))
            XCTAssertNil(result.identityIssue)
        }
    }

    func testIOSLocalMigratedAndRestoredReturnSameContainerData() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        let real = try f.ios("External/bh3.app")
        let portal = try f.stub("Apps/bh3.app", id: "com.miHoYo.bh3", target: real, legacy: true)
        let own = try f.container("com.miHoYo.bh3")
        let scanner = f.scanner()
        let local = await scanner.scanLibraryDirs(for: f.app(real))
        let migrated = await scanner.scanLibraryDirs(for: f.app(portal))
        XCTAssertTrue(local.contains { $0.path.standardizedFileURL.path == own.standardizedFileURL.path })
        XCTAssertEqual(Set(migrated.map(\.path)), Set(local.map(\.path)))
        // Reproduce the restored directory layout without performing a real migration.
        try f.fm.removeItem(at: portal)
        try f.fm.copyItem(at: real, to: portal)
        let restored = await scanner.scanLibraryDirsWithDiagnostics(for: f.app(portal))
        XCTAssertEqual(Set(restored.items.map(\.path)), Set(local.map(\.path)))
        XCTAssertNil(restored.identityIssue)
    }

    func testWholeAppLinksAndDeepContentsKeepContainerAssociations() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        let native = try f.native("External/Native.app", id: "com.example.native")
        let ios = try f.ios("External/bh3.app")
        let nativeData = try f.container("com.example.native")
        let iosData = try f.container("com.miHoYo.bh3")
        for (index, pair) in [(native, nativeData), (ios, iosData)].enumerated() {
            let link = f.root.appendingPathComponent("Link\(index).app")
            try f.fm.createSymbolicLink(atPath: link.path, withDestinationPath: "External/\(pair.0.lastPathComponent)")
            let result = await f.scanner().scanLibraryDirsWithDiagnostics(for: f.app(link))
            XCTAssertTrue(result.items.contains { $0.path.standardizedFileURL.path == pair.1.standardizedFileURL.path })
            XCTAssertNil(result.identityIssue)
        }
        let deep = try f.directory("Deep.app")
        try f.fm.createSymbolicLink(atPath: deep.appendingPathComponent("Contents").path,
                                   withDestinationPath: "../External/Native.app/Contents")
        let result = await f.scanner().scanLibraryDirs(for: f.app(deep))
        XCTAssertTrue(result.contains { $0.path.standardizedFileURL.path == nativeData.standardizedFileURL.path })
    }

    func testOfflineNameFallbackPreservesSupportButRequiresResolvedContainerIdentity() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        let target = f.root.appendingPathComponent("External/wpsoffice.app")
        let portal = try f.stub("Apps/wpsoffice.app", id: "com.kingsoft.wpsoffice.mac", target: target)
        let data = try f.container("com.kingsoft.wpsoffice.mac")
        let support = try f.directory("Home/Library/Application Support/wpsoffice")
        let scanner = f.scanner()
        let offline = await scanner.scanLibraryDirsWithDiagnostics(for: f.app(portal))
        XCTAssertTrue(offline.items.contains { $0.path.standardizedFileURL.path == support.standardizedFileURL.path },
                      "Non-container name fallback remains available while the real app is offline")
        XCTAssertFalse(offline.items.contains { $0.path.standardizedFileURL.path == data.standardizedFileURL.path },
                       "An ordinary sandbox container requires a resolved application identity")
        XCTAssertEqual(offline.identityIssue?.reason, .realAppUnavailable)
        XCTAssertTrue(offline.readIssues.isEmpty, "Identity failure is not a directory permission error")
        _ = try f.native("External/wpsoffice.app", id: "com.kingsoft.wpsoffice.mac")
        let online = await scanner.scanLibraryDirsWithDiagnostics(for: f.app(portal))
        XCTAssertTrue(online.items.contains { $0.path.standardizedFileURL.path == data.standardizedFileURL.path })
        XCTAssertTrue(online.items.contains { $0.path.standardizedFileURL.path == support.standardizedFileURL.path })
        XCTAssertNil(online.identityIssue)
    }

    func testOfflineShortNamedStubFindsDataAfterTargetReturns() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        let target = f.root.appendingPathComponent("External/鸣潮.app")
        let portal = try f.stub("Apps/鸣潮.app", id: "com.kurogame.mingchao", target: target)
        let data = try f.container("com.kurogame.mingchao")
        _ = try f.container("com.unrelated.stubgame")
        let scanner = f.scanner()
        let offline = await scanner.scanLibraryDirsWithDiagnostics(for: f.app(portal))
        XCTAssertTrue(offline.items.isEmpty)
        XCTAssertNotNil(offline.identityIssue)
        _ = try f.native("External/鸣潮.app", id: "com.kurogame.mingchao")
        let online = await scanner.scanLibraryDirsWithDiagnostics(for: f.app(portal))
        XCTAssertTrue(online.items.contains { $0.path.standardizedFileURL.path == data.standardizedFileURL.path })
        XCTAssertFalse(online.items.contains { $0.path.path.contains("unrelated") })
        XCTAssertNil(online.identityIssue)
    }

    func testShortNamesRetainPrefixFallbackWithoutSubstringOvermatching() async throws {
        for name in ["bh3", "QQ"] {
            let f = try IdentityFixture()
            defer { f.cleanup() }
            let app = try f.directory("Apps/\(name).app")
            let own = try f.directory("Home/Library/Application Support/\(name)")
            _ = try f.directory("Home/Library/Application Support/com.unrelated.\(name)tools")
            let result = await f.scanner().scanLibraryDirsWithDiagnostics(for: f.app(app))
            XCTAssertEqual(result.items.map { $0.path.standardizedFileURL.path }, [own.standardizedFileURL.path])
            XCTAssertEqual(result.identityIssue?.reason, .missingInfoPlist)
        }
    }

    func testMalformedPlistKeepsNameFallbackAndReportsIdentityFailure() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        let app = try f.native("Apps/Example.app", id: "com.example.game")
        try Data("broken".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let own = try f.directory("Home/Library/Application Support/Example")
        let result = await f.scanner().scanLibraryDirsWithDiagnostics(for: f.app(app))
        XCTAssertEqual(result.items.map { $0.path.standardizedFileURL.path }, [own.standardizedFileURL.path])
        XCTAssertEqual(result.identityIssue?.reason, .invalidInfoPlist)
    }

    func testResolvedEmptyApplicationHasNoIdentityFailure() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        let app = try f.native("Apps/Empty.app", id: "com.example.empty")
        let result = await f.scanner().scanLibraryDirsWithDiagnostics(for: f.app(app))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNil(result.identityIssue)
    }

    func testSingleAppFolderUsesBundleURLAndName() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        let folder = try f.directory("Apps/Unrelated Folder")
        let real = try f.native("Apps/Unrelated Folder/Focus.app", id: "com.example.focus")
        let own = try f.container("com.example.focus")
        let nameData = try f.directory("Home/Library/Application Support/Focus")
        var app = f.app(folder)
        app.bundleURL = real
        app.containerKind = .singleAppContainer
        let result = await f.scanner().scanLibraryDirsWithDiagnostics(for: app)
        XCTAssertTrue(result.items.contains { $0.path.standardizedFileURL.path == own.standardizedFileURL.path })
        XCTAssertTrue(result.items.contains { $0.path.standardizedFileURL.path == nameData.standardizedFileURL.path })
        XCTAssertNil(result.identityIssue)
    }

    func testMultiAppFolderRemainsExcludedWithoutIdentityWarning() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        var app = f.app(try f.directory("Apps/Suite"))
        app.isFolder = true
        app.containerKind = .appSuiteFolder
        let result = await f.scanner().scanLibraryDirsWithDiagnostics(for: app)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNil(result.identityIssue)
    }

    func testIOSContainerChildrenKeepMountMigrationRequirement() async throws {
        let f = try IdentityFixture()
        defer { f.cleanup() }
        let app = try f.ios("Apps/bh3.app")
        let own = try f.container("com.miHoYo.bh3")
        let result = await f.scanner().scanLibraryDirs(for: f.app(app))
        let item = try XCTUnwrap(result.first { $0.path.standardizedFileURL.path == own.standardizedFileURL.path })
        XCTAssertTrue(item.isMigratable)
        XCTAssertTrue(item.requiresMountMigration)
    }
}

/// Real filesystem fixtures shared by resolver and scanner integration tests.
struct IdentityFixture {
    let root: URL
    let home: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("AppPortsIdentity-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("Home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func cleanup() { try? fm.removeItem(at: root) }

    func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func plist(_ values: [String: Any], at url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: url)
    }

    func native(_ relative: String, id: String) throws -> URL {
        let url = try directory(relative)
        try plist(["CFBundleIdentifier": id], at: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func ios(_ relative: String, id: String = "com.miHoYo.bh3", link: Bool = true) throws -> URL {
        let outer = try directory(relative)
        let inner = outer.appendingPathComponent("Wrapper/bh3.app")
        try plist(["CFBundleIdentifier": id, "CFBundleSupportedPlatforms": ["iPhoneOS"]],
                  at: inner.appendingPathComponent("Info.plist"))
        if link {
            try fm.createSymbolicLink(atPath: outer.appendingPathComponent("WrappedBundle").path,
                                     withDestinationPath: "Wrapper/bh3.app")
        }
        return outer
    }

    func stub(_ relative: String, id: String, target: URL, legacy: Bool = false) throws -> URL {
        let url = try native(relative, id: id + ".appports.stub")
        if legacy {
            let launcher = url.appendingPathComponent("Contents/MacOS/launcher")
            try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            let escaped = target.path.replacingOccurrences(of: "'", with: "'\\''")
            try "#!/bin/bash\nREAL_APP='\(escaped)'\nexit 99\n".write(to: launcher, atomically: true, encoding: .utf8)
        } else {
            let pathFile = url.appendingPathComponent("Contents/Resources/real_app_path.txt")
            try fm.createDirectory(at: pathFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try target.path.write(to: pathFile, atomically: true, encoding: .utf8)
        }
        return url
    }

    func container(_ identifier: String) throws -> URL {
        let data = home.appendingPathComponent("Library/Containers/\(identifier)/Data/Documents/Payload")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("fixture data".utf8).write(to: data.appendingPathComponent("save.dat"))
        return data
    }

    func app(_ url: URL) -> AppItem {
        AppItem(name: url.lastPathComponent, path: url, status: AppStatus.local)
    }

    func scanner() -> DataDirScanner {
        DataDirScanner(homeDir: home,
                       mountStore: ContainerMountStore(fileURL: root.appendingPathComponent("mounts.plist")),
                       isMountPoint: { _ in false }, isVolumeOnline: { _ in false },
                       isSandboxedApplication: { _ in false })
    }
}
