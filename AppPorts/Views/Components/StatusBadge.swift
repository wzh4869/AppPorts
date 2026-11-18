//
//  StatusBadge.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI

// MARK: - 状态徽章组件

/// 应用状态徽章视图
///
/// 以胶囊形状的徽章显示应用的当前状态，包括：
/// - ✅ 已链接（绿色）：应用已迁移到外部存储并创建了符号链接
/// - ▶️ 运行中（紫色）：应用当前正在运行
/// - 🔒 系统（灰色）：macOS 系统应用
/// - 📱 非原生（粉色）：iOS/iPadOS 应用（通过 Apple Silicon 运行）
/// - 🏪 商店（蓝色）：Mac App Store 应用
/// - 📀 未链接（橙色）：应用在外部存储但未链接回本地
/// - 💻 本地（次要色）：普通本地应用
///
/// ## 设计特点
/// - 使用 SF Symbols 图标增强视觉识别
/// - 颜色编码快速传达状态信息
/// - 圆角胶囊形状现代简洁
/// - 半透明背景和边框提升层次感
///
/// - Note: 自动支持无障碍功能（Accessibility）
private struct BadgeConfig: Identifiable {
    var id: String { text }
    let text: String
    let icon: String
    let color: Color
    let isTappable: Bool
}

private func localizedStatusBadgeText(_ text: String) -> String {
    switch text {
    case AppStatus.local, AppStatus.linked, AppStatus.unlinked, AppStatus.partialLinked, AppStatus.orphanedLink, AppStatus.external, AppStatus.pendingMoveOut:
        return AppStatus.localized(text)
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

struct StatusBadge: View {
    /// 应用项目数据
    let app: AppItem
    /// 签名被替换时的修复入口：给了回调就点开修复面板，没给就只是个静态徽章。
    var onRepairSignature: ((AppItem) -> Void)? = nil
    var activeTaskStatus: String? = nil
    var onViewTask: (() -> Void)? = nil
    @State private var externalAppLocked: Bool?

    private struct LockRequest: Hashable {
        let path: URL
        let status: String
        let needsLock: Bool
        let hasSelfUpdater: Bool
        let version: String?
    }

    /// 所有适用的标签列表
    private var badges: [BadgeConfig] {
        var result: [BadgeConfig] = []

        // 1. 链接状态标签
        if app.status == AppStatus.linked {
            if let locked = externalAppLocked, locked || app.needsLock {
                result.append(BadgeConfig(
                    text: locked ? "锁定迁移" : "非锁定迁移",
                    icon: locked ? "lock.fill" : "lock.open",
                    color: locked ? .green : .orange,
                    isTappable: true
                ))
            } else {
                // 原生自更新 app（Chrome、Edge 等）不加锁，显示"已链接"
                result.append(BadgeConfig(text: AppStatus.linked, icon: "link", color: .green, isTappable: false))
            }
        } else if app.status == AppStatus.partialLinked {
            result.append(BadgeConfig(text: AppStatus.partialLinked, icon: "link.badge.plus", color: .yellow, isTappable: false))
        } else if app.status == AppStatus.orphanedLink {
            result.append(BadgeConfig(text: AppStatus.orphanedLink, icon: "exclamationmark.triangle", color: .red, isTappable: false))
        } else if app.status == AppStatus.unlinked {
            result.append(BadgeConfig(text: AppStatus.unlinked, icon: "externaldrive.badge.xmark", color: .orange, isTappable: false))
        } else if app.status == AppStatus.external {
            result.append(BadgeConfig(text: AppStatus.external, icon: "externaldrive", color: .orange, isTappable: false))
        } else if app.status == AppStatus.pendingMoveOut {
            result.append(BadgeConfig(text: AppStatus.pendingMoveOut, icon: "arrow.up.right.circle", color: .cyan, isTappable: false))
        }

        // 2. 类型标签
        if app.isRunning {
            result.append(BadgeConfig(text: "运行中", icon: "play.fill", color: .purple, isTappable: false))
        } else if app.isSystemApp {
            result.append(BadgeConfig(text: "系统", icon: "lock.fill", color: .gray, isTappable: false))
        } else if app.isIOSApp {
            result.append(BadgeConfig(text: "非原生", icon: "iphone", color: .pink, isTappable: false))
        } else if app.isAppStoreApp {
            result.append(BadgeConfig(text: "商店", icon: "applelogo", color: .blue, isTappable: AppMigrationService.isMASExternalInstallSupported))
        }

        // 3. MAS 外部安装标签（复用商店标签，附加外部安装说明）
        if app.isMASExternal && !app.isAppStoreApp {
            result.append(BadgeConfig(text: "商店", icon: "applelogo", color: .blue, isTappable: true))
        }

        // 4. 如果没有任何标签，显示"本地"
        if result.isEmpty {
            result.append(BadgeConfig(text: AppStatus.local, icon: "macmini", color: .secondary, isTappable: false))
        }

        return result
    }
    
    /// 检查外部 app 是否被 uchg 锁定
    nonisolated private static func isExternalAppLocked(app: AppItem) -> Bool {
        let externalPath: String

        // 外部 app：直接检查自身
        if app.path.path.hasPrefix("/Volumes/") {
            externalPath = app.path.path
        }
        // wholeAppSymlink：整个 .app 是符号链接，解析目标
        else if let resolved = resolveExternalPath(from: app.path) {
            externalPath = resolved
        }
        // stub portal：从 launcher 脚本提取外部路径
        else if let resolved = resolveExternalPathFromLauncher(app: app) {
            externalPath = resolved
        }
        // deepContentsWrapper：解析 Contents/ 符号链接目标
        else if let resolved = resolveExternalPathFromContents(app: app) {
            externalPath = resolved
        }
        else {
            return false
        }

        // 检查 uchg 标志
        var statBuf = stat()
        guard stat(externalPath, &statBuf) == 0 else { return false }
        return (statBuf.st_flags & UInt32(UF_IMMUTABLE)) != 0
    }

    /// wholeAppSymlink：解析符号链接目标
    nonisolated private static func resolveExternalPath(from url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        let resolved = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        return resolved.path.hasPrefix("/Volumes/") ? resolved.path : nil
    }

    /// stub portal：从原生 launcher 的 real_app_path.txt 或旧版 bash 脚本提取外部路径
    nonisolated private static func resolveExternalPathFromLauncher(app: AppItem) -> String? {
        // 新版原生 launcher：从 real_app_path.txt 读取
        let pathFile = app.path.appendingPathComponent("Contents/Resources/real_app_path.txt")
        if let raw = try? String(contentsOf: pathFile, encoding: .utf8),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.hasPrefix("/Volumes/") ? path : nil
        }

        // 旧版 bash launcher：从脚本中提取 REAL_APP='...'
        let launcher = app.path.appendingPathComponent("Contents/MacOS/launcher")
        guard let script = try? String(contentsOf: launcher, encoding: .utf8),
              let range = script.range(of: "REAL_APP='") else { return nil }
        let afterQuote = script[range.upperBound...]
        guard let endQuote = afterQuote.range(of: "'") else { return nil }
        let path = String(afterQuote[..<endQuote.lowerBound])
        return path.hasPrefix("/Volumes/") ? path : nil
    }

    /// deepContentsWrapper：解析 Contents/ 符号链接目标
    nonisolated private static func resolveExternalPathFromContents(app: AppItem) -> String? {
        let contents = app.path.appendingPathComponent("Contents")
        guard let values = try? contents.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: contents.path) else {
            return nil
        }
        let resolved = URL(fileURLWithPath: dest, relativeTo: contents.deletingLastPathComponent()).standardizedFileURL
        // Contents/ 指向外部 app 的 Contents/，需要上跳一级
        let externalApp = resolved.deletingLastPathComponent()
        return externalApp.path.hasPrefix("/Volumes/") ? externalApp.path : nil
    }

    /// 点击标签时显示的说明文字
    private func badgeInfoMessage(for badge: BadgeConfig) -> String? {
        switch badge.text {
        case "锁定迁移":
            return "此应用已被迁移到外部存储并锁定。锁定状态可防止应用内更新破坏外部应用。如需更新，请通过 AppPorts 迁回本地后再更新。".localized
        case "非锁定迁移":
            return "此应用已迁移到外部存储且未加锁，可尝试继续使用应用内更新。在设置中开启“应用更新守护”后，AppPorts 可协助处理更新异常，但无法保证所有应用都能处理成功。".localized
        case "商店" where app.isMASExternal:
            return "此应用位于外部磁盘的 Applications 目录，由 macOS 原生管理（macOS 15.1+ 功能）。App Store 可直接在此目录进行增量更新，无需通过 AppPorts 迁回。".localized
        default:
            return nil
        }
    }

    /// 单个标签胶囊
    private func badgeView(for badge: BadgeConfig) -> some View {
        HStack(spacing: 4) {
            Image(systemName: badge.icon)
                .font(.system(size: 9, weight: .bold))
            Text(localizedStatusBadgeText(badge.text))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(badge.color)
        .background(badge.color.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(badge.color.opacity(0.2), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localizedStatusBadgeText(badge.text))
    }

    var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                BadgeFlowLayout(spacing: 6) { badgeContent }
            } else {
                VStack(alignment: .leading, spacing: 6) { badgeContent }
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: LockRequest(path: app.path, status: app.status, needsLock: app.needsLock,
                              hasSelfUpdater: app.hasSelfUpdater, version: app.version)) {
            externalAppLocked = nil
            guard app.needsLock || app.hasSelfUpdater, app.status == AppStatus.linked else { return }
            let inspectedApp = app
            let worker = Task.detached(priority: .utility) {
                Self.isExternalAppLocked(app: inspectedApp)
            }
            let locked = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            externalAppLocked = locked
        }
    }

    private var signatureAccessibilityLabel: String {
        var prefix = activeTaskStatus.map { localizedStatusBadgeText($0) + ", " } ?? ""
        if app.signatureReplaced { prefix += "签名已替换".localized + ", " }
        else if app.signatureCheckUnavailable { prefix += "签名待检查".localized + ", " }
        else if app.isResigned { prefix += "已重签名".localized + ", " }
        return prefix
    }

    private var activeTaskBadgeConfig: BadgeConfig? {
        guard let activeTaskStatus else { return nil }
        switch activeTaskStatus {
        case "已暂停":
            return BadgeConfig(text: activeTaskStatus, icon: "pause.circle", color: .orange, isTappable: true)
        case "等待中":
            return BadgeConfig(text: activeTaskStatus, icon: "clock", color: .secondary, isTappable: true)
        default:
            return BadgeConfig(text: activeTaskStatus, icon: "arrow.triangle.2.circlepath", color: .blue, isTappable: true)
        }
    }

    private var badgeContent: some View {
        Group {
            if let taskBadge = activeTaskBadgeConfig {
                if let onViewTask {
                    TappableBadge(badge: taskBadge, action: onViewTask, actionHelp: "查看进度".localized)
                } else {
                    badgeView(for: taskBadge)
                }
            }

            ForEach(badges) { badge in
                if badge.isTappable, let message = badgeInfoMessage(for: badge) {
                    TappableBadge(badge: badge, message: message)
                } else {
                    badgeView(for: badge)
                }
            }

            if app.signatureReplaced {
                // 徽章本身就是入口：点它直接打开修复面板，不用去右键菜单里翻。
                TappableBadge(
                    badge: BadgeConfig(text: "签名已替换", icon: "exclamationmark.shield.fill", color: .red, isTappable: true),
                    action: onRepairSignature.map { handler in { handler(app) } }
                )
            } else if app.signatureCheckUnavailable {
                TappableBadge(
                    badge: BadgeConfig(text: "签名待检查", icon: "questionmark.circle", color: .orange, isTappable: true),
                    action: onRepairSignature.map { handler in { handler(app) } }
                )
            } else if app.isResigned {
                badgeView(for: BadgeConfig(text: "已重签名", icon: "seal.fill", color: .teal, isTappable: false))
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
    @State private var isPresented = false

    var body: some View {
        Button {
            if let action {
                action()
            } else {
                isPresented = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: badge.icon)
                    .font(.system(size: 9, weight: .bold))
                Text(localizedStatusBadgeText(badge.text))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(badge.color)
            .background(badge.color.opacity(0.1))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(badge.color.opacity(0.2), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localizedStatusBadgeText(badge.text))
        .help(action == nil ? (message ?? "") : actionHelp)
        .popover(isPresented: $isPresented) {
            Text(message ?? "")
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
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
