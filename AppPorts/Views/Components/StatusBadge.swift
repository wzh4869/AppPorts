//
//  StatusBadge.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI

// MARK: - 状态徽章组件

/// 用未翻译的标签内容在当前语言和栏宽下还原上次扫描的徽章。
struct AppBadgeLayout: Codable, Equatable, Sendable {
    struct Label: Codable, Equatable, Sendable {
        let prefix: String?
        let text: String
        let icon: String

        var color: Color {
            switch text {
            case "未知", "检测中": return .secondary
            case AppStatus.linked, "锁定迁移": return .green
            case AppStatus.unlinked, AppStatus.external, "非锁定迁移", "签名待检查", "已暂停": return .orange
            case AppStatus.partialLinked, "等待中": return .yellow
            case AppStatus.orphanedLink, "签名已替换": return .red
            case AppStatus.pendingMoveOut: return .cyan
            case "运行中": return .purple
            case "系统": return .gray
            case "非原生": return .pink
            case "已重签名": return .teal
            default: return .blue
            }
        }

        var accessibilityTitle: String {
            if let prefix { return "\(localizedStatusBadgeText(prefix)): \(localizedStatusBadgeText(text))" }
            return localizedStatusBadgeText(text)
        }
    }

    let update: Label?
    let status: [Label]
    let signature: Label?
}

extension AppBadgeLayout {
    init(app: AppItem, context: UpdateRecommendationContext) {
        let presentation = AppBadgePresentation(app: app, updateContext: context)
        let badges = presentation.badges
        update = badges.update?.label
        status = badges.status.map(\.label)
        signature = presentation.signature?.label
    }

    init(previewing app: AppItem, context: UpdateRecommendationContext) {
        guard let cached = app.cachedBadgeLayout else {
            self.init(app: app, context: context)
            return
        }
        guard app.hasVerifiedUpdateInspection else { self = cached; return }
        // 更新组件的核对也会读取锁和应用类型。运行及签名仍要等目录扫描返回。
        var preview = app
        preview.isRunning = cached.status.contains { $0.text == "运行中" }
        let current = AppBadgePresentation(app: preview, updateContext: context).badges
        self.init(update: current.update?.label, status: current.status.map(\.label), signature: cached.signature)
    }
}

private struct BadgeConfig: Identifiable {
    var id: String { prefix.map { "\($0)|\(text)" } ?? text }
    let prefix: String?
    let text: String
    let icon: String
    let isTappable: Bool

    init(prefix: String? = nil, text: String, icon: String, isTappable: Bool) {
        self.prefix = prefix
        self.text = text
        self.icon = icon
        self.isTappable = isTappable
    }

    var label: AppBadgeLayout.Label { .init(prefix: prefix, text: text, icon: icon) }
}

private struct BadgeCapsuleLabel: View {
    let label: AppBadgeLayout.Label
    private var color: Color { label.color }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: label.icon)
                .font(.system(size: 9, weight: .bold))
            if let prefix = label.prefix {
                Text(localizedStatusBadgeText(prefix))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Rectangle()
                    .fill(color.opacity(0.35))
                    .frame(width: 0.75, height: 9)
            }
            Text(localizedStatusBadgeText(label.text))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(color)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(color.opacity(0.2), lineWidth: 0.5)
        )
    }
}

private func localizedStatusBadgeText(_ text: String) -> String {
    switch text {
    case AppStatus.linked, AppStatus.unlinked, AppStatus.partialLinked, AppStatus.orphanedLink, AppStatus.external, AppStatus.pendingMoveOut:
        return AppStatus.localized(text)
    case "更新": return "更新".localized
    case "自有": return "自有".localized
    case "可用": return "可用".localized
    case "检测中": return "检测中".localized
    case "未知": return "未知".localized
    case "锁定迁移":
        return "锁定迁移".localized
    case "非锁定迁移":
        return "非锁定迁移".localized
    case "运行中":
        return "运行中".localized
    case "系统":
        return "系统".localized
    case "非原生":
        return "非原生".localized
    case "商店":
        return "商店".localized
    case "已重签名":
        return "已重签名".localized
    case "签名已替换":
        return "签名已替换".localized
    case "签名待检查":
        return "签名待检查".localized
    case "处理中":
        return "处理中".localized
    case "等待中":
        return "等待中".localized
    case "已暂停":
        return "已暂停".localized
    default:
        return text
    }
}

