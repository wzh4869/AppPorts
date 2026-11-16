import AppKit
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
        let userSize = NSSize(width: 1000, height: 700)
        window.setContentSize(userSize)
        window.contentView = MainWindowAppearance.WindowView()
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, userSize)
        window.orderFront(nil)
        window.orderOut(nil)
        window.orderFront(nil)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, userSize)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: 952, height: 624),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
