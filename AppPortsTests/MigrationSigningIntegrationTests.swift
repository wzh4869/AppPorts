import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Migration and signing integration")
struct MigrationSigningIntegrationTests {
    @Test("Moving a signed app preserves its real signature and metadata", .bug("https://github.com/wzh4869/AppPorts/issues/59"))
    func migrationPreservesSignedApplication() async throws {
        let workspace = try IntegrationWorkspace()
        defer { workspace.cleanup() }
        let localApp = workspace.localAppsURL.appendingPathComponent("Signed Chat.app")
        let externalApp = workspace.externalRootURL.appendingPathComponent(localApp.lastPathComponent)
        try makeSignedApplication(at: localApp, workspace: workspace)

        let executablePath = "Contents/MacOS/Chat"
        let executable = try Data(contentsOf: localApp.appendingPathComponent(executablePath))
        let resourcesPath = "Contents/Resources"
        let metadata = Data("preserve application metadata".utf8)
        let whereFroms = try PropertyListSerialization.data(
            fromPropertyList: ["https://example.invalid/chat-fixture"], format: .binary, options: 0
        )
        try setAttribute("com.appports.tests.metadata", value: metadata, at: localApp)
        try setAttribute("com.appports.tests.metadata", value: metadata, at: localApp.appendingPathComponent(resourcesPath))
        try setAttribute("com.apple.metadata:kMDItemWhereFroms", value: whereFroms, at: localApp.appendingPathComponent(executablePath))
        for relativePath in ["", resourcesPath, executablePath, "Contents/Resources/payload.bin"] {
            try setAttribute("com.apple.quarantine", value: Data("0081;00000000;AppPortsTests;".utf8), at: localApp.appendingPathComponent(relativePath))
        }
        try verifySignature(at: localApp)
        try #require(try sandboxEnabled(at: localApp))

        try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
            appToMove: AppItem(name: localApp.lastPathComponent, path: localApp, status: "本地"),
            destinationURL: externalApp,
            isRunning: false,
            progressHandler: nil
        )

