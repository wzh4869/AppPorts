import SwiftUI

/// App-data visibility only; execution policy and tool-directory controls remain independent.
struct AppDataVisibilityControls: View {
    @Binding var showZeroByteDirectories: Bool
    @Binding var showLockedStructure: Bool
    @Binding var showNonMigratableDirectories: Bool

    var body: some View {
        HStack(spacing: 8) {
            AppDataVisibilityButton(
                showZeroByteDirectories: $showZeroByteDirectories,
                showLockedStructure: $showLockedStructure,
                showNonMigratableDirectories: $showNonMigratableDirectories
            )
            AppDataVisibilityActivePills(
                showZeroByteDirectories: $showZeroByteDirectories,
                showLockedStructure: $showLockedStructure,
                showNonMigratableDirectories: $showNonMigratableDirectories
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Header toolbar button for App Data directory visibility options with count badge and popover.
struct AppDataVisibilityButton: View {
    @Binding var showZeroByteDirectories: Bool
    @Binding var showLockedStructure: Bool
    @Binding var showNonMigratableDirectories: Bool

    @Environment(\.layoutDirection) private var layoutDirection
    @ObservedObject private var languageManager = LanguageManager.shared

    private var activeCount: Int {
        [showZeroByteDirectories, showLockedStructure, showNonMigratableDirectories]
            .filter { $0 }
            .count
    }

    var body: some View {
        AppPopoverButton(
            preferredEdge: .maxY,
            isHighlighted: activeCount > 0,
            help: "目录显示选项".localized,
            accessibilityLabel: "目录显示选项".localized
        ) {
            HStack(spacing: 5) {
                Image(systemName: activeCount > 0 ? "eye.fill" : "eye")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(activeCount > 0 ? .accentColor : .secondary)
                Text("显示".localized)
            }
        } popoverContent: {
            AppDataVisibilityPopover(
                showZeroByteDirectories: $showZeroByteDirectories,
                showLockedStructure: $showLockedStructure,
                showNonMigratableDirectories: $showNonMigratableDirectories
            )
        }
        .fixedSize()
        .overlay(alignment: .topTrailing) {
            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .frame(width: 14, height: 14)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(AppSurfaceColors.content, lineWidth: 1.5)
                    )
                    .offset(x: layoutDirection == .rightToLeft ? -5 : 5, y: -5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Popover listing App Data directory visibility toggles with concise descriptions and reset action.
struct AppDataVisibilityPopover: View {
    @Binding var showZeroByteDirectories: Bool
    @Binding var showLockedStructure: Bool
    @Binding var showNonMigratableDirectories: Bool

    @ObservedObject private var languageManager = LanguageManager.shared

    private var hasActiveOptions: Bool {
        showZeroByteDirectories || showLockedStructure || showNonMigratableDirectories
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("目录显示选项".localized)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("恢复默认".localized) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showZeroByteDirectories = false
                        showLockedStructure = false
                        showNonMigratableDirectories = false
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .opacity(hasActiveOptions ? 1 : 0)
                .disabled(!hasActiveOptions)
                .accessibilityHidden(!hasActiveOptions)
            }
            .frame(height: 18)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                optionRow(
                    title: "零字节目录".localized,
                    subtitle: "显示当前大小为 0 B 的空目录".localized,
                    accessibilityLabel: "显示零字节目录".localized,
                    isOn: $showZeroByteDirectories
                )
                optionRow(
                    title: "锁定目录结构".localized,
                    subtitle: "展开受保护的父级骨架目录".localized,
                    accessibilityLabel: "显示锁定目录结构".localized,
                    isOn: $showLockedStructure
                )
                optionRow(
                    title: "不支持迁移目录".localized,
                    subtitle: "显示系统限制或策略拦截的目录".localized,
                    accessibilityLabel: "显示不支持迁移目录".localized,
                    isOn: $showNonMigratableDirectories
                )
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func optionRow(
        title: String,
        subtitle: String,
        accessibilityLabel: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(accessibilityLabel)
        }
    }
}

/// Dismissible status pills shown alongside App Data stats when visibility overrides are enabled.
struct AppDataVisibilityActivePills: View {
    @Binding var showZeroByteDirectories: Bool
    @Binding var showLockedStructure: Bool
    @Binding var showNonMigratableDirectories: Bool

    @ObservedObject private var languageManager = LanguageManager.shared

    var hasActiveOptions: Bool {
        showZeroByteDirectories || showLockedStructure || showNonMigratableDirectories
    }

    var body: some View {
        if hasActiveOptions {
            if #available(macOS 13.0, *) {
                VisibilityWrapRowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    activePillViews
                }
            } else {
                HStack(spacing: 6) {
                    activePillViews
                }
            }
        }
    }

    @ViewBuilder
    private var activePillViews: some View {
        if showZeroByteDirectories {
            DismissibleVisibilityPill(
                icon: "circle.dotted",
                title: "含零字节目录".localized,
                dismissLabel: String(format: "关闭「%@」".localized, "零字节目录".localized)
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showZeroByteDirectories = false
                }
            }
        }
        if showLockedStructure {
            DismissibleVisibilityPill(
                icon: "lock",
                title: "含锁定结构".localized,
                dismissLabel: String(format: "关闭「%@」".localized, "锁定目录结构".localized)
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showLockedStructure = false
                }
            }
        }
        if showNonMigratableDirectories {
            DismissibleVisibilityPill(
                icon: "nosign",
                title: "含不支持迁移".localized,
                dismissLabel: String(format: "关闭「%@」".localized, "不支持迁移目录".localized)
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showNonMigratableDirectories = false
                }
            }
        }
    }
}

private struct DismissibleVisibilityPill: View {
    let icon: String
    let title: String
    let dismissLabel: String
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .opacity(isHovered ? 0.95 : 0.65)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Color.accentColor.opacity(isHovered ? 0.18 : 0.11))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(dismissLabel)
        .accessibilityLabel(dismissLabel)
    }
}