private struct UpdateRecommendationKey: EnvironmentKey {
    static let defaultValue = UpdateRecommendationContext(guardian: .unavailable)
}

extension EnvironmentValues {
    var updateRecommendation: UpdateRecommendationContext {
        get { self[UpdateRecommendationKey.self] }
        set { self[UpdateRecommendationKey.self] = newValue }
    }
}

private struct AppBadgePresentation {
    let app: AppItem
    let updateContext: UpdateRecommendationContext

    var updateAvailability: UpdateAvailability {
        if app.updateRoute == .appPorts { return .appPorts }
        guard app.bundleIsLocked == false else { return .unknown }
        return app.updateRoute.availability(in: updateContext,
            beforeStoreMigration: app.willMigrateToStoreDirectory)
    }

    /// 所有适用的标签列表
    var badges: (update: BadgeConfig?, status: [BadgeConfig]) {
        var result: [BadgeConfig] = []

        // 1. 链接状态标签
        if app.status == AppStatus.linked {
            if let locked = app.bundleIsLocked, locked || app.needsLock {
                result.append(BadgeConfig(
                    text: locked ? "锁定迁移" : "非锁定迁移",
                    icon: locked ? "lock.fill" : "lock.open",
                    isTappable: true
                ))
            } else {
                // 原生自更新 app（Chrome、Edge 等）不加锁，显示"已链接"
                result.append(BadgeConfig(text: AppStatus.linked, icon: "link", isTappable: false))
            }
        } else if app.status == AppStatus.partialLinked {
            result.append(BadgeConfig(text: AppStatus.partialLinked, icon: "link.badge.plus", isTappable: false))
        } else if app.status == AppStatus.orphanedLink {
            result.append(BadgeConfig(text: AppStatus.orphanedLink, icon: "exclamationmark.triangle", isTappable: false))
        } else if app.status == AppStatus.unlinked {
            result.append(BadgeConfig(text: AppStatus.unlinked, icon: "externaldrive.badge.xmark", isTappable: false))
        } else if app.status == AppStatus.external {
            result.append(BadgeConfig(text: AppStatus.external, icon: "externaldrive", isTappable: false))
        } else if app.status == AppStatus.pendingMoveOut {
            result.append(BadgeConfig(text: AppStatus.pendingMoveOut, icon: "arrow.up.right.circle", isTappable: true))
        }

        // 2. 类型标签
        if app.isRunning {
            result.append(BadgeConfig(text: "运行中", icon: "play.fill", isTappable: false))
        } else if app.isSystemApp {
            result.append(BadgeConfig(text: "系统", icon: "lock.fill", isTappable: false))
        } else if app.isIOSApp {
            result.append(BadgeConfig(text: "非原生", icon: "iphone", isTappable: false))
        } else if app.isAppStoreApp {
            result.append(BadgeConfig(text: "商店", icon: "applelogo", isTappable: AppMigrationService.isMASExternalInstallSupported))
        }

        if app.updateRoute == .appPorts {
            return (BadgeConfig(prefix: "更新", text: updateAvailability.badgeTitle, icon: "arrow.triangle.2.circlepath",
                                isTappable: true), result)
        }

        if !app.isSystemApp && !app.isIOSApp && !app.isFolder &&
            app.status != AppStatus.orphanedLink && app.status != AppStatus.pendingMoveOut {
            if app.bundleIsLocked == true && [AppStatus.external, AppStatus.unlinked].contains(app.status) {
                result.append(BadgeConfig(text: "锁定迁移", icon: "lock.fill", isTappable: true))
            } else if app.bodyMigrationPolicy == .standard && (app.bundleIsLocked != true || app.status == AppStatus.local) {
                let available = updateAvailability.isAvailable
                if available && updateContext.guardian != .disabled {
                    result.removeAll { $0.text == "非锁定迁移" }
                }
                let update = BadgeConfig(prefix: "更新", text: updateAvailability.badgeTitle, icon: "arrow.triangle.2.circlepath",
                                         isTappable: true)
                return (update, result)
            }
        }
        return (nil, result)
    }

