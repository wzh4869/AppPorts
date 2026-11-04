// Adapted from DogSC by 神烦老狗, copyright 2026, MIT License.
// Source: laogou717/dogsc, commit 567fd6ed3bf113227dcf3e815f87ce60f0b69497.
// See Resources/DogSC-LICENSE.txt for the retained license.
import AppKit
import SwiftUI

@MainActor
final class FullDiskAccessGuide {
    static let shared = FullDiskAccessGuide()
    static let panelSize = NSSize(width: 640, height: 116)
    private var panel: NSPanel?
    private var followTask: Task<Void, Never>?
    private var hasSeenSettings = false
    private var missingSamples = 0

    func openSettings() {
        guard AppInstallationLocation.confirmIfNeeded(),
              let url = LaunchReadinessChecker.Item.Action.fullDiskAccess.settingsURLs.first,
              NSWorkspace.shared.open(url) else { return }
        show(applicationURL: Bundle.main.bundleURL)
    }

    private func show(applicationURL: URL) {
        hide()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingController(rootView: FullDiskAccessGuideView(
            applicationURL: applicationURL,
            onDragEnded: { [weak self] accepted in self?.applicationDragEnded(accepted: accepted) }))
        if #available(macOS 13.0, *) {
            host.sizingOptions = []
        }
        panel.contentViewController = host
        // Wait for the settings window before displaying, avoiding an initial jump.
        followTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.followSettings()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = PermissionGuidePanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.tabbingMode = .disallowed
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        return panel
    }

    func hide() {
        followTask?.cancel()
        followTask = nil
        hasSeenSettings = false
        missingSamples = 0
        panel?.orderOut(nil)
    }

    private func applicationDragEnded(accepted: Bool) {
        guard accepted else { return }
        // Receiving a file is not proof of permission. Leave authorization to System Settings.
        hide()
        Self.settingsApplication()?.activate(options: [.activateAllWindows])
    }

    private func followSettings() {
        guard let panel else { return }
        if hasSeenSettings, let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           identifier != "com.apple.systempreferences", identifier != Bundle.main.bundleIdentifier {
            hide()
            return
        }
        guard let settings = Self.settingsWindowFrame(),
              let screen = NSScreen.screens.max(by: {
                  Self.overlap($0.frame, settings) < Self.overlap($1.frame, settings)
              }) else {
            missingSamples += 1
            if missingSamples >= (hasSeenSettings ? 4 : 40) { hide() }
            return
        }
        hasSeenSettings = true
        missingSamples = 0
        let frame = Self.attachedFrame(to: settings, visibleFrame: screen.visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    static func attachedFrame(to reference: NSRect, visibleFrame: NSRect) -> NSRect {
        let inset: CGFloat = 12
        let gap: CGFloat = 10
        let width = min(reference.width, max(320, visibleFrame.width - inset * 2))
        let minX = visibleFrame.minX + inset
        let maxX = max(visibleFrame.maxX - width - inset, minX)
        let x = min(max(reference.minX, minX), maxX)
        let below = reference.minY - panelSize.height - gap
        let y = below >= visibleFrame.minY + inset ? below
            : min(reference.maxY + gap, visibleFrame.maxY - panelSize.height - inset)
        return NSRect(x: x, y: y, width: width, height: panelSize.height).integral
    }

    private static func overlap(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func settingsApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.systempreferences" }
    }

    private static func settingsWindowFrame() -> NSRect? {
        guard let application = settingsApplication(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]] else { return nil }
        let bounds = windows.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary),
                  frame.width >= 480, frame.height >= 320 else { return nil }
            return frame
        }.max { $0.width * $0.height < $1.width * $1.height }
        guard let bounds else { return nil }
        // WindowServer uses a top-left origin; AppKit uses the primary display's bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: bounds.minX, y: primaryTop - bounds.maxY,
            width: bounds.width, height: bounds.height).integral
    }
}

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
