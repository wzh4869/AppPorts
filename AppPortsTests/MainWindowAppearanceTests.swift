import AppKit
import Combine
import SwiftUI
import XCTest
@testable import AppPorts

@MainActor
final class MainWindowAppearanceTests: XCTestCase {
    func testInitialSizeIsAppliedBeforeTheWindowIsDisplayed() async throws {
        let window = makeWindow()
        defer { window.close() }
        let expected = MainWindowAppearance.initialContentSize(on: window.screen ?? NSScreen.main)
        window.contentView = MainWindowAppearance.WindowView()

        // Read immediately; waiting for a run-loop turn would hide the first-frame regression.
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, expected)
        window.orderFront(nil)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, expected)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, expected)
    }

    func testReplacingTheBridgeAndReopeningPreserveTheUserSize() {
        let window = makeWindow()
        defer { window.close() }
        window.contentView = MainWindowAppearance.WindowView()
        // AppKit constrains oversized windows when shown; keep this fixture inside the visible screen.
        let visibleSize = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1200, height: 780)
        let userSize = NSSize(width: min(1000, visibleSize.width - 40), height: min(700, visibleSize.height - 40))
        window.setContentSize(userSize)
        window.contentView = MainWindowAppearance.WindowView()
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, userSize)
        window.orderFront(nil)
        window.orderOut(nil)
        window.orderFront(nil)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, userSize)
    }

    func testMainWindowDoesNotMoveWhenDraggingContentControls() {
        let window = makeWindow()
        defer { window.close() }
        window.contentView = MainWindowAppearance.WindowView()

        XCTAssertFalse(window.isMovableByWindowBackground)
    }

    func testAppearanceMappingCoversSystemLightDarkAndFallback() {
        XCTAssertNil(MainWindowAppearance.nsAppearance(for: "system"))
        XCTAssertNil(MainWindowAppearance.nsAppearance(for: nil))
        XCTAssertNil(MainWindowAppearance.nsAppearance(for: "unexpected"))
        XCTAssertEqual(MainWindowAppearance.nsAppearance(for: "light")?.name, .aqua)
        XCTAssertEqual(MainWindowAppearance.nsAppearance(for: "dark")?.name, .darkAqua)
    }

    func testSwitchingFromDarkAndLightBackToSystemRestoresEffectiveAppearanceAndSwiftUIColorScheme() async throws {
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }

        NSApp.appearance = nil
        let systemAppearance = try XCTUnwrap(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        let expectedSystemScheme: ColorScheme = systemAppearance == .darkAqua ? .dark : .light

        let model = AppearanceTestModel()
        let mainRecorder = ColorSchemeRecorder()
        let secondaryRecorder = ColorSchemeRecorder()

        let mainWindow = makeWindow()
        let secondaryWindow = makeWindow()
        defer {
            mainWindow.close()
            secondaryWindow.close()
        }

        // Simulate a stale window-level override left behind before MainWindowAppearance attaches.
        mainWindow.appearance = NSAppearance(named: .darkAqua)

        let mainHost = NSHostingView(
            rootView: MainAppearanceProbeView(model: model, recorder: mainRecorder)
        )
        let secondaryHost = NSHostingView(
            rootView: SecondaryAppearanceProbeView(recorder: secondaryRecorder)
        )

        mainWindow.contentView = mainHost
        secondaryWindow.contentView = secondaryHost
        mainWindow.orderFront(nil)
        secondaryWindow.orderFront(nil)

        try await settleAppearance(hosts: [mainHost, secondaryHost])
        XCTAssertNil(NSApp.appearance)
        XCTAssertNil(mainWindow.appearance)
        XCTAssertEqual(mainWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), systemAppearance)
        XCTAssertEqual(secondaryWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), systemAppearance)
        XCTAssertEqual(mainRecorder.colorScheme, expectedSystemScheme)
        XCTAssertEqual(secondaryRecorder.colorScheme, expectedSystemScheme)

        model.mode = "light"
        try await settleAppearance(hosts: [mainHost, secondaryHost])
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        XCTAssertNil(mainWindow.appearance)
        XCTAssertEqual(mainWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(secondaryWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(mainRecorder.colorScheme, .light)
        XCTAssertEqual(secondaryRecorder.colorScheme, .light)

        model.mode = "dark"
        try await settleAppearance(hosts: [mainHost, secondaryHost])
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        XCTAssertNil(mainWindow.appearance)
        XCTAssertEqual(mainWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(secondaryWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(mainRecorder.colorScheme, .dark)
        XCTAssertEqual(secondaryRecorder.colorScheme, .dark)

        // Switching from dark back to auto must clear NSApp.appearance and update SwiftUI colorScheme.
        model.mode = "system"
        try await settleAppearance(hosts: [mainHost, secondaryHost])
        XCTAssertNil(NSApp.appearance)
        XCTAssertNil(mainWindow.appearance)
        XCTAssertEqual(mainWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), systemAppearance)
        XCTAssertEqual(secondaryWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), systemAppearance)
        XCTAssertEqual(mainRecorder.colorScheme, expectedSystemScheme)
        XCTAssertEqual(secondaryRecorder.colorScheme, expectedSystemScheme)

        // Also confirm light -> system clears explicit light override cleanly.
        model.mode = "light"
        try await settleAppearance(hosts: [mainHost, secondaryHost])
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        XCTAssertEqual(mainRecorder.colorScheme, .light)
        XCTAssertEqual(secondaryRecorder.colorScheme, .light)

        model.mode = "system"
        try await settleAppearance(hosts: [mainHost, secondaryHost])
        XCTAssertNil(NSApp.appearance)
        XCTAssertNil(mainWindow.appearance)
        XCTAssertEqual(mainWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), systemAppearance)
        XCTAssertEqual(secondaryWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), systemAppearance)
        XCTAssertEqual(mainRecorder.colorScheme, expectedSystemScheme)
        XCTAssertEqual(secondaryRecorder.colorScheme, expectedSystemScheme)
    }

    func testApplyOverlayScrollbarsIfAutomaticOverridesNilAndAutomaticOnly() throws {
        XCTAssertEqual(MainWindowAppearance.overlayScrollBarOverride(for: nil), "WhenScrolling")
        XCTAssertEqual(MainWindowAppearance.overlayScrollBarOverride(for: "Automatic"), "WhenScrolling")
        XCTAssertNil(MainWindowAppearance.overlayScrollBarOverride(for: "Always"))
        XCTAssertNil(MainWindowAppearance.overlayScrollBarOverride(for: "WhenScrolling"))

        let suiteName = "MainWindowAppearanceTests.\(UUID().uuidString)"
        let volatileDomain = "\(suiteName).volatile"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removeVolatileDomain(forName: volatileDomain)
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("Automatic", forKey: MainWindowAppearance.scrollBarsDefaultsKey)
        MainWindowAppearance.applyOverlayScrollbarsIfAutomatic(
            defaults: defaults,
            targetVolatileDomain: volatileDomain,
            appliesInTests: true
        )
        XCTAssertEqual(
            defaults.volatileDomain(forName: volatileDomain)[MainWindowAppearance.scrollBarsDefaultsKey] as? String,
            "WhenScrolling"
        )

        defaults.removeVolatileDomain(forName: volatileDomain)
        defaults.set("Always", forKey: MainWindowAppearance.scrollBarsDefaultsKey)
        MainWindowAppearance.applyOverlayScrollbarsIfAutomatic(
            defaults: defaults,
            targetVolatileDomain: volatileDomain,
            appliesInTests: true
        )
        XCTAssertNil(
            defaults.volatileDomain(forName: volatileDomain)[MainWindowAppearance.scrollBarsDefaultsKey]
        )

        defaults.removeVolatileDomain(forName: volatileDomain)
        defaults.set("WhenScrolling", forKey: MainWindowAppearance.scrollBarsDefaultsKey)
        MainWindowAppearance.applyOverlayScrollbarsIfAutomatic(
            defaults: defaults,
            targetVolatileDomain: volatileDomain,
            appliesInTests: true
        )
        XCTAssertNil(
            defaults.volatileDomain(forName: volatileDomain)[MainWindowAppearance.scrollBarsDefaultsKey]
        )
    }

    private func settleAppearance(hosts: [NSView]) async throws {
        for host in hosts {
            host.layoutSubtreeIfNeeded()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        for host in hosts {
            host.layoutSubtreeIfNeeded()
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: 952, height: 624),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

private final class AppearanceTestModel: ObservableObject {
    @Published var mode = "system"
}

private final class ColorSchemeRecorder {
    var colorScheme: ColorScheme?
}

private struct MainAppearanceProbeView: View {
    @ObservedObject var model: AppearanceTestModel
    let recorder: ColorSchemeRecorder
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = { recorder.colorScheme = colorScheme }()
        Text(verbatim: model.mode)
            .frame(width: 240, height: 120)
            .background(MainWindowAppearance(appearance: model.mode, appliesAppearanceInTests: true))
    }
}

private struct SecondaryAppearanceProbeView: View {
    let recorder: ColorSchemeRecorder
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = { recorder.colorScheme = colorScheme }()
        Text(verbatim: "Secondary")
            .frame(width: 240, height: 120)
    }
}