    var signature: BadgeConfig? {
        if app.signatureReplaced {
            return BadgeConfig(text: "签名已替换", icon: "exclamationmark.triangle", isTappable: true)
        }
        if app.signatureCheckUnavailable {
            return BadgeConfig(text: "签名待检查", icon: "questionmark.circle", isTappable: true)
        }
        if app.isResigned {
            return BadgeConfig(text: "已重签名", icon: "seal.fill", isTappable: false)
        }
        return nil
    }
}

/// 应用状态徽章视图
///
/// 以胶囊形状的徽章显示应用的当前状态，包括：
/// - ✅ 已链接（绿色）：应用已迁移到外部存储并创建了符号链接
/// - ▶️ 运行中（紫色）：应用当前正在运行
/// - 🔒 系统（灰色）：macOS 系统应用
/// - 📱 非原生（粉色）：iOS/iPadOS 应用（通过 Apple Silicon 运行）
/// - 🏪 商店（蓝色）：Mac App Store 应用
/// - 📀 未链接（橙色）：应用在外部存储但未链接回本地
///
/// ## 设计特点
/// - 使用 SF Symbols 图标增强视觉识别
/// - 颜色编码快速传达状态信息
/// - 圆角胶囊形状现代简洁
/// - 半透明背景和边框提升层次感
///
/// - Note: 自动支持无障碍功能（Accessibility）
struct StatusBadge: View {
    /// 应用项目数据
    let app: AppItem
    /// 签名被替换时的修复入口：给了回调就点开修复面板，没给就只是个静态徽章。
    var onRepairSignature: ((AppItem) -> Void)? = nil
    var showsCachedBadges = false
    var activeTaskStatus: String? = nil
    var onViewTask: (() -> Void)? = nil
    @Environment(\.updateRecommendation) private var updateContext

    @Environment(\.isEnabled) private var isEnabled

    private var presentation: AppBadgePresentation {
        AppBadgePresentation(app: app, updateContext: updateContext)
    }

    /// 点击标签时显示的说明文字
    private func badgeInfoMessage(for badge: BadgeConfig) -> String? {
        switch badge.text {
        case "待迁出":
            return UpdateAvailability.moveOut.explanation
        case "锁定迁移":
            return "此应用已被迁移到外部存储并锁定。锁定状态可防止应用内更新破坏外部应用。如需更新，请通过 AppPorts 迁回本地后再更新。".localized
        case "非锁定迁移":
            return "此应用已迁移到外部存储且未加锁，可尝试继续使用应用内更新。在设置中开启“应用更新守护”后，AppPorts 可协助处理更新异常，但无法保证所有应用都能处理成功。".localized
        case "商店" where presentation.updateAvailability == .store && !app.willMigrateToStoreDirectory:
            return "此应用位于外部磁盘的 Applications 目录，由 macOS 原生管理（macOS 15.1+ 功能）。App Store 可直接在此目录进行增量更新，无需通过 AppPorts 迁回。".localized
        default:
            return nil
        }
    }

    private func readOnlyBadge(_ label: AppBadgeLayout.Label) -> some View {
        BadgeCapsuleLabel(label: label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label.accessibilityTitle)
    }

