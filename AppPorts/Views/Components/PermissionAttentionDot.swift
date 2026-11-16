import SwiftUI

struct PermissionAttentionDot: View {
    let level: LaunchReadinessChecker.Item.Level?

    var body: some View {
        if level == .failed || level == .warning {
            Circle()
                .fill(level == .failed ? Color.red : Color.orange)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
    }
}

struct PermissionSettingsButton: View {
    let level: LaunchReadinessChecker.Item.Level?
    let attentionText: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("设置".localized, systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 30)
                .background(isSelected ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    PermissionAttentionDot(level: level).padding(4)
                }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: .command)
        .accessibilityValue(attentionText)
        .help(helpText)
    }

    private var helpText: String {
        let title = "设置".localized + " (⌘,)"
        return attentionText.isEmpty ? title : title + " · " + attentionText
    }
}

struct PermissionCheckButton: View {
    let level: LaunchReadinessChecker.Item.Level?
    let attentionText: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            PermissionAttentionDot(level: level)
            Button("检查".localized, action: action)
                .accessibilityValue(attentionText)
        }
        .help(attentionText)
    }
}
