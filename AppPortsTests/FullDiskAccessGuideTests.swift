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

    func testGuideOverlaysTheBottomOfANearlyFullHeightSettingsWindow() {
        // Reported layout: no room above or below the window on a 900-point display.
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let settings = NSRect(x: 362, y: 10, width: 715, height: 860)
        let frame = FullDiskAccessGuide.attachedFrame(to: settings, visibleFrame: screen)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.minY, settings.minY + 12)
        XCTAssertEqual(frame.minX, settings.minX)
        XCTAssertFalse(frame.intersects(Self.titleBar(of: settings)))
    }

    func testGuideNeverCoversTheSettingsTitleBar() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1280, height: 775),
            NSRect(x: 0, y: 0, width: 1440, height: 875),
            NSRect(x: -1920, y: 100, width: 1920, height: 1055)
        ]
        for screen in screens {
            for width in [480.0, 715.0] {
                for height in stride(from: 320.0, through: screen.height, by: 23) {
                    for offset in stride(from: 0.0, through: screen.height - height, by: 29) {
                        let settings = NSRect(x: screen.minX + 100, y: screen.minY + offset, width: width, height: height)
                        let frame = FullDiskAccessGuide.attachedFrame(to: settings, visibleFrame: screen)
                        XCTAssertTrue(screen.contains(frame), "\(frame) leaves \(screen) for \(settings)")
                        XCTAssertFalse(frame.intersects(Self.titleBar(of: settings)), "\(frame) covers the title bar of \(settings)")
                    }
                }
            }
        }
    }

    /// System Settings draws its title bar, window controls and toolbar in the top 52 points.
    private static func titleBar(of window: NSRect) -> NSRect {
        NSRect(x: window.minX, y: window.maxY - 52, width: window.width, height: 52)
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
        for language in ["zh-Hans", "en", "de", "fr", "ja", "ar"] {
            LanguageManager.shared.language = language
            for dark in [false, true] {
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let host = NSHostingView(rootView: FullDiskAccessGuideView(applicationURL: Bundle.main.bundleURL,
                    onDragEnded: { _ in XCTFail("Rendering must not perform a drag") })
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight))
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