    var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                BadgeFlowLayout(spacing: 6) { content }
            } else {
                VStack(alignment: .leading, spacing: 6) { content }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var content: some View {
        if showsCachedBadges {
            let layout = AppBadgeLayout(previewing: app, context: updateContext)
            if app.cachedBadgeLayout != nil || app.hasVerifiedUpdateInspection {
                readOnlyBadges(layout)
            } else {
                // 早期清单没有徽章快照，只用估算的布局占位。
                readOnlyBadges(layout).hidden()
            }
        } else if !isEnabled {
            readOnlyBadges(AppBadgeLayout(app: app, context: updateContext))
        } else {
            badgeContent
        }
    }

    @ViewBuilder private func readOnlyBadges(_ layout: AppBadgeLayout) -> some View {
        if let update = layout.update { readOnlyBadge(update) }
        if let task = activeTaskBadgeConfig { readOnlyBadge(task.label) }
        ForEach(layout.status.indices, id: \.self) { readOnlyBadge(layout.status[$0]) }
        if let signature = layout.signature { readOnlyBadge(signature) }
    }

    private var activeTaskBadgeConfig: BadgeConfig? {
        guard let activeTaskStatus else { return nil }
        switch activeTaskStatus {
        case "已暂停":
            return BadgeConfig(text: activeTaskStatus, icon: "pause.circle", isTappable: true)
        case "等待中":
            return BadgeConfig(text: activeTaskStatus, icon: "clock", isTappable: true)
        default:
            return BadgeConfig(text: activeTaskStatus, icon: "arrow.triangle.2.circlepath", isTappable: true)
        }
    }

    private var badgeContent: some View {
        let badges = presentation.badges
        return Group {
            if let updateBadge = badges.update {
                TappableBadge(badge: updateBadge, message: presentation.updateAvailability.explanation)
            }

            if let taskBadge = activeTaskBadgeConfig {
                if let onViewTask {
                    TappableBadge(badge: taskBadge, action: onViewTask, actionHelp: "查看进度".localized)
                } else {
                    readOnlyBadge(taskBadge.label)
                }
            }

            ForEach(badges.status) { badge in
                if badge.isTappable, let message = badgeInfoMessage(for: badge) {
                    TappableBadge(badge: badge, message: message)
                } else {
                    readOnlyBadge(badge.label)
                }
            }

            if let signature = presentation.signature {
                if signature.isTappable {
                    TappableBadge(badge: signature, action: onRepairSignature.map { handler in { handler(app) } },
                                  actionHelp: app.signatureReplaced ? "查看修复步骤".localized : "检查签名".localized)
                } else {
                    readOnlyBadge(signature.label)
                }
            }
        }
    }
}

/// 可点击标签：有 `action` 就执行动作，否则弹一段说明（独立 popover，避免 race condition）
private struct TappableBadge: View {
    let badge: BadgeConfig
    /// 点击后弹的说明；给 `action` 时不用传。
    var message: String? = nil
    /// 点击后执行的动作，优先级高于 `message`。
    var action: (() -> Void)? = nil
    var actionHelp: String = "查看修复步骤".localized
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isPageActive) private var isPageActive
    @State private var isPresented = false
    @State private var hoverPreview = false
    @State private var overBadge = false
    @State private var overMessage = false
    @State private var pendingHover: Task<Void, Never>?

    var body: some View {
        Button {
            pendingHover?.cancel()
            activate(onHover: false)
        } label: {
            BadgeCapsuleLabel(label: badge.label)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge.label.accessibilityTitle)
        .accessibilityHint(action == nil ? (message ?? "") : actionHelp)
        .onHover { inside in
            guard isPageActive else {
                overBadge = false
                return
            }
            overBadge = inside
            updateHover()
        }
        .popover(isPresented: $isPresented) {
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .padding(12)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .onHover { inside in
                        overMessage = inside
                        updateHover()
                    }
            }
        }
        .onChange(of: isPageActive) { active in
            if !active {
                pendingHover?.cancel()
                overBadge = false
                overMessage = false
                hoverPreview = false
                isPresented = false
            }
        }
        .onChange(of: isPresented) { presented in
            if !presented {
                pendingHover?.cancel()
                hoverPreview = false
                overMessage = false
            }
        }
        .onDisappear {
            pendingHover?.cancel()
            overBadge = false
            overMessage = false
            isPresented = false
        }
    }

    private func activate(onHover: Bool) {
        guard isEnabled, isPageActive else { return }
        if let action {
            action()
        } else if message != nil {
            hoverPreview = onHover
            isPresented = true
        }
    }

    private func updateHover() {
        pendingHover?.cancel()
        if overBadge && !isPresented && isEnabled && isPageActive && (message != nil || action != nil) {
            pendingHover = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, isPageActive else { return }
                activate(onHover: true)
            }
        } else if hoverPreview && isPresented && !overBadge && !overMessage {
            // Allow the pointer to cross the gap between the capsule and its popover.
            pendingHover = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                isPresented = false
            }
        }
    }
}

/// 标签在内容列内换行，避免把行尾的操作按钮挤出对齐位置。
@available(macOS 13.0, *)
private struct BadgeFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y),
                anchor: .topLeading,
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, positions: [CGPoint], sizes: [CGSize]) {
        let limit = max(1, width ?? .greatestFiniteMagnitude)
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, limit), height: nil))
            if x > 0 && x + size.width > limit {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            sizes.append(size)
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), positions, sizes)
    }
}
