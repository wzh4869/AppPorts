import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

@MainActor
final class FullDiskAccessGuideTests: XCTestCase {
    func testGuideStaysBelowSettingsAndMovesAboveWhenNecessary() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let settings = NSRect(x: 400, y: 250, width: 640, height: 600)
        let below = FullDiskAccessGuide.attachedFrame(to: settings, visibleFrame: screen)
        XCTAssertEqual(below.maxY, settings.minY - 10)
        XCTAssertEqual(below.width, settings.width)
        let lowSettings = NSRect(x: 400, y: 20, width: 640, height: 600)
        let above = FullDiskAccessGuide.attachedFrame(to: lowSettings, visibleFrame: screen)
        XCTAssertEqual(above.minY, lowSettings.maxY + 10)
        XCTAssertTrue(screen.contains(above))
    }

    func testGuideClampsToTheSelectedDisplay() {
        let screen = NSRect(x: -1920, y: 100, width: 1920, height: 1080)
        for x in [-2200.0, -200.0] {
            let settings = NSRect(x: x, y: 400, width: 640, height: 600)
            XCTAssertTrue(screen.contains(FullDiskAccessGuide.attachedFrame(to: settings, visibleFrame: screen)))
        }
    }

    func testApplicationDragPublishesAFileURLWithoutChangingPermissionState() throws {
        let url = URL(fileURLWithPath: "/Applications/AppPorts.app")
        var completions = 0
        let view = PermissionApplicationDragView(applicationURL: url, onDragEnded: { _ in completions += 1 })
        view.frame = NSRect(x: 0, y: 0, width: 72, height: 72)
        let item = view.draggingItem()
        let writer = try XCTUnwrap(item.item as? NSPasteboardWriting)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([writer]))
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])
        XCTAssertEqual(urls, [url])
        XCTAssertEqual(completions, 0)
    }

    func testRenderGuideInBothAppearancesAndLanguages() async throws {
        guard let output = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"] else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT for permission guide visual review")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalLanguage = LanguageManager.shared.language
        defer { LanguageManager.shared.language = originalLanguage }
        for language in ["zh-Hans", "en"] {
            LanguageManager.shared.language = language
            for dark in [false, true] {
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let host = NSHostingView(rootView: FullDiskAccessGuideView(applicationURL: Bundle.main.bundleURL,
                    onDragEnded: { _ in XCTFail("Rendering must not perform a drag") })
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: 480, height: FullDiskAccessGuide.panelSize.height),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                host.frame = NSRect(x: 0, y: 0, width: 480, height: FullDiskAccessGuide.panelSize.height)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 150_000_000)
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                try png.write(to: directory.appendingPathComponent("permission-\(language)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
