import SwiftUI

enum AppSettingsStyle {
    static let background = AppSurfaceColors.content
    static let border = Color(nsColor: .separatorColor).opacity(0.7)
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let gap: CGFloat = 16
    static let contentInset: CGFloat = 24
    static let panelInset: CGFloat = 16
    static let sectionGap: CGFloat = 12
    static let rowGap: CGFloat = 8
    static let relatedGap: CGFloat = 4
    static let minimumColumnWidth: CGFloat = 350
    static let applicationIconSize: CGFloat = 48
    static let bodyFont = Font.system(size: 13)
    static let controlSize = ControlSize.regular
    static let sectionFont = Font.system(size: 14, weight: .semibold)
    static let rowFont = Font.system(size: 13, weight: .medium)
    static let secondaryFont = Font.system(size: 12)
}

struct AppSettingsPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(AppSettingsStyle.bodyFont)
            .controlSize(AppSettingsStyle.controlSize)
            .buttonStyle(.bordered)
            .padding(AppSettingsStyle.panelInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSettingsStyle.background)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppSettingsStyle.border, lineWidth: 1))
    }
}

struct AppSettingsSection<Content: View, HeaderAccessory: View>: View {
    let title: String
    let content: Content
    let headerAccessory: HeaderAccessory

    init(title: String, @ViewBuilder headerAccessory: () -> HeaderAccessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.headerAccessory = headerAccessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSettingsStyle.sectionGap) {
            HStack(alignment: .firstTextBaseline, spacing: AppSettingsStyle.rowGap) {
                Text(title)
                    .font(AppSettingsStyle.sectionFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                headerAccessory
            }
            VStack(alignment: .leading, spacing: AppSettingsStyle.rowGap) {
                content
            }
        }
        .modifier(AppSettingsPanelStyle())
    }
}

extension AppSettingsSection where HeaderAccessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, headerAccessory: { EmptyView() }, content: content)
    }
}

struct AppSettingsToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: AppSettingsStyle.sectionGap) {
            VStack(alignment: .leading, spacing: AppSettingsStyle.relatedGap) {
                Text(title).font(AppSettingsStyle.rowFont)
                if !detail.isEmpty {
                    Text(detail)
                        .font(AppSettingsStyle.secondaryFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .fixedSize()
                .accessibilityHint(detail)
        }
    }
}
