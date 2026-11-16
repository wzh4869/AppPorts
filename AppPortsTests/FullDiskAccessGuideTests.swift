import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

@MainActor
final class FullDiskAccessGuideTests: XCTestCase {
    func testPermissionSettingsPreparationClearsBindingsBeforeReadingWindows() async throws {
        var dismissed = false
        try await FullDiskAccessGuide.prepareForOpeningSettings(dismiss: {
            XCTAssertTrue(Thread.isMainThread)
            dismissed = true
        }, windows: {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(dismissed)
            return []
        })
    }

    func testPermissionSettingsPreparationDetachesNestedNativeSheets() async throws {
        let frame = NSRect(x: -10_000, y: 0, width: 300, height: 200)
        let windows = (0..<3).map { _ in
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        defer { windows.reversed().forEach { $0.close() } }
        windows[0].beginSheet(windows[1], completionHandler: nil)
        windows[1].beginSheet(windows[2], completionHandler: nil)
        try await FullDiskAccessGuide.prepareForOpeningSettings(dismiss: {}, windows: { [windows[0]] })
        XCTAssertNil(windows[0].attachedSheet)
        XCTAssertNil(windows[1].attachedSheet)
    }

    func testPermissionSettingsPreparationDoesNotRecreateSwiftUISheets() async throws {
        for nested in [false, true] {
            let state = PermissionSheetTestState(nested: nested)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: 600, height: 450),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PermissionSheetTestView(state: state))
            window.orderFront(nil)
            defer { state.settings = false; window.close() }
            let deadline = Date().addingTimeInterval(3)
            while (window.attachedSheet == nil || (nested && window.attachedSheet?.attachedSheet == nil)) && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNotNil(window.attachedSheet)
            if nested { XCTAssertNotNil(window.attachedSheet?.attachedSheet) }
            try await FullDiskAccessGuide.prepareForOpeningSettings(dismiss: {
                state.readiness = false
                state.settings = false
            }, windows: { [window] })
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(state.settings)
            XCTAssertFalse(state.readiness)
        }
    }

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

    func testGuidanceUsesTheSelectedPermissionList() {
        XCTAssertEqual(LaunchReadinessChecker.Item.Action.fullDiskAccess.guideInstruction,
                       "把图标拖入“完全磁盘访问权限”列表，再打开开关。".localized)
        XCTAssertEqual(LaunchReadinessChecker.Item.Action.appManagement.guideInstruction,
                       "把图标拖入“App 管理”列表，再打开开关。".localized)
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

    func testRenderPermissionAttentionControls() async throws {
        guard let output = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"] else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT for permission attention visual review")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalLanguage = LanguageManager.shared.language
        defer { LanguageManager.shared.language = originalLanguage }
        let levels: [LaunchReadinessChecker.Item.Level?] = [nil, .failed, .warning, .ok]
        let attentionItems = [LaunchReadinessChecker.appManagementItem(state: .denied),
                              LaunchReadinessChecker.appManagementItem(state: .unknown)]
        let attention = ["", PermissionReadiness.attentionText(for: [attentionItems[0]]),
                         PermissionReadiness.attentionText(for: [attentionItems[1]]), ""]
        for language in ["zh-Hans", "en", "de", "fr", "ja", "ar"] {
            LanguageManager.shared.language = language
            for dark in [false, true] {
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let host = NSHostingView(rootView: VStack(spacing: 12) {
                    ForEach(levels.indices, id: \.self) { index in
                        HStack {
                            Text(["正在检查…", "需要授权", "待核对", "已就绪"][index].localized)
                                .frame(width: 150, alignment: .leading)
                            PermissionSettingsButton(level: levels[index], attentionText: attention[index]) { XCTFail("Rendering must not open settings") }
                            Spacer()
                            PermissionCheckButton(level: levels[index], attentionText: attention[index]) { XCTFail("Rendering must not open permission checks") }
                        }
                    }
                }.padding(20).background(dark ? Color.black : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight))
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: 400, height: 220),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                host.frame = NSRect(x: 0, y: 0, width: 400, height: 220)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 150_000_000)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("permission-attention-\(language)-\(dark ? "dark" : "light").png"))
            }
        }
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
            for permission in [LaunchReadinessChecker.Item.Action.fullDiskAccess, .appManagement] {
                for dark in [false, true] {
                    let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                    let host = NSHostingView(rootView: FullDiskAccessGuideView(applicationURL: Bundle.main.bundleURL, permission: permission,
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
                    try png.write(to: directory.appendingPathComponent("permission-\(permission == .appManagement ? "app-management" : "full-disk")-\(language)-\(dark ? "dark" : "light").png"))
                    if permission == .appManagement {
                        let states: [AppManagementPermission.State] = [.granted, .denied, .unknown]
                        let card = NSHostingView(rootView: VStack(spacing: 12) {
                            ForEach(states.indices, id: \.self) { index in
                                ReadinessCard(item: LaunchReadinessChecker.appManagementItem(state: states[index]), onAction: { _ in
                                    XCTFail("Rendering must not open System Settings")
                                })
                            }
                        }.padding().background(dark ? Color.black : Color.white)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.locale, Locale(identifier: language))
                            .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight))
                        window.setContentSize(NSSize(width: 520, height: 560))
                        window.contentView = card
                        card.frame = NSRect(x: 0, y: 0, width: 520, height: 560)
                        card.layoutSubtreeIfNeeded()
                        try await Task.sleep(nanoseconds: 150_000_000)
                        let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
                        appearance.performAsCurrentDrawingAppearance { card.cacheDisplay(in: card.bounds, to: bitmap) }
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: directory.appendingPathComponent("readiness-\(language)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}

private final class PermissionSheetTestState: ObservableObject {
    @Published var settings = true
    @Published var readiness: Bool

    init(nested: Bool) { readiness = nested }
}

private struct PermissionSheetTestView: View {
    @ObservedObject var state: PermissionSheetTestState

    var body: some View {
        Text("Main").frame(width: 600, height: 450)
            .sheet(isPresented: $state.settings) {
                Text("Settings").frame(width: 560, height: 450)
                    .sheet(isPresented: $state.readiness) { ReadinessCheckSheet() }
            }
    }
}