        try expectStub(at: localApp, pointingTo: externalApp)
        try verifySignature(at: externalApp)
        try verifySignature(at: externalApp.appendingPathComponent("Contents/Helpers/Chat Helper.app"))
        #expect(try sandboxEnabled(at: externalApp))
        #expect(try Data(contentsOf: externalApp.appendingPathComponent(executablePath)) == executable)
        #expect(try permissions(at: externalApp.appendingPathComponent(executablePath)) == 0o751)
        #expect(try permissions(at: externalApp.appendingPathComponent(resourcesPath)) == 0o750)
        #expect(try readAttribute("com.appports.tests.metadata", at: externalApp) == metadata)
        #expect(try readAttribute("com.appports.tests.metadata", at: externalApp.appendingPathComponent(resourcesPath)) == metadata)
        #expect(try readAttribute("com.apple.metadata:kMDItemWhereFroms", at: externalApp.appendingPathComponent(executablePath)) == whereFroms)
        for relativePath in ["", resourcesPath, executablePath, "Contents/Resources/payload.bin"] {
            #expect(try readAttribute("com.apple.quarantine", at: externalApp.appendingPathComponent(relativePath)) == nil)
        }
    }

    @Test("Signing a migrated sandboxed Sparkle app is refused and keeps its entitlements and locks", .bug("https://github.com/wzh4869/AppPorts/issues/59"))
    func signingMigratedLockedApplication() async throws {
        let workspace = try IntegrationWorkspace()
        defer { workspace.cleanup() }
        let localApp = workspace.localAppsURL.appendingPathComponent("Locked Chat's.app")
        let externalApp = workspace.externalRootURL.appendingPathComponent(localApp.lastPathComponent)
        let helperPath = "Contents/Helpers/Chat Helper.app"
        try makeSignedApplication(at: localApp, workspace: workspace, hasSparkle: true)
        try #require(try sandboxEnabled(at: localApp))
        try #require(try sandboxEnabled(at: localApp.appendingPathComponent(helperPath)))

        try await AppMigrationService(dockShortcutUpdater: { _, _ in 0 }).moveAndLink(
            appToMove: AppItem(name: localApp.lastPathComponent, path: localApp, status: "本地"),
            destinationURL: externalApp,
            isRunning: false,
            progressHandler: nil
        )
        try expectStub(at: localApp, pointingTo: externalApp)
        let originalLocks = try immutableFlags(in: externalApp)
        try #require(originalLocks.count > 10)
        try #require(originalLocks.values.allSatisfy { $0 }, "The migrated Sparkle bundle must actually be recursively locked")
        let stubExecutable = try Data(contentsOf: localApp.appendingPathComponent("Contents/MacOS/launcher"))
        let externalExecutable = try Data(contentsOf: externalApp.appendingPathComponent("Contents/MacOS/Chat"))
        let backups = workspace.rootURL.appendingPathComponent("SignatureBackups")

        // 沙盒应用的容器访问只靠 entitlements；ad-hoc 重签名会抹掉它们且无法恢复，必须在改动前拒绝。
        let signer = CodeSigner(backupDirectoryURL: backups, allowAdministratorPrompt: false)
        do {
            try await signer.sign(appURL: localApp, bundleIdentifier: nil)
            Issue.record("A migrated sandboxed application must not be ad-hoc re-signed")
        } catch CodeSigner.SigningError.sandboxedApplication(let url) {
            #expect(url.resolvingSymlinksInPath().path == externalApp.resolvingSymlinksInPath().path)
        }

        try verifySignature(at: externalApp)
        try verifySignature(at: externalApp.appendingPathComponent(helperPath))
        #expect(try sandboxEnabled(at: externalApp))
        #expect(try sandboxEnabled(at: externalApp.appendingPathComponent(helperPath)))
        #expect(try immutableFlags(in: externalApp) == originalLocks)
        #expect(try Data(contentsOf: externalApp.appendingPathComponent("Contents/MacOS/Chat")) == externalExecutable)
        #expect(try Data(contentsOf: localApp.appendingPathComponent("Contents/MacOS/launcher")) == stubExecutable)
        #expect(FileManager.default.fileExists(atPath: backups.path) == false)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: externalApp.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Versions/Current").path
        ) == "A")
        try expectStub(at: localApp, pointingTo: externalApp)
    }

    @Test("Chat database and attachments survive application and data migration round trips", .bug("https://github.com/wzh4869/AppPorts/issues/59"))
    func applicationAndChatDataRoundTrip() async throws {
        let workspace = try IntegrationWorkspace()
        defer { workspace.cleanup() }
        let localApp = workspace.localAppsURL.appendingPathComponent("Chat.app")
        let externalApp = workspace.externalRootURL.appendingPathComponent(localApp.lastPathComponent)
        try makeSignedApplication(at: localApp, workspace: workspace)
        let originalExecutable = try Data(contentsOf: localApp.appendingPathComponent("Contents/MacOS/Chat"))

        // This WeChat-shaped path exists entirely inside the test's temporary home.
        let localData = workspace.homeURL.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_fixture"
        )
        let externalDataBase = workspace.externalRootURL.appendingPathComponent("ChatData")
        let externalData = externalDataBase.appendingPathComponent(localData.lastPathComponent)
        let databasePath = "db_storage/Chat.db"
        try FileManager.default.createDirectory(at: localData.appendingPathComponent("db_storage"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localData.appendingPathComponent("attachments/empty"), withIntermediateDirectories: true)
        try queryDatabase(at: localData.appendingPathComponent(databasePath), sql:
            "CREATE TABLE messages (id INTEGER PRIMARY KEY, body TEXT NOT NULL); INSERT INTO messages VALUES (1, '原始聊天内容'), (2, 'attachment');")
        try Data((0..<65_536).map { UInt8($0 % 256) }).write(to: localData.appendingPathComponent("attachments/picture.bin"))
        try Data("hidden state".utf8).write(to: localData.appendingPathComponent(".chat-state"))
        try FileManager.default.createSymbolicLink(atPath: localData.appendingPathComponent("latest-attachment").path, withDestinationPath: "attachments/picture.bin")
        var expectedFiles = try payloadFiles(in: localData)

        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 })
        try await service.moveAndLink(
            appToMove: AppItem(name: localApp.lastPathComponent, path: localApp, status: "本地"),
            destinationURL: externalApp,
            isRunning: false,
            progressHandler: nil
        )
        let mover = DataDirMover(homeDir: workspace.homeURL, store: ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("migration-records.plist")))
        var item = DataDirItem(name: "Chat account", path: localData, type: .containers,
                               priority: .critical, description: "Temporary chat regression fixture")
        try await mover.migrate(item: item, to: externalDataBase, progressHandler: nil)

        try expectSymbolicLink(at: localData, pointingTo: externalData)
        #expect(try payloadFiles(in: externalData) == expectedFiles)
        #expect(try payloadFiles(in: localData) == expectedFiles)
        #expect(FileManager.default.fileExists(atPath: externalData.appendingPathComponent(".appports-link-metadata.plist").path))
        #expect(try queryDatabase(at: localData.appendingPathComponent(databasePath), sql:
            "PRAGMA integrity_check; SELECT count(*) FROM messages;") == "ok\n2\n")

        // A write through the original path must reach the external database and survive restore.
        try queryDatabase(at: localData.appendingPathComponent(databasePath), sql: "INSERT INTO messages VALUES (3, '迁移后新增');")
        expectedFiles[databasePath] = try Data(contentsOf: externalData.appendingPathComponent(databasePath))
        #expect(try queryDatabase(at: externalData.appendingPathComponent(databasePath), sql:
            "SELECT body FROM messages WHERE id = 3;") == "迁移后新增\n")
        #expect(try payloadFiles(in: externalData) == expectedFiles)

        item.status = DataDirStatus.linked
        item.linkedDestination = externalData
        try await mover.restore(item: item, progressHandler: nil)
        #expect(try FileManager.default.attributesOfItem(atPath: localData.path)[.type] as? FileAttributeType == .typeDirectory)
        #expect(try payloadFiles(in: localData) == expectedFiles)
        // Data migration retains the previous copy until explicit verified cleanup.
        #expect(try payloadFiles(in: externalData) == expectedFiles)
        #expect(FileManager.default.fileExists(atPath: localData.appendingPathComponent(".appports-link-metadata.plist").path) == false)
        #expect(FileManager.default.fileExists(atPath: localData.appendingPathComponent("attachments/empty").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: localData.appendingPathComponent("latest-attachment").path) == "attachments/picture.bin")
        #expect(try Data(contentsOf: localData.appendingPathComponent("latest-attachment")) == expectedFiles["attachments/picture.bin"])
        #expect(try queryDatabase(at: localData.appendingPathComponent(databasePath), sql:
            "PRAGMA integrity_check; SELECT count(*) FROM messages;") == "ok\n3\n")

        try await service.moveBack(
            app: AppItem(name: externalApp.lastPathComponent, path: externalApp, status: "已链接"),
            localDestinationURL: localApp,
            progressHandler: nil
        )
        try verifySignature(at: localApp)
        #expect(try sandboxEnabled(at: localApp))
        #expect(try Data(contentsOf: localApp.appendingPathComponent("Contents/MacOS/Chat")) == originalExecutable)
        #expect(FileManager.default.fileExists(atPath: externalApp.path) == false)
        #expect(FileManager.default.fileExists(atPath: localApp.appendingPathComponent("Contents/MacOS/launcher").path) == false)
    }

    private struct IntegrationWorkspace {
        let rootURL: URL
        let externalRootURL: URL
        private let hasSeparateExternalRoot: Bool
        var localAppsURL: URL { rootURL.appendingPathComponent("Applications") }
        var homeURL: URL { rootURL.appendingPathComponent("Home") }

        init() throws {
            let directoryName = "AppPortsSigningIntegration-\(UUID().uuidString)"
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(directoryName)
                .resolvingSymlinksInPath()
            if let externalRoot = ProcessInfo.processInfo.environment["APPPORTS_TEST_EXTERNAL_ROOT"], !externalRoot.isEmpty {
                externalRootURL = URL(fileURLWithPath: externalRoot, isDirectory: true).appendingPathComponent(directoryName)
                hasSeparateExternalRoot = true
            } else {
                externalRootURL = rootURL.appendingPathComponent("External")
                hasSeparateExternalRoot = false
            }
            for directory in [localAppsURL, externalRootURL, homeURL] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func cleanup() {
            // Only remove this test's UUID directories, never the configured external root.
            let directories = [rootURL] + (hasSeparateExternalRoot ? [externalRootURL] : [])
            for directory in directories {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
                process.arguments = ["-R", "nouchg", directory.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    Issue.record("Could not clean integration fixture \(directory.path): \(error)")
                }
            }
        }
    }

    private func makeSignedApplication(at appURL: URL, workspace: IntegrationWorkspace, hasSparkle: Bool = false) throws {
        let identifier = "com.appports.tests.\(UUID().uuidString.lowercased())"
        let entitlementsURL = workspace.rootURL.appendingPathComponent("\(UUID().uuidString)-entitlements.plist")
        try writePlist(["com.apple.security.app-sandbox": true], to: entitlementsURL)
        try makeBundle(at: appURL, executableName: "Chat", identifier: identifier)
        let helperURL = appURL.appendingPathComponent("Contents/Helpers/Chat Helper.app")
        try makeBundle(at: helperURL, executableName: "ChatHelper", identifier: identifier + ".helper")
        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--entitlements", entitlementsURL.path, helperURL.path])

        if hasSparkle {
            let frameworkURL = appURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
            let versionURL = frameworkURL.appendingPathComponent("Versions/A")
            try FileManager.default.createDirectory(at: versionURL.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            try copyMachO(to: versionURL.appendingPathComponent("Sparkle"))
            try writePlist(["CFBundleIdentifier": identifier + ".sparkle", "CFBundleExecutable": "Sparkle",
                            "CFBundlePackageType": "FMWK", "CFBundleVersion": "1"], to: versionURL.appendingPathComponent("Resources/Info.plist"))
            for (path, destination) in [("Versions/Current", "A"), ("Sparkle", "Versions/Current/Sparkle"), ("Resources", "Versions/Current/Resources")] {
                try FileManager.default.createSymbolicLink(atPath: frameworkURL.appendingPathComponent(path).path, withDestinationPath: destination)
            }
            try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", frameworkURL.path])
        }

        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--entitlements", entitlementsURL.path, appURL.path])
        try verifySignature(at: appURL)
    }

    private func makeBundle(at appURL: URL, executableName: String, identifier: String) throws {
        let contents = appURL.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try copyMachO(to: contents.appendingPathComponent("MacOS/\(executableName)"))
        try Data([0, 1, 2, 3, 0xff, 0x80]).write(to: resources.appendingPathComponent("payload.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: resources.path)
        try writePlist(["CFBundleIdentifier": identifier, "CFBundleExecutable": executableName,
                        "CFBundleName": executableName, "CFBundlePackageType": "APPL",
                        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"], to: contents.appendingPathComponent("Info.plist"))
    }

    private func copyMachO(to destination: URL) throws {
        let source = try #require(Bundle.main.url(forResource: "StubLauncherBinary", withExtension: nil))
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: destination.path)
    }

    private func writePlist(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }

    private func verifySignature(at appURL: URL) throws {
        try runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
    }

    private func sandboxEnabled(at appURL: URL) throws -> Bool {
        let result = try runProcess("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", appURL.path])
        guard !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let plist = try PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil)
        let values = try #require(plist as? [String: Any])
        return values["com.apple.security.app-sandbox"] as? Bool == true
    }

    private func expectStub(at localURL: URL, pointingTo externalURL: URL) throws {
        #expect(try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true)
        #expect(try localURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        let path = try String(contentsOf: localURL.appendingPathComponent("Contents/Resources/real_app_path.txt"), encoding: .utf8)
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path == externalURL.resolvingSymlinksInPath().path)
        let executable = localURL.appendingPathComponent("Contents/MacOS/launcher")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        #expect(FileManager.default.fileExists(atPath: localURL.appendingPathComponent("Contents/MacOS/Chat").path) == false)
    }

    private func expectSymbolicLink(at localURL: URL, pointingTo externalURL: URL) throws {
        try #require(try localURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: localURL.path)
        #expect(URL(fileURLWithPath: target, relativeTo: localURL.deletingLastPathComponent()).resolvingSymlinksInPath().path
                == externalURL.resolvingSymlinksInPath().path)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func immutableFlags(in root: URL) throws -> [String: Bool] {
        let paths = [""] + (try FileManager.default.subpathsOfDirectory(atPath: root.path))
        var result: [String: Bool] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            var info = stat()
            try #require(lstat(url.path, &info) == 0)
            result[path] = info.st_flags & UInt32(UF_IMMUTABLE) != 0
        }
        return result
    }

    private func payloadFiles(in root: URL) throws -> [String: Data] {
        let root = URL(fileURLWithPath: root.path).resolvingSymlinksInPath()
        var result: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.lastPathComponent != ".appports-link-metadata.plist" else { continue }
            result[path] = try Data(contentsOf: url)
        }
        return result
    }

    private func setAttribute(_ name: String, value: Data, at url: URL) throws {
        let status = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        try #require(status == 0, "setxattr failed for \(url.path): \(errno)")
    }

    private func readAttribute(_ name: String, at url: URL) throws -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0, errno == ENOATTR { return nil }
        try #require(size >= 0, "getxattr failed for \(url.path): \(errno)")
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        try #require(count == size)
        return data
    }

    @discardableResult
    private func queryDatabase(at url: URL, sql: String) throws -> String {
        try runProcess("/usr/bin/sqlite3", ["-batch", "-noheader", "-init", "/dev/null", url.path, sql]).output
    }

    @discardableResult
    private func runProcess(_ executable: String, _ arguments: [String]) throws -> (output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let outputText = String(decoding: outputData, as: UTF8.self)
        let errorText = String(decoding: errorData, as: UTF8.self)
        try #require(process.terminationStatus == 0, "\(executable) \(arguments.joined(separator: " ")) failed:\n\(errorText)\n\(outputText)")
        return (outputText, errorText)
    }
}
