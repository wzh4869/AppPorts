import AppKit
import Combine
import SwiftUI

/// 绕开 SwiftUI `.popover` 与系统边框按钮在 macOS 上的追踪态卡死问题，
/// 直接通过受控的 `NSPopover` 管理弹出与重复点击开关。
@MainActor
final class AppPopoverController: NSObject, ObservableObject, NSPopoverDelegate {
    weak var anchorView: NSView?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?
    private var suppressAnchorReopen = false
    private var closeMouseUpMonitor: Any?
    @Published private(set) var isShown = false

    func updateContent(_ rootView: AnyView) {
        if popover?.isShown == true {
            hostingController?.rootView = rootView
        }
    }

    func toggle(preferredEdge: NSRectEdge, content: () -> AnyView) {
        if popover?.isShown == true {
            popover?.performClose(nil)
            return
        }
        if suppressAnchorReopen {
            clearAnchorClickSuppression()
            return
        }
        clearAnchorClickSuppression()

        guard let anchor = anchorView, anchor.window != nil else { return }
        popover?.close()

        let hosting = NSHostingController(rootView: content())
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = hosting

        popover = pop
        hostingController = hosting
        isShown = true
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
    }

    nonisolated func popoverWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard notification.object as AnyObject? === popover,
                  let event = NSApp.currentEvent,
                  event.type == .leftMouseDown,
                  isMouseInsideAnchor() else { return }
            suppressAnchorReopen = true
            armMouseUpCleanupMonitor()
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard notification.object as AnyObject? === popover else { return }
            isShown = false
            popover = nil
            hostingController = nil
        }
    }

    func closeImmediately() {
        clearAnchorClickSuppression()
        popover?.close()
        popover = nil
        hostingController = nil
        isShown = false
    }

    private func isMouseInsideAnchor() -> Bool {
        guard let anchor = anchorView, let window = anchor.window else { return false }
        let windowRect = anchor.convert(anchor.bounds, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        return screenRect.contains(NSEvent.mouseLocation)
    }

    private func armMouseUpCleanupMonitor() {
        if let closeMouseUpMonitor {
            NSEvent.removeMonitor(closeMouseUpMonitor)
            self.closeMouseUpMonitor = nil
        }
        closeMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            DispatchQueue.main.async {
                self?.clearAnchorClickSuppression()
            }
            return event
        }
    }

    private func clearAnchorClickSuppression() {
        suppressAnchorReopen = false
        if let closeMouseUpMonitor {
            NSEvent.removeMonitor(closeMouseUpMonitor)
            self.closeMouseUpMonitor = nil
        }
    }
}

private struct AppPopoverAnchorView: NSViewRepresentable {
    @ObservedObject var controller: AppPopoverController
    let content: AnyView

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        controller.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.anchorView = nsView
        controller.updateContent(content)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // N/A: owned by the hosting SwiftUI view lifetime; closed if anchor leaves window.
    }
}

@MainActor
struct AppPopoverButton<Label: View, PopoverContent: View>: View {
    var preferredEdge: NSRectEdge = .maxY
    var isHighlighted: Bool = false
    var help: String? = nil
    var accessibilityLabel: String? = nil
    @ViewBuilder let label: () -> Label
    @ViewBuilder let popoverContent: () -> PopoverContent

    @StateObject private var controller = AppPopoverController()
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        if controller.isShown { return 0.12 }
        if isHovered { return 0.07 }
        return 0.035
    }

    private var fillColor: Color {
        if controller.isShown || isHighlighted {
            return Color.accentColor.opacity(controller.isShown ? 0.14 : (isHovered ? 0.11 : 0.08))
        }
        return Color.primary.opacity(backgroundOpacity)
    }

    private var borderColor: Color {
        if controller.isShown || isHighlighted {
            return Color.accentColor.opacity(controller.isShown ? 0.28 : 0.18)
        }
        return Color.primary.opacity(controller.isShown ? 0.14 : 0.08)
    }

    var body: some View {
        let button = Button {
            controller.toggle(preferredEdge: preferredEdge) {
                AnyView(popoverContent())
            }
        } label: {
            label()
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(controller.isShown || isHighlighted ? .accentColor : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDisappear { controller.closeImmediately() }
        .background(AppPopoverAnchorView(controller: controller, content: AnyView(popoverContent())))

        if let help, let accessibilityLabel {
            button
                .help(help)
                .accessibilityLabel(accessibilityLabel)
        } else if let help {
            button.help(help)
        } else if let accessibilityLabel {
            button.accessibilityLabel(accessibilityLabel)
        } else {
            button
        }
    }
}
