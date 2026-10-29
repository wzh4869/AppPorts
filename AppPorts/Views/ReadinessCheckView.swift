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
/// 欢迎屏第二屏与「设置」里共用同一组设置页风格的卡片，
/// 只有刷新入口的位置不同：欢迎屏放在卡片下方（让两屏的卡片从同一高度开始），
/// 「设置」里放在卡片上方。
struct ReadinessCheckView: View {
    /// 刷新入口相对卡片的位置
    enum RefreshPlacement {
        /// 卡片上方（「设置」弹窗里使用）
        case top
        /// 卡片下方，可与左侧脚注并排（欢迎屏使用）
        case bottom
    }

    /// 刷新入口的位置
    var refreshPlacement: RefreshPlacement = .top

    /// 放在刷新入口左侧的说明文字，仅 `refreshPlacement == .bottom` 时显示
    var footnote: String?

    @State private var items: [LaunchReadinessChecker.Item] = []
    @State private var isChecking = false

    init(refreshPlacement: RefreshPlacement = .top, footnote: String? = nil) {
        self.refreshPlacement = refreshPlacement
        self.footnote = footnote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if refreshPlacement == .top {
                refreshRow
            }

            if items.isEmpty {
                loadingCard
            } else {
                ForEach(items) { item in
                    ReadinessCard(item: item) { action in
                        openSettings(for: action)
                    }
                }
            }

            if refreshPlacement == .bottom {
                refreshRow
            }
        }
        .onAppear(perform: refresh)
        // 去系统设置改完权限切回来，自动重新检查一次。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
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

            if isChecking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            Button(action: refresh) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("重新检查".localized)
                }
                .font(AppDialogTypography.body)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(isChecking)
        }
        .padding(.top, refreshPlacement == .bottom ? 2 : 0)
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在检查…".localized)
                .font(AppDialogTypography.body)
                .foregroundColor(.secondary)
        }
        .settingsCardBackground()
    }

    /// 重新执行三项检查。外部存储格式要问 diskutil，所以是异步的。
    private func refresh() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let result = await LaunchReadinessChecker().check()
            await MainActor.run {
                items = result
                isChecking = false
            }
        }
    }

    private func openSettings(for action: LaunchReadinessChecker.Item.Action) {
        for url in action.settingsURLs where NSWorkspace.shared.open(url) {
            return
        }
    }
}

// MARK: - 准备情况弹窗

/// 「设置」里点「检查」后弹出的准备情况面板。
struct ReadinessCheckSheet: View {
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
                    ReadinessCheckView()
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
private struct ReadinessCard: View {
    let item: LaunchReadinessChecker.Item
    let onAction: (LaunchReadinessChecker.Item.Action) -> Void

    var body: some View {
        SettingsStyleCard(
            icon: symbolName,
            iconColor: statusColor,
            title: item.title,
            detail: item.detail
        ) {
            if let action = item.action {
                Button(action: { onAction(action) }) {
                    HStack(spacing: 3) {
                        Text(action == .fullDiskAccess ? "打开系统设置".localized : "去授权".localized)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(AppDialogTypography.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("去设置授予权限".localized)
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
        case .warning: return "注意".localized
        case .failed: return "需要授权".localized
        }
    }

    private var statusColor: Color {
        switch item.level {
        case .ok: return .green
        case .warning: return .orange
        case .failed: return .red
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
    let accessory: Accessory

    init(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundColor(iconColor)

                    Text(title)
                        .font(AppDialogTypography.title)
                        .foregroundColor(.primary)
                }

                Text(detail)
                    .font(AppDialogTypography.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            accessory
        }
        .settingsCardBackground()
    }
}

extension SettingsStyleCard where Accessory == EmptyView {
    init(icon: String, iconColor: Color, title: String, detail: String) {
        self.init(icon: icon, iconColor: iconColor, title: title, detail: detail) {
            EmptyView()
        }
    }
}
