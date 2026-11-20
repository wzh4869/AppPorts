//
//  ReadinessCheckView.swift
//  AppPorts
//
//  迁移前的准备情况：权限是否齐全、外部存储格式是否满足要求。
//

import SwiftUI

// MARK: - 准备情况列表

/// 迁移前的准备情况检查。
///
/// 欢迎屏、独立检查面板与设置页共用检查结果和权限操作。
@MainActor
struct ReadinessCheckView: View {
    /// 刷新入口相对卡片的位置
    enum RefreshPlacement {
        /// 卡片上方（「设置」弹窗里使用）
        case top
        /// 卡片下方，可与左侧脚注并排（欢迎屏使用）
        case bottom
        /// 设置页使用准备情况标题行中的刷新入口。
        case hidden
    }

    /// 刷新入口的位置
    var refreshPlacement: RefreshPlacement = .top

    /// 放在刷新入口左侧的说明文字，仅 `refreshPlacement == .bottom` 时显示
    var footnote: String?

    var onOpenSettings: (() -> Void)?
    var isEmbedded: Bool
    @StateObject private var model: ReadinessCheckModel
    @State private var isResettingLegacyPermissions = false
    @State private var legacyResetFeedback: String?
    @State private var legacyResetFeedbackIsError = false

    init(refreshPlacement: RefreshPlacement = .top, footnote: String? = nil,
         onOpenSettings: (() -> Void)? = nil, isEmbedded: Bool = false,
         model: ReadinessCheckModel? = nil) {
        self.refreshPlacement = refreshPlacement
        self.footnote = footnote
        self.onOpenSettings = onOpenSettings
        self.isEmbedded = isEmbedded
        _model = StateObject(wrappedValue: model ?? ReadinessCheckModel())
    }

