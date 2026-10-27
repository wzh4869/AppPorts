import SwiftUI

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
        VStack(spacing: 0) {
            Divider()
            content
                .font(.system(size: 13, weight: .medium))
                .controlSize(.regular)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Hover updates stay within the row so scrolling cannot invalidate and sort both lists.
struct AppListRowAppearance: ViewModifier {
    let isSelected: Bool
    let index: Int
    @State private var isHovered = false

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.20) }
        if isHovered { return Color.primary.opacity(0.08) }
        return index.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(0.035)
    }

    func body(content: Content) -> some View {
        content
            .listRowBackground(background)
            .onHover { hovering in
                if isHovered != hovering { isHovered = hovering }
            }
    }
}

/// Disabled primary actions use a neutral surface instead of a faded accent fill.
struct AppListPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isEnabled ? .white : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled ? Color.accentColor : Color.primary.opacity(0.045))
            )
            .opacity(isEnabled && configuration.isPressed ? 0.8 : 1)
            .scaleEffect(!reduceMotion && isEnabled && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : AppMotion.interaction, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
