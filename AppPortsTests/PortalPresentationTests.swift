import XCTest
@testable import AppPorts

final class PortalPresentationTests: XCTestCase {
    func testCopiesLocalizedNamesAndModernAndTraditionalIconsWithoutChangingOriginal() throws {
        try withFixture { source, destination in
            let info: [String: Any] = ["CFBundleIdentifier": "org.example.app", "CFBundleExecutable": "original", "CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon", "SUFeedURL": "https://example.org", "CFBundleShortVersionString": "1"]
            try writePlist(info, to: source.appendingPathComponent("Info.plist"))
            try put(Data("icon".utf8), at: source.appendingPathComponent("Resources/AppIcon.icns"))
            try put(Data("assets".utf8), at: source.appendingPathComponent("Resources/Assets.car"))
            try writePlist(["CFBundleDisplayName": "中文名称", "CFBundleExecutable": "wrong", "NSCameraUsageDescription": "irrelevant"], to: source.appendingPathComponent("Resources/zh-Hans.lproj/InfoPlist.strings"))
            _ = try PortalPresentation.write(from: source, to: destination)
            let result = try readPlist(destination.appendingPathComponent("Info.plist"))
            XCTAssertEqual(result["CFBundleIdentifier"] as? String, "org.example.app.appports.stub")
            XCTAssertEqual(result["CFBundleExecutable"] as? String, "launcher")
            XCTAssertEqual(result["AppPortsTargetBundleIdentifier"] as? String, "org.example.app")
            XCTAssertEqual(result["AppPortsTargetVolumeUUID"] as? String, try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            XCTAssertEqual(result["LSUIElement"] as? Bool, true)
            XCTAssertNil(result["SUFeedURL"])
            XCTAssertEqual(result["CFBundleIconName"] as? String, "AppIcon")
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Resources/Assets.car")), Data("assets".utf8))
            let names = try readPlist(destination.appendingPathComponent("Resources/zh-Hans.lproj/InfoPlist.strings"))
            XCTAssertEqual(names["CFBundleDisplayName"] as? String, "中文名称")
            XCTAssertNil(names["CFBundleExecutable"])
            XCTAssertNil(names["NSCameraUsageDescription"])
            XCTAssertEqual(try readPlist(source.appendingPathComponent("Info.plist"))["CFBundleExecutable"] as? String, "original")
        }
    }

    func testMissingModernAssetsFallsBackAndRejectsEscapingIconPath() throws {
        try withFixture { source, destination in
            try writePlist(["CFBundleIconFile": "../secret", "CFBundleIconName": "Missing"], to: source.appendingPathComponent("Info.plist"))
            let warnings = try PortalPresentation.write(from: source, to: destination)
            let result = try readPlist(destination.appendingPathComponent("Info.plist"))
            XCTAssertNil(result["CFBundleIconFile"])
            XCTAssertNil(result["CFBundleIconName"])
            XCTAssertFalse(warnings.isEmpty)
        }
    }

    func testCopiesInternalSymlinkAsRealFileButRejectsExternalSymlink() throws {
        try withFixture { source, destination in
            try writePlist(["CFBundleIconFile": "Link.icns", "CFBundleIconName": "Modern"], to: source.appendingPathComponent("Info.plist"))
            try put(Data("safe".utf8), at: source.appendingPathComponent("Resources/Original.icns"))
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Resources/Link.icns"), withDestinationURL: source.appendingPathComponent("Resources/Original.icns"))
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Resources/Assets.car"), withDestinationURL: source.appendingPathComponent("Info.plist"))
            _ = try PortalPresentation.write(from: source, to: destination)
            let icon = destination.appendingPathComponent("Resources/Link.icns")
            XCTAssertEqual(try Data(contentsOf: icon), Data("safe".utf8))
            XCTAssertFalse(try icon.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
            XCTAssertNil(try readPlist(destination.appendingPathComponent("Info.plist"))["CFBundleIconName"])
        }
    }

    func testRefreshRemovesObsoleteLocalizedNamesAndIconsButPreservesLauncherTarget() throws {
        try withFixture { source, destination in
            try writePlist(["CFBundleIdentifier": "org.example.app"], to: source.appendingPathComponent("Info.plist"))
            try writePlist(["CFBundleIconFile": "Old.icns"], to: destination.appendingPathComponent("Info.plist"))
            try put(Data("old".utf8), at: destination.appendingPathComponent("Resources/Old.icns"))
            try writePlist(["CFBundleDisplayName": "旧名称"], to: destination.appendingPathComponent("Resources/zh-Hans.lproj/InfoPlist.strings"))
            try put(Data("/Volumes/External/App.app".utf8), at: destination.appendingPathComponent("Resources/real_app_path.txt"))
            _ = try PortalPresentation.write(from: source, to: destination)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Resources/Old.icns").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Resources/zh-Hans.lproj/InfoPlist.strings").path))
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Resources/real_app_path.txt"), encoding: .utf8), "/Volumes/External/App.app")
        }
    }

    func testTraditionalIconDoesNotKeepUnbackedModernReference() throws {
        for hasTraditionalReference in [true, false] {
            try withFixture { source, destination in
                var info: [String: Any] = ["CFBundleIconName": "AppIcon"]
                if hasTraditionalReference { info["CFBundleIconFile"] = "AppIcon" }
                try writePlist(info, to: source.appendingPathComponent("Info.plist"))
                try put(Data("icon".utf8), at: source.appendingPathComponent("Resources/AppIcon.icns"))
                _ = try PortalPresentation.write(from: source, to: destination)
                let result = try readPlist(destination.appendingPathComponent("Info.plist"))
                XCTAssertNil(result["CFBundleIconName"])
                XCTAssertEqual(result["CFBundleIconFile"] as? String, hasTraditionalReference ? "AppIcon" : "AppIcon.icns")
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Resources/AppIcon.icns")), Data("icon".utf8))
            }
        }
    }

    func testUnrelatedNamedFileOrDirectoryCannotBackModernIconReference() throws {
        for resource in ["AppIcon", "Assets.car"] {
            try withFixture { source, destination in
                try writePlist(["CFBundleIconName": "AppIcon"], to: source.appendingPathComponent("Info.plist"))
                if resource == "AppIcon" {
                    try put(Data("unrelated".utf8), at: source.appendingPathComponent("Resources/AppIcon"))
                } else {
                    try FileManager.default.createDirectory(at: source.appendingPathComponent("Resources/Assets.car"), withIntermediateDirectories: true)
                }
                _ = try PortalPresentation.write(from: source, to: destination)
                XCTAssertNil(try readPlist(destination.appendingPathComponent("Info.plist"))["CFBundleIconName"])
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Resources/" + resource).path))
            }
        }
    }

    func testNamedIconPackageKeepsModernReferenceWithoutAssetCatalog() throws {
        try withFixture { source, destination in
            try writePlist(["CFBundleIconName": "AppIcon"], to: source.appendingPathComponent("Info.plist"))
            try put(Data("{}".utf8), at: source.appendingPathComponent("Resources/AppIcon.icon/icon.json"))
            _ = try PortalPresentation.write(from: source, to: destination)
            XCTAssertEqual(try readPlist(destination.appendingPathComponent("Info.plist"))["CFBundleIconName"] as? String, "AppIcon")
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Resources/AppIcon.icon/icon.json").path))
        }
    }

    func testSameVersionOldPortalNeedsRepair() {
        let external: [String: Any] = ["CFBundleVersion": "42", "CFBundleShortVersionString": "1"]
        XCTAssertTrue(PortalPresentation.needsRefresh(local: external, external: external))
        var current = external
        current[PortalPresentation.versionKey] = PortalPresentation.formatVersion
        XCTAssertFalse(PortalPresentation.needsRefresh(local: current, external: external))
    }

    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("External/Contents")
        let destination = root.appendingPathComponent("Staged/Contents")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try body(source, destination)
    }

    private func put(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func writePlist(_ info: [String: Any], to url: URL) throws {
        try put(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), at: url)
    }
    private func readPlist(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
}
