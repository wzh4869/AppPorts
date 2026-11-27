import Foundation
import XCTest
@testable import AppPorts

final class HomebrewCaskRoutingTests: XCTestCase {
    private var root: URL!
    private var cask: URL!
    private var local: URL!
    private var routed: URL!
    private var source: URL!
    private var config: URL!
    private var receipt: URL!
    private var metadata: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BrewRouting-" + UUID().uuidString)
        cask = root.appendingPathComponent("Caskroom/example")
        local = root.appendingPathComponent("Custom/Example.app")
        routed = root.appendingPathComponent("Disk/Entry/Example.app")
        source = cask.appendingPathComponent("1/Example Source.app")
        config = cask.appendingPathComponent(".metadata/config.json")
        receipt = cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
        metadata = cask.appendingPathComponent(".metadata/1/20261127/Casks/example.json")
        let fm = FileManager.default
        for dir in [source.deletingLastPathComponent(), metadata.deletingLastPathComponent(), local!, routed!] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: source.path, withDestinationPath: local.path)
        try write(["default": ["appdir": local.deletingLastPathComponent().path], "env": [:],
                   "explicit": ["languages": ["en"]]], config)
        try write(["source": ["version": "1"], "uninstall_artifacts": [["app": ["Example Source.app", ["target": "Example.app"]]]]], receipt)
        try write([:], metadata)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ object: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    private func install() throws -> HomebrewCaskInstallation {
        try XCTUnwrap(HomebrewCaskInstallation.load(cask))
    }

    func testRetriedHalfRegistrationAndExactInheritedSettingRestoration() throws {
        let fm = FileManager.default
        // The old intent already replaced the version link; Homebrew still remembers the local appdir.
        try fm.removeItem(at: source)
        try fm.createSymbolicLink(atPath: source.path, withDestinationPath: routed.path)
        try install().redirect(original: local, routed: routed, originalExplicit: nil, restoring: false)
        XCTAssertEqual(try install().installedTarget?.path, routed.path)
        try install().redirect(original: local, routed: routed, originalExplicit: nil, restoring: true)
        let restored = try install()
        XCTAssertNil(restored.explicitDirectory)
        XCTAssertEqual(restored.installedTarget?.path, local.path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: source.path), local.path)
        XCTAssertEqual((restored.config["explicit"] as? [String: Any])?["languages"] as? [String], ["en"])
    }

    func testLocalReceiptKeySurvivesDeletionAndTheSystemTemporaryDirectoryAlias() throws {
        let app = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("BrewRouting-" + UUID().uuidString + ".app")
        let alias = URL(fileURLWithPath: "/tmp").appendingPathComponent(app.lastPathComponent)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let key = HomebrewCaskRouting.localPath(app)
        try FileManager.default.removeItem(at: app)
        XCTAssertEqual(HomebrewCaskRouting.localPath(alias), key)
        XCTAssertEqual(HomebrewCaskRouting.localPath(app), key)
    }

    func testRestoresStagingLinkRemovedByOfflineUpgrade() throws {
        try install().redirect(original: local, routed: routed, originalExplicit: nil, restoring: false)
        try FileManager.default.removeItem(at: source)
        try install().redirect(original: local, routed: routed, originalExplicit: nil, restoring: true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), local.path)
        XCTAssertNil(try install().explicitDirectory)
    }

    func testRefusesNewConfigAndForeignLinkWithoutChangingThem() throws {
        let staged = try install()
        let before = try Data(contentsOf: config)
        try write(["explicit": ["appdir": "/elsewhere"]], config)
        XCTAssertThrowsError(try staged.redirect(original: local, routed: routed, originalExplicit: nil, restoring: false))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), local.path)
        try before.write(to: config)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "/unrelated")
        XCTAssertThrowsError(try install().redirect(original: local, routed: routed, originalExplicit: nil, restoring: false))
        XCTAssertEqual(try Data(contentsOf: config), before)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), "/unrelated")
    }

    func testSkipsMultipleApplicationsInstallersAndSymlinkedVersionDirectories() throws {
        try write(["artifacts": [["app": ["Example Source.app"]], ["pkg": ["Example.pkg"]]]], metadata)
        XCTAssertNil(try HomebrewCaskInstallation.load(cask))
        try write([:], metadata)
        try write(["source": ["version": "1"], "uninstall_artifacts": [["app": ["A.app"]], ["app": ["B.app"]]]], receipt)
        XCTAssertNil(try HomebrewCaskInstallation.load(cask))
        try write(["source": ["version": "1"], "uninstall_artifacts": [["app": ["Example Source.app"]]]], receipt)
        let directory = source.deletingLastPathComponent()
        let other = root.appendingPathComponent("unrelated")
        try FileManager.default.moveItem(at: directory, to: other)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: other)
        XCTAssertNil(try HomebrewCaskInstallation.load(cask))
    }
}
