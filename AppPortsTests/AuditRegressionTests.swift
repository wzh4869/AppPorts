import Darwin
import Foundation
import Testing
@testable import AppPorts

struct AuditRegressionTests {
    @Test("FolderMonitor closes descriptors on repeated start, stop, and deallocation")
    func folderMonitorClosesFileDescriptors() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderMonitorTest-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tracker = DescriptorCloseTracker()
        do {
            let monitor = FolderMonitor(url: root) { fd, rc in
                tracker.record(fd: fd, returnCode: rc)
            }
            for _ in 0..<25 {
                monitor.startMonitoring(onChange: {})
            }
            // Leave the 25th monitor active when `monitor` leaves scope so `deinit`
            // cancels it and `cancelHandler` closes the descriptor after `self` is gone.
        }
        for _ in 0..<30 {
            if tracker.closedCount == 25 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(tracker.closedCount == 25)
        #expect(tracker.failedCount == 0)
    }

    @Test("DurableFileIO root entry exclusions apply only at the root directory", .enabled(if: getuid() != 0))
    func syncTreeExclusionsApplyOnlyAtRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableSyncExclusions-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let rootExcluded = root.appendingPathComponent(".Spotlight-V100")
        let nestedDir = root.appendingPathComponent("Nested")
        let nestedSameName = nestedDir.appendingPathComponent(".Spotlight-V100")
        try FileManager.default.createDirectory(at: rootExcluded, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedSameName, withIntermediateDirectories: true)
        defer {
            _ = chmod(rootExcluded.path, 0o700)
            _ = chmod(nestedSameName.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }

        // Unreadable root excluded directory is skipped cleanly.
        #expect(chmod(rootExcluded.path, 0o000) == 0)
        try DurableFileIO.syncTree(at: root, excludingRootEntries: [".Spotlight-V100"])

        // Unreadable nested directory with the same name must NOT be skipped.
        #expect(chmod(nestedSameName.path, 0o000) == 0)
        #expect(throws: (any Error).self) {
            try DurableFileIO.syncTree(at: root, excludingRootEntries: [".Spotlight-V100"])
        }
    }

    @Test("CustomDirValidator rejects external symlink escaping into home or local directory")
    func customDirValidatorRejectsSymlinkIntoHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomDirSymlink-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let fakeHome = root.appendingPathComponent("Home")
        let insideHome = fakeHome.appendingPathComponent("InsideHome")
        let externalMount = root.appendingPathComponent("Volumes/ExternalDrive")
        let sneakLink = externalMount.appendingPathComponent("SneakIntoHome")
        try FileManager.default.createDirectory(at: insideHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalMount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createSymbolicLink(at: sneakLink, withDestinationURL: insideHome)

        #expect(throws: CustomDirValidationError.externalInsideHome) {
            try CustomDirValidator.validateExternalBaseDirectory(sneakLink, homeURL: fakeHome)
        }
    }

    @Test("SignatureSnapshot rejects dangling symlinks escaping the bundle root")
    func validateLinksForSigningRejectsDanglingExternalSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DanglingSignLink-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let app = root.appendingPathComponent("Sample.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Dangling external absolute symlink must be rejected before codesign runs.
        try FileManager.default.createSymbolicLink(
            atPath: resources.appendingPathComponent("escape-abs").path,
            withDestinationPath: root.appendingPathComponent("nonexistent-outside-secret").path
        )
        #expect(throws: (any Error).self) {
            try SignatureSnapshot.validateLinksForSigning(in: app)
        }

        try FileManager.default.removeItem(at: resources.appendingPathComponent("escape-abs"))

        // Dangling relative symlink escaping `../../outside` must also be rejected.
        try FileManager.default.createSymbolicLink(
            atPath: resources.appendingPathComponent("escape-rel").path,
            withDestinationPath: "../../../nonexistent-outside"
        )
        #expect(throws: (any Error).self) {
            try SignatureSnapshot.validateLinksForSigning(in: app)
        }
    }

    @Test("PortalImageLaunchPreparation.verifyLink accepts both regular plist files and directories")
    func verifyLinkAcceptsRegularPlistFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerifyLinkFile-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let localDir = root.appendingPathComponent("Preferences")
        let externalDir = root.appendingPathComponent("ImageMount/Preferences")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetPlist = externalDir.appendingPathComponent("org.example.app.plist")
        try Data("plist-bytes".utf8).write(to: targetPlist)
        let localLink = localDir.appendingPathComponent("org.example.app.plist")
        try FileManager.default.createSymbolicLink(atPath: localLink.path, withDestinationPath: targetPlist.path)

        let identity = try DataPathIdentity.capture(targetPlist)
        let record = ManagedDataLinkRecord(
            operationID: UUID(),
            originalPath: localLink.path,
            destinationPath: targetPlist.path,
            destinationIdentity: identity,
            appName: "Example",
            bundleIdentifier: "org.example.app",
            dataDirType: DataDirType.preferences.rawValue
        )
        let access = AppLibraryImageFileAccess(inspect: { try AppLibraryImageFileAccess.evaluate($0) })
        try await PortalImageLaunchPreparation.verifyLink(record, files: access)
    }

    @Test("ShipItUpdateEventMonitor canonicalizes nonexistent watchedFiles under symlinked paths")
    func shipItEventMonitorDetectsWatchedFileCreatedLaterUnderSymlink() async throws {
        let realRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShipItSymlinkMonitor-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let realCaches = realRoot.appendingPathComponent("Caches")
        let realLedgerDir = realRoot.appendingPathComponent("Ledger")
        let aliasRoot = realRoot.appendingPathComponent("AliasToRoot")
        try FileManager.default.createDirectory(at: realCaches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realLedgerDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: realRoot)
        defer { try? FileManager.default.removeItem(at: realRoot) }

        // Pass watched file via symlinked parent BEFORE the file itself exists!
        let nonexistentWatchedViaAlias = aliasRoot.appendingPathComponent("Ledger/app-transfers.json")
        let counter = EventCounter()
        let monitor = ShipItUpdateEventMonitor(
            caches: aliasRoot.appendingPathComponent("Caches"),
            latency: 0.05,
            watchedFiles: [nonexistentWatchedViaAlias],
            onChange: { Task { await counter.increment() } }
        )
        #expect(monitor.start(identifiers: ["org.example.app"]))
        defer { monitor.stop() }

        try await Task.sleep(nanoseconds: 150_000_000)
        try Data("{}".utf8).write(to: realLedgerDir.appendingPathComponent("app-transfers.json"))

        for _ in 0..<30 {
            if await counter.value > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(await counter.value > 0, "FSEvents on realpath must match watchedFiles passed via symlinked path before creation")
    }

    @Test("AppScanner reads metadata and marks Wrapper/*.app bundles as iOS App Store apps")
    func appScannerRecognizesWrapperIOSApp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppScannerWrapperIOS-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let appsDir = root.appendingPathComponent("Applications")
        let outerApp = appsDir.appendingPathComponent("MobileGame.app")
        let innerApp = outerApp.appendingPathComponent("Wrapper/Payload.app")
        try FileManager.default.createDirectory(at: innerApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.mobilegame",
            "CFBundleName": "MobileGame",
            "CFBundleShortVersionString": "2.4.0",
            "UIDeviceFamily": [1, 2],
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: innerApp.appendingPathComponent("Info.plist"))

        let scanner = AppScanner(backupDirectoryURL: root.appendingPathComponent("Backups"), adHocProbe: { _ in false })
        let items = await scanner.scanLocalApps(at: appsDir, runningAppURLs: [])
        let scanned = try #require(items.first)
        #expect(scanned.isIOSApp)
        #expect(scanned.isAppStoreApp)
    }
}

private final class DescriptorCloseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = 0
    private var failed = 0

    func record(fd: Int32, returnCode: Int32) {
        lock.withLock {
            if returnCode == 0 {
                closed += 1
            } else {
                failed += 1
            }
        }
    }

    var closedCount: Int { lock.withLock { closed } }
    var failedCount: Int { lock.withLock { failed } }
}

private actor EventCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
