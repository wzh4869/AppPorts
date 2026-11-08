// Icon dragging adapted from DogSC by 神烦老狗, copyright 2026, MIT License.
// Source: laogou717/dogsc, commit 567fd6ed3bf113227dcf3e815f87ce60f0b69497.
// See Resources/DogSC-LICENSE.txt.
import AppKit
import SwiftUI

struct FullDiskAccessGuideView: View {
    let applicationURL: URL
    let onDragEnded: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 18) {
            PermissionApplicationIcon(applicationURL: applicationURL, onDragEnded: onDragEnded)
                .frame(width: 72, height: 72)
                .background(Color.primary.opacity(hovered ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 15))
                .onHover { hovered = $0 }
            VStack(alignment: .leading, spacing: 7) {
                Text("找不到 AppPorts？".localized).font(AppDialogTypography.title)
                Text("把图标拖入“完全磁盘访问权限”列表，再打开开关。".localized)
                    .font(AppDialogTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white,
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct PermissionApplicationIcon: NSViewRepresentable {
    let applicationURL: URL
    let onDragEnded: (Bool) -> Void

    func makeNSView(context: Context) -> PermissionApplicationDragView {
        PermissionApplicationDragView(applicationURL: applicationURL, onDragEnded: onDragEnded)
    }

    func updateNSView(_ view: PermissionApplicationDragView, context: Context) {
        view.applicationURL = applicationURL
        view.onDragEnded = onDragEnded
        view.setAccessibilityLabel("将 AppPorts 图标拖入系统设置的应用列表".localized)
    }
}

@MainActor
final class PermissionApplicationDragView: NSView, NSDraggingSource {
    var applicationURL: URL {
        didSet {
            guard oldValue != applicationURL else { return }
            icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            needsDisplay = true
        }
    }
    var onDragEnded: (Bool) -> Void
    private var icon: NSImage
    private var isDraggingApplication = false

    init(applicationURL: URL, onDragEnded: @escaping (Bool) -> Void) {
        self.applicationURL = applicationURL
        self.onDragEnded = onDragEnded
        icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        setAccessibilityLabel("将 AppPorts 图标拖入系统设置的应用列表".localized)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon.draw(in: bounds.insetBy(dx: 9, dy: 9), from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    func draggingItem() -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        return item
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingApplication else { return }
        isDraggingApplication = true
        beginDraggingSession(with: [draggingItem()], event: event, source: self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingApplication = false
        onDragEnded(operation != [])
    }
}