/// Inline filter chips for Tool Directories stats bar (independent of App Data visibility popover).
struct ToolDirectoryVisibilityChips: View {
    @Binding var showZeroByteDirectories: Bool
    @Binding var showNonMigratableDirectories: Bool

    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some View {
        HStack(spacing: 8) {
            DirectoryVisibilityChip(
                icon: "circle.dotted",
                title: "零字节目录".localized,
                tooltip: "显示零字节目录".localized,
                isOn: $showZeroByteDirectories
            )
            DirectoryVisibilityChip(
                icon: "nosign",
                title: "不可迁移".localized,
                tooltip: "显示不可迁移目录".localized,
                isOn: $showNonMigratableDirectories
            )
        }
    }
}

/// Reusable toggleable filter chip capsule used in Tool Directories.
struct DirectoryVisibilityChip: View {
    let icon: String
    let title: String
    let tooltip: String
    @Binding var isOn: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var chipBackground: Color {
        if isOn {
            return Color.accentColor.opacity(isHovered ? 0.18 : 0.12)
        }
        if colorScheme == .dark {
            return Color.white.opacity(isHovered ? 0.10 : 0.06)
        }
        return Color.primary.opacity(isHovered ? 0.07 : 0.04)
    }

    private var chipBorder: Color {
        if isOn {
            return Color.accentColor.opacity(0.35)
        }
        return Color.primary.opacity(isHovered ? 0.20 : 0.12)
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : icon)
                    .font(.system(size: 10, weight: isOn ? .bold : .medium))
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(isOn ? .accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(chipBackground)
            .overlay(
                Capsule()
                    .strokeBorder(chipBorder, lineWidth: 1)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Places stats summary and trailing visibility controls on one row when space permits,
/// wrapping the trailing controls onto a second row on narrow widths or verbose locales.
struct VisibilityStatsAccessoryRow<Primary: View, Trailing: View>: View {
    let primary: Primary
    let trailing: Trailing

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder trailing: () -> Trailing) {
        self.primary = primary()
        self.trailing = trailing()
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    primary
                    trailing
                }
                VStack(alignment: .leading, spacing: 6) {
                    primary
                    trailing
                }
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                primary
                trailing
            }
        }
    }
}

@available(macOS 13.0, *)
private struct VisibilityWrapRowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + horizontalSpacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                if rowWidth > 0 { rowWidth += horizontalSpacing }
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
            }
        }

        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: cursorX, y: cursorY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            cursorX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
