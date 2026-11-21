import AppKit
import XCTest
@testable import AppPorts

final class TauriUpdateSupportTests: XCTestCase {
    private func plist(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
    }

    func testUnrecognizedApplicationKeepsStandardLaunch() {
        let app = Bundle.main.bundleURL
        XCTAssertNil(TauriUpdateSupport.mode(at: app, info: ["CFBundleExecutable": "AppPorts"]))
        XCTAssertNil(TauriUpdateSupport.mode(at: app, info: [
            "CFBundleExecutable": "../AppPorts", "CSResourcesFileMapped": true, "LSRequiresCarbon": true
        ]))
    }

    func testVersionBoundaryAndMixedUniversalExecutables() {
        func source(_ version: String) -> Data { Data("/tauri-plugin-updater-\(version)/src/updater.rs\0".utf8) }
        let old = source("2.13.1"), new = source("2.13.2")
        XCTAssertEqual(TauriUpdateSupport.pluginMode(in: old), .sameVolumeTemporaryDirectory)
        XCTAssertEqual(TauriUpdateSupport.pluginMode(in: new + source("2.14.1")), .native)
        XCTAssertNil(TauriUpdateSupport.pluginMode(in: old + new))
        XCTAssertNil(TauriUpdateSupport.pluginMode(in: source("2.13.2-beta.1")))
        XCTAssertNil(TauriUpdateSupport.pluginMode(in: old + source("2.13.2-beta.1")))
        XCTAssertNil(TauriUpdateSupport.pluginMode(in: source("3.0.0")))
        XCTAssertNil(TauriUpdateSupport.pluginMode(in: Data("/tauri-2.14.1/src/updater.rs".utf8)))
    }

