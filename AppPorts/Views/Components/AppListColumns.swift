import SwiftUI
import AppKit


/// Neutral sidebar surface for light and dark appearances.
enum AppListColors {
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    })
}

/// Capture the existing path identity once; List reads IDs repeatedly while scrolling.
struct AppListEntry: Identifiable {
    let id: String
    let app: AppItem
    let index: Int

    init(app: AppItem, index: Int) {
        self.id = app.id
        self.app = app
        self.index = index
    }
}

/// Shared column widths keep the list header and application rows aligned.
struct AppListColumns<Name: View, Size: View, Actions: View>: View {
    @ViewBuilder var name: Name
    @ViewBuilder var size: Size
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            name.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            size.frame(width: 64, alignment: .leading)
            actions.frame(width: 28, alignment: .trailing)
        }
    }
}

/// The two application libraries share the same panel appearance.
struct AppListPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

struct AppListFooterStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .controlSize(.regular)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

/// Hover updates stay within the row so scrolling cannot invalidate and sort both lists.
struct AppListRowAppearance: ViewModifier {
    let isSelected: Bool
    let index: Int
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var surface: Color {
        colorScheme == .light ? .white : Color(nsColor: .controlBackgroundColor)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.20) }
        if isHovered { return Color.primary.opacity(0.08) }
        return surface
    }

    func body(content: Content) -> some View {
        content
            .listRowBackground(
                background.overlay(alignment: .top) {
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, 16)
                            .background(surface)
                            .allowsHitTesting(false)
                    }
                }
            )
            .onHover { hovering in
                if isHovered != hovering { isHovered = hovering }
            }
    }
}

/// Disabled primary actions use a neutral surface instead of a faded accent fill.
struct AppListPrimaryButtonStyle: ButtonStyle {
    var isSecondary = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isEnabled ? (isSecondary ? .primary : .white) : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled && !isSecondary ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            .opacity(isEnabled && configuration.isPressed ? 0.8 : 1)
            .scaleEffect(!reduceMotion && isEnabled && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : AppMotion.interaction, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Keep native List keyboard and multiple selection behavior while drawing selection in AppRowView.
struct AppListSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionView { SelectionView() }

    func updateNSView(_ nsView: SelectionView, context: Context) {
        nsView.updateSelectionAppearance()
    }

    final class SelectionView: NSView {
        private weak var configuredTable: NSTableView?
        private var updateScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { configuredTable = nil }
            updateSelectionAppearance()
        }

        func updateSelectionAppearance() {
            guard window != nil, configuredTable == nil, !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                var ancestor = self.superview
                while let view = ancestor {
                    // AppKit also draws a focus ring around the right-clicked row.
                    view.focusRingType = .none
                    if let table = view as? NSTableView {
                        self.configuredTable = table
                        if table.selectionHighlightStyle != .none {
                            table.selectionHighlightStyle = .none
                        }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}
