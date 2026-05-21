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
    let id = UUID()
    let text: String
    let icon: String
    let color: Color
    let isTappable: Bool
}

struct StatusBadge: View {
    /// 应用项目数据
    let app: AppItem

    /// 所有适用的标签列表
    private var badges: [BadgeConfig] {
        var result: [BadgeConfig] = []

        // 1. 链接状态标签
        if app.status == "已链接" {
            if app.needsLock {
                let locked = Self.isExternalAppLocked(app: app)
                result.append(BadgeConfig(
                    text: locked ? "锁定迁移" : "非锁定迁移",
                    icon: locked ? "lock.fill" : "lock.open",
                    color: locked ? .green : .orange,
                    isTappable: true
                ))
            } else if app.hasSelfUpdater {
                // 原生自更新 app（Chrome、Edge 等）不加锁，显示"已链接"
                result.append(BadgeConfig(text: "已链接", icon: "link", color: .green, isTappable: false))
            } else {
                result.append(BadgeConfig(text: "已链接", icon: "link", color: .green, isTappable: false))
            }
        } else if app.status == "部分链接" {
            result.append(BadgeConfig(text: "部分链接", icon: "link.badge.plus", color: .yellow, isTappable: false))
        } else if app.status == "孤立链接" {
            result.append(BadgeConfig(text: "孤立链接", icon: "link.badge.exclamationmark", color: .red, isTappable: false))
        } else if app.status == "未链接" {
            result.append(BadgeConfig(text: "未链接", icon: "externaldrive.badge.xmark", color: .orange, isTappable: false))
        } else if app.status == "外部" {
            result.append(BadgeConfig(text: "外部", icon: "externaldrive", color: .orange, isTappable: false))
        }

        // 2. 框架标签（独立于链接状态）
        if app.isSparkleApp {
            result.append(BadgeConfig(text: "Sparkle", icon: "arrow.triangle.2.circlepath", color: .teal, isTappable: true))
        }
        if app.isElectronApp {
            result.append(BadgeConfig(text: "Electron", icon: "atom", color: .indigo, isTappable: true))
        }

        // 3. 类型标签
        if app.isRunning {
            result.append(BadgeConfig(text: "运行中", icon: "play.fill", color: .purple, isTappable: false))
        } else if app.isSystemApp {
            result.append(BadgeConfig(text: "系统", icon: "lock.fill", color: .gray, isTappable: false))
        } else if app.isIOSApp {
            result.append(BadgeConfig(text: "非原生", icon: "iphone", color: .pink, isTappable: false))
        } else if app.isAppStoreApp {
            result.append(BadgeConfig(text: "商店", icon: "applelogo", color: .blue, isTappable: AppMigrationService.isMASExternalInstallSupported))
        }

        // 5. MAS 外部安装标签（复用商店标签，附加外部安装说明）
        if app.isMASExternal && !app.isAppStoreApp {
            result.append(BadgeConfig(text: "商店", icon: "applelogo", color: .blue, isTappable: true))
        }

        // 4. 如果没有任何标签，显示"本地"
        if result.isEmpty {
            result.append(BadgeConfig(text: "本地", icon: "macmini", color: .secondary, isTappable: false))
        }

        return result
    }
    
    /// 检查外部 app 是否被 uchg 锁定
    private static func isExternalAppLocked(app: AppItem) -> Bool {
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
    private static func resolveExternalPath(from url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        let resolved = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        return resolved.path.hasPrefix("/Volumes/") ? resolved.path : nil
    }

    /// stub portal：从原生 launcher 的 real_app_path.txt 或旧版 bash 脚本提取外部路径
    private static func resolveExternalPathFromLauncher(app: AppItem) -> String? {
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
    private static func resolveExternalPathFromContents(app: AppItem) -> String? {
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
        case "Sparkle":
            return "此应用使用 Sparkle 框架自动更新。迁移到外部存储后，应用内更新可能导致外部应用丢失。建议使用锁定迁移保护数据安全。".localized
        case "Electron":
            return "此应用基于 Electron 框架，支持自动更新。迁移到外部存储后，应用内更新可能导致外部应用丢失。建议使用锁定迁移保护数据安全。".localized
        case "锁定迁移":
            return "此应用已被迁移到外部存储并锁定。锁定状态可防止应用内更新破坏外部应用。如需更新，请通过 AppPorts 迁回本地后再更新。".localized
        case "非锁定迁移":
            return "此应用已迁移到外部存储但未锁定。应用内更新可能删除外部应用。建议迁回本地后重新迁移并选择锁定模式。".localized
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
            Text(badge.text.localized)
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(badge.color)
        .background(badge.color.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(badge.color.opacity(0.2), lineWidth: 0.5)
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges) { badge in
                if badge.isTappable, let message = badgeInfoMessage(for: badge) {
                    TappableBadge(badge: badge, message: message)
                } else {
                    badgeView(for: badge)
                }
            }

            if app.isResigned {
                badgeView(for: BadgeConfig(text: "已重签名", icon: "seal.fill", color: .teal, isTappable: false))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            (app.isResigned ? "已重签名, ".localized : "") +
            badges.map { $0.text.localized }.joined(separator: ", ")
        )
        .accessibilityAddTraits(.isStaticText)
    }
}

/// 可点击标签（独立 popover，避免 race condition）
private struct TappableBadge: View {
    let badge: BadgeConfig
    let message: String
    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.icon)
                .font(.system(size: 9, weight: .bold))
            Text(badge.text.localized)
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(badge.color)
        .background(badge.color.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(badge.color.opacity(0.2), lineWidth: 0.5)
        )
        .onTapGesture { isPresented = true }
        .popover(isPresented: $isPresented) {
            Text(message)
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