    func testPortalReusesPrivateDirectoryAndPreservesConflictingEntry() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Sample.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let id = "org.appports.validation.sample"
        XCTAssertNil(TauriUpdateSupport.temporaryDirectory(for: app, identifier: id, create: false))
        let tmp = try XCTUnwrap(TauriUpdateSupport.temporaryDirectory(for: app, identifier: id, create: true))
        XCTAssertEqual(TauriUpdateSupport.temporaryDirectory(for: app, identifier: id, create: false), tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        XCTAssertNil(TauriUpdateSupport.temporaryDirectory(for: app, identifier: id, create: true))
        try fm.removeItem(at: tmp)
        try fm.createSymbolicLink(at: tmp, withDestinationURL: app)
        XCTAssertNil(TauriUpdateSupport.temporaryDirectory(for: app, identifier: id, create: true))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: tmp.path), app.path)
    }

    /// Only preferences and the Dock reload are isolated. The bookmark codec and launches are real.
    private final class DockPins {
        let id: String
        var tiles: [[String: Any]] = []
        init(_ id: String) { self.id = id }

        func pin(_ url: URL) {
            tiles = [
                ["tile-type": "spacer-tile", "GUID": 10],
                ["tile-type": "file-tile", "GUID": 20, "tile-data": [
                    "bundle-identifier": id, "file-label": "My pinned app",
                    "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15]
                ] as [String: Any]],
                ["tile-type": "spacer-tile", "GUID": 30]
            ]
        }

        func service() -> DockShortcutService {
            DockShortcutService(store: .init(read: { self.tiles }, write: { self.tiles = $0 }, isManaged: { false }), reload: {})
        }

        func launchURL(expected: URL, portal: Bool) throws -> URL {
            XCTAssertEqual(tiles.compactMap { $0["GUID"] as? Int }, [10, 20, 30])
            let data = try XCTUnwrap(tiles[1]["tile-data"] as? [String: Any])
            XCTAssertEqual(data["file-label"] as? String, "My pinned app")
            XCTAssertEqual(data["bundle-identifier"] as? String, portal ? id + ".appports.stub" : id)
            let url = try DockShortcutService.Bookmarks.fileSystem.resolve(XCTUnwrap(data["book"] as? Data))
            XCTAssertEqual(url.resolvingSymlinksInPath().path, expected.resolvingSymlinksInPath().path)
            return url
        }
    }

    /// Opt-in fixture runs the actual upstream updater, verifies its signed feed, then exits.
    @MainActor
    func testMigratedTauriUpdaterInstallsAndColdLaunchesFromOrdinaryPortal() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let ext = env["APPPORTS_TAURI_FIXTURE_ROOT"], let local = env["APPPORTS_TAURI_FIXTURE_LOCAL"],
              let evidencePath = env["APPPORTS_TAURI_EVIDENCE"],
              let version = env["APPPORTS_TAURI_PLUGIN_VERSION"] else { throw XCTSkip("Requires the signed Tauri updater fixture on a separate volume") }
        let root = URL(fileURLWithPath: ext, isDirectory: true)
        let evidence = URL(fileURLWithPath: evidencePath, isDirectory: true)
        let localRoot = URL(fileURLWithPath: local, isDirectory: true)
        let app = localRoot.appendingPathComponent("AppPorts Tauri Compatibility Probe.app", isDirectory: true).standardizedFileURL
        let disk = root.appendingPathComponent("external")
        let target = disk.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        let id = "org.appports.validation.tauri20261121"
        let old = try plist(app)
        try XCTSkipUnless(old["CFBundleIdentifier"] as? String == id && old["CFBundleVersion"] as? String == "1.0.0")
        let legacy: Bool
        switch version {
        case "2.10.0", "2.10.1", "2.11.0", "2.12.0", "2.13.0", "2.13.1": legacy = true
        case "2.13.2", "2.13.3", "2.14.0", "2.14.1": legacy = false
        default: return XCTFail("Missing expected launch behavior for fixture version " + version)
        }
        XCTAssertEqual(TauriUpdateSupport.mode(at: app), legacy ? .sameVolumeTemporaryDirectory : .native)
        let scanner = AppScanner(backupDirectoryURL: root.appendingPathComponent("SignatureFacts"), adHocProbe: { _ in false })
        let localApps = await scanner.scanLocalApps(at: localRoot, runningAppURLs: [])
        let item = try XCTUnwrap(localApps.first { $0.path.lastPathComponent == app.lastPathComponent })
        let guardianOff = UpdateRecommendationContext(guardian: .disabled)
        XCTAssertEqual(item.updateRoute.availability(in: guardianOff), .inApp)
        let pins = DockPins(id)
        pins.pin(app)
        let dock = pins.service()
        let service = AppMigrationService(dockShortcutUpdater: { try dock.redirectShortcuts(from: $0, to: $1) },
            dockShortcutRetryUpdater: { try dock.redirectShortcuts(from: $0, to: $1, requiringBundleIdentity: true) },
            transferStore: AppTransferStore(directoryURL: root.appendingPathComponent("Transfers")),
            signatureFactStore: SignatureFactStore(backupDirectoryURL: root.appendingPathComponent("SignatureFacts")))
        try await service.moveAndLink(appToMove: item, destinationURL: target, isRunning: false, lockExternal: false, progressHandler: nil)
        XCTAssertEqual(try plist(app)[TauriUpdateSupport.portalKey] as? Bool == true, legacy)

        _ = try pins.launchURL(expected: legacy ? app : target, portal: legacy)
        if legacy {
            // Users migrated by an older build have a pin pointing directly to the external app.
            pins.pin(target)
            // Simulate an entry made by a previous build, without changing the target or its version.
            let url = app.appendingPathComponent("Contents/Info.plist")
            var oldEntry = try plist(app)
            oldEntry.removeValue(forKey: TauriUpdateSupport.portalKey)
            try PropertyListSerialization.data(fromPropertyList: oldEntry, format: .xml, options: 0).write(to: url)
            let signing = Process()
            signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signing.arguments = ["--force", "--sign", "-", app.path]
            try signing.run()
            signing.waitUntilExit()
            XCTAssertEqual(signing.terminationStatus, 0)
            let before = await scanner.scanLocalApps(at: localRoot, runningAppURLs: [])
            XCTAssertEqual(before.first?.updateRoute, .unknown)
            XCTAssertTrue(service.refreshStubPortal(at: app, from: target))
            XCTAssertEqual(try plist(app)[TauriUpdateSupport.portalKey] as? Bool, true)
        }
        let localAfter = await scanner.scanLocalApps(at: localRoot, runningAppURLs: [])
        let extAfter = await scanner.scanExternalApps(at: disk, localAppsDir: localRoot)
        XCTAssertEqual(localAfter.first?.updateRoute.availability(in: guardianOff), .inApp)
        XCTAssertEqual(extAfter.first { $0.path.lastPathComponent == app.lastPathComponent }?.updateRoute.availability(in: guardianOff), .inApp)
        let options = NSWorkspace.OpenConfiguration()
        options.activates = false
        let pinnedURL = try pins.launchURL(expected: legacy ? app : target, portal: legacy)
        XCTAssertFalse(try dock.needsRedirect(from: app, to: target))
        _ = try await NSWorkspace.shared.openApplication(at: pinnedURL, configuration: options)
        let installed = evidence.appendingPathComponent("installed.txt")
        let error = evidence.appendingPathComponent("error.txt")
        for _ in 0..<240 {
            if FileManager.default.fileExists(atPath: error.path) { XCTFail(try String(contentsOf: error)); return }
            if FileManager.default.fileExists(atPath: installed.path) { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertEqual(try String(contentsOf: installed), "1.1.0")
        XCTAssertEqual(try plist(target)["CFBundleVersion"] as? String, "1.1.0")
        let first = try XCTUnwrap(launchRecords(evidence).first { $0["version"] as? String == "1.0.0" })
        let temporary = try XCTUnwrap(first["tmp"] as? String)
        XCTAssertEqual(temporary.contains(".appports-tmp-"), legacy)
        XCTAssertEqual((first["path"] as? String).map { $0.hasPrefix(target.path + "/") }, true)
        let pid = try XCTUnwrap(first["pid"] as? Int32)
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0)
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: options)
        for _ in 0..<100 {
            if let cold = launchRecords(evidence).first(where: { $0["version"] as? String == "1.1.0" }) {
                XCTAssertEqual(cold["path"] as? String, first["path"] as? String)
                XCTAssertNotEqual(cold["pid"] as? Int32, pid)
                XCTAssertTrue(service.refreshStubPortal(at: app, from: target))
                XCTAssertNil(try plist(app)[TauriUpdateSupport.portalKey])
                XCTAssertEqual(try plist(app)["CFBundleVersion"] as? String, "1.1.0")
                _ = try pins.launchURL(expected: target, portal: false)
                let coldPID = try XCTUnwrap(cold["pid"] as? Int32)
                for _ in 0..<100 where kill(coldPID, 0) == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
                let current = await scanner.scanExternalApps(at: disk, localAppsDir: localRoot)
                let externalApp = try XCTUnwrap(current.first { $0.path.lastPathComponent == app.lastPathComponent })
                _ = try await service.moveBack(app: externalApp, localDestinationURL: app, progressHandler: nil)
                _ = try pins.launchURL(expected: app, portal: false)
                XCTAssertEqual(try plist(app)["CFBundleIdentifier"] as? String, id)
                XCTAssertEqual(try plist(app)["CFBundleVersion"] as? String, "1.1.0")
                return
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTFail("The original portal did not start the updated app")
    }

    private func launchRecords(_ root: URL) -> [[String: Any]] {
        let paths = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return paths.filter { $0.lastPathComponent.hasPrefix("launch-") && $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}