    private var resettablePermissions: [LegacyPermissionResetter.PermissionKind] {
        var result: [LegacyPermissionResetter.PermissionKind] = []
        if let item = model.items.first(where: { $0.id == LaunchReadinessChecker.ItemID.appManagement }),
           item.level != .ok {
            result.append(.appManagement)
        }
        if let item = model.items.first(where: { $0.id == LaunchReadinessChecker.ItemID.fullDiskAccess }),
           item.level == .failed {
            result.append(.fullDiskAccess)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isEmbedded ? AppSettingsStyle.rowGap : 12) {
            if refreshPlacement == .top {
                refreshRow
            }

            if model.items.isEmpty {
                loadingCard
            } else {
                ForEach(model.items) { item in
                    ReadinessCard(item: item, isEmbedded: isEmbedded) { action in
                        openSettings(for: action)
                    }
                    if isEmbedded, item.id != model.items.last?.id { Divider() }
                }

                if !resettablePermissions.isEmpty {
                    if isEmbedded { Divider() }
                    legacyResetCard
                }
            }

            if refreshPlacement == .bottom {
                refreshRow
            }
        }
        .onAppear { model.refresh() }
        // 去系统设置改完权限切回来，自动重新检查一次。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onChange(of: resettablePermissions) { current in
            if current.isEmpty {
                legacyResetFeedback = nil
                legacyResetFeedbackIsError = false
            }
        }
    }

    /// 一行刷新入口：左侧是可选脚注，右侧是「重新检查」。
    private var refreshRow: some View {
        HStack(spacing: 8) {
            if let footnote {
                Text(footnote)
                    .font(AppDialogTypography.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if model.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            Button(action: model.refresh) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("重新检查".localized)
                }
                .font(AppDialogTypography.body)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(model.isChecking)
        }
        .padding(.top, refreshPlacement == .bottom ? 2 : 0)
    }

    @ViewBuilder
    private var loadingCard: some View {
        if isEmbedded { loadingContent }
        else { loadingContent.settingsCardBackground() }
    }

    private var loadingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在检查…".localized)
                .font(AppDialogTypography.body)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var legacyResetCard: some View {
        if isEmbedded { legacyResetContent }
        else { legacyResetContent.settingsCardBackground() }
    }

    private var legacyResetContent: some View {
        VStack(alignment: .leading, spacing: isEmbedded ? AppSettingsStyle.relatedGap : 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("若系统设置中 AppPorts 开关已开但仍未生效，可能是旧版本证书残留，可先清理旧记录再重新授权。".localized)
                    .font(isEmbedded ? AppSettingsStyle.secondaryFont : AppDialogTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: resetLegacyPermissions) {
                    HStack(spacing: 5) {
                        if isResettingLegacyPermissions {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                        Text("清理旧版授权记录".localized)
                    }
                    .font(isEmbedded ? AppSettingsStyle.bodyFont : AppDialogTypography.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(isEmbedded ? AppSettingsStyle.controlSize : .small)
                .disabled(isResettingLegacyPermissions)
                .fixedSize(horizontal: true, vertical: false)
                .help("清理旧证书留下的系统权限记录；清理完全磁盘访问权限时可能会请求管理员授权。".localized)
            }

            if let legacyResetFeedback {
                Text(legacyResetFeedback)
                    .font(isEmbedded ? AppSettingsStyle.secondaryFont : AppDialogTypography.body)
                    .foregroundStyle(legacyResetFeedbackIsError ? AppSettingsStyle.error : AppSettingsStyle.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resetLegacyPermissions() {
        let targets = resettablePermissions
        guard !targets.isEmpty, !isResettingLegacyPermissions else { return }
        guard AppInstallationLocation.confirmIfNeeded() else { return }

        isResettingLegacyPermissions = true
        legacyResetFeedback = nil
        legacyResetFeedbackIsError = false

        Task {
            defer { isResettingLegacyPermissions = false }
            do {
                let outcome = try await LegacyPermissionResetter.shared.resetManually(permissions: targets)
                model.refresh()
                if outcome.allSucceeded {
                    legacyResetFeedback = "已清理旧版授权记录，请点击上方“打开系统设置”重新添加并开启开关。".localized
                    legacyResetFeedbackIsError = false
                } else {
                    legacyResetFeedback = "未能自动清理部分旧版授权记录，请在系统设置中选中旧的 AppPorts 后点“-”移除再重新添加。".localized
                    legacyResetFeedbackIsError = true
                }
            } catch is CancellationError {
                return
            } catch {
                legacyResetFeedback = error.localizedDescription
                legacyResetFeedbackIsError = true
            }
        }
    }

    private func openSettings(for action: LaunchReadinessChecker.Item.Action) {
        FullDiskAccessGuide.shared.openSettings(for: action, dismiss: onOpenSettings)
    }
}

// MARK: - 准备情况弹窗

/// 主界面其他入口使用的独立准备情况面板。
struct ReadinessCheckSheet: View {
    var onOpenSettings: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "checkmark.shield")
                    .font(.title2)
                    .foregroundColor(.blue)

                Text("准备情况".localized)
                    .font(AppDialogTypography.title)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("关闭".localized)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RunningApplicationCard()
                    ReadinessCheckView(onOpenSettings: {
                        dismiss()
                        onOpenSettings?()
                    })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .appDialogTypography()
        .frame(width: 560, height: 600)
    }
}

/// 展示检查对应的实际应用，帮助用户在系统设置中添加正确的副本。
private struct RunningApplicationCard: View {
    private let application = LaunchReadinessChecker.RunningApplication()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("当前运行的 AppPorts".localized, systemImage: "app.badge.checkmark")
                .font(AppDialogTypography.title)
            Text(String(format: "版本 %@（构建 %@）".localized, application.version, application.build))
                .font(AppDialogTypography.body)
            Text(application.url.path)
                .font(AppDialogTypography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("在 Finder 中显示".localized) {
                    NSWorkspace.shared.activateFileViewerSelecting([application.url])
                }
                Button("复制路径".localized) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(application.url.path, forType: .string)
                }
            }
            .controlSize(.small)
            Text("检查针对当前进程，无法直接比对系统授权列表中的版本。若已开启但仍被拒绝，请将此处的 AppPorts 重新添加到「完全磁盘访问权限」，退出重开后再检查。".localized)
                .font(AppDialogTypography.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCardBackground()
    }
}

// MARK: - 卡片

/// 准备情况里的一张卡片，缺权限时右侧是可点击的「去授权」。
struct ReadinessCard: View {
    let item: LaunchReadinessChecker.Item
    var isEmbedded = false
    let onAction: (LaunchReadinessChecker.Item.Action) -> Void

    @ViewBuilder
    var body: some View {
        if isEmbedded {
            HStack(alignment: .top, spacing: AppSettingsStyle.sectionGap) {
                VStack(alignment: .leading, spacing: AppSettingsStyle.relatedGap) {
                    Text(item.title).font(AppSettingsStyle.rowFont)
                    if item.level != .ok {
                        Text(item.detail)
                            .font(AppSettingsStyle.secondaryFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            .help(item.detail)
        } else {
            SettingsStyleCard(icon: symbolName, iconColor: statusColor,
                title: item.title, detail: item.detail) {
                accessory
            }
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if let action = item.action {
            VStack(alignment: .trailing, spacing: 6) {
                if action == .appManagement {
                    Text(statusText)
                        .font(isEmbedded ? AppSettingsStyle.secondaryFont : AppDialogTypography.body)
                        .foregroundColor(isEmbedded ? .primary : statusColor)
                }
                Button(action: { onAction(action) }) {
                    HStack(spacing: 3) {
                        Text("打开系统设置".localized)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(isEmbedded ? AppSettingsStyle.bodyFont
                        : AppDialogTypography.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(isEmbedded ? AppSettingsStyle.controlSize : .small)
                .help("去设置授予权限".localized)
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
            if isEmbedded {
                Label {
                    Text(statusText)
                } icon: {
                    Image(systemName: symbolName).foregroundStyle(statusColor)
                }
                .font(AppSettingsStyle.secondaryFont)
                .fixedSize()
            } else {
                Text(statusText)
                    .font(AppDialogTypography.body.weight(.semibold))
                    .foregroundColor(statusColor)
            }
        }
    }

    private var symbolName: String {
        switch item.level {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var statusText: String {
        switch item.level {
        case .ok: return "已就绪".localized
        case .warning: return item.action == .appManagement ? "无法确认".localized : "注意".localized
        case .failed: return "需要授权".localized
        }
    }

    private var statusColor: Color {
        switch item.level {
        case .ok: return AppSettingsStyle.success
        case .warning: return AppSettingsStyle.warning
        case .failed: return AppSettingsStyle.error
        }
    }
}

// MARK: - 设置页风格的卡片

/// 设置页统一的卡片容器：淡底色 + 圆角 + 内边距。
extension View {
    func settingsCardBackground(opacity: Double = 0.03) -> some View {
        self
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(opacity))
            .cornerRadius(12)
    }
}

/// 设置页风格的卡片：彩色图标 + 标题，下面是说明，右侧可选控件。
struct SettingsStyleCard<Accessory: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String
    var isEmbedded: Bool
    let accessory: Accessory

    init(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        isEmbedded: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.detail = detail
        self.isEmbedded = isEmbedded
        self.accessory = accessory()
    }

    @ViewBuilder
    var body: some View {
        if isEmbedded { cardContent }
        else { cardContent.settingsCardBackground() }
    }

    private var cardContent: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundColor(iconColor)

                    Text(title)
                        .font(isEmbedded ? .system(size: 13, weight: .medium) : AppDialogTypography.title)
                        .foregroundColor(.primary)
                }

                Text(detail)
                    .font(isEmbedded ? AppSettingsStyle.secondaryFont : AppDialogTypography.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            accessory
        }
    }
}
