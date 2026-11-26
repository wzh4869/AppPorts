//
//  BoundaryConsensusView.swift
//  AppPorts
//
//  关于 AppPorts 的边界与共识：欢迎页、升级一次性确认与设置页阅读面板共用的内容和状态判定。
//

import AppKit
import SwiftUI

// MARK: - 欢迎与边界确认启动策略

/// 欢迎入口的展示形态。
enum WelcomePresentationMode: Equatable, Sendable {
    /// 全新用户：完整 3 步引导（概览 → 边界与共识 → 准备情况）。
    case fullOnboarding
    /// 已完成旧版欢迎页的升级老用户：仅展示一次单屏「边界与共识」。
    case boundaryConsensusOnly
}

/// 决定应用启动时是否展示欢迎或边界确认页，并保持 `welcomeCompleted` 语义稳定。
///
/// `LegacyPermissionResetter` 依赖 `welcomeCompleted == true` 识别老用户，
/// 因此升级老用户的边界确认使用独立版本号键记录，绝不重置 `welcomeCompleted`。
enum WelcomeLaunchPolicy {
    static let welcomeCompletedDefaultsKey = "welcomeCompleted"
    static let boundaryConsensusVersionDefaultsKey = "boundaryConsensusAcknowledgedVersion"
    static let currentBoundaryConsensusVersion = 1

    static func presentationMode(defaults: UserDefaults = .standard) -> WelcomePresentationMode? {
        if !defaults.bool(forKey: welcomeCompletedDefaultsKey) {
            return .fullOnboarding
        }
        if defaults.integer(forKey: boundaryConsensusVersionDefaultsKey) < currentBoundaryConsensusVersion {
            return .boundaryConsensusOnly
        }
        return nil
    }

    static func recordFullOnboardingCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: welcomeCompletedDefaultsKey)
        defaults.set(currentBoundaryConsensusVersion, forKey: boundaryConsensusVersionDefaultsKey)
    }

    static func recordBoundaryConsensusAcknowledged(defaults: UserDefaults = .standard) {
        defaults.set(currentBoundaryConsensusVersion, forKey: boundaryConsensusVersionDefaultsKey)
    }
}

// MARK: - 视觉令牌与辅助链接

enum BoundaryConsensusStyle {
    static let githubIssuesURL = URL(string: "https://github.com/wzh4869/AppPorts/issues")!
    static let githubIssuesLabel = "GitHub Issues"

    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.035)
            : .white
    })

    static let cardBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.11)
            : NSColor.black.withAlphaComponent(0.095)
    })

    static let quoteSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
    })

    static let linkBlue = Color(nsColor: .linkColor)

    static let mutedSlateBlue = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 96 / 255, green: 165 / 255, blue: 250 / 255, alpha: 1)
            : NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1)
    })

    static let mutedAmber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 251 / 255, green: 191 / 255, blue: 36 / 255, alpha: 1)
            : NSColor(srgbRed: 194 / 255, green: 114 / 255, blue: 12 / 255, alpha: 1)
    })

    static let mutedTeal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 52 / 255, green: 211 / 255, blue: 153 / 255, alpha: 1)
            : NSColor(srgbRed: 15 / 255, green: 138 / 255, blue: 112 / 255, alpha: 1)
    })
}

extension View {
    func editorialCardStyle(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(BoundaryConsensusStyle.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(BoundaryConsensusStyle.cardBorder, lineWidth: 1)
            )
    }
}

// MARK: - 富文本段落构建

/// 使用 `AttributedString` 在本地化模板中插入加粗与可点击链接片段，
/// 避免跨语种词序冲突、CommonMark 标点边界失效及 `Text + Text` 弃用告警。
enum EditorialRichText {
    private static let placeholderRegex = try! NSRegularExpression(pattern: #"%(\d+)\$@|%@"#)

    static func body(_ text: String, size: CGFloat = 13) -> AttributedString {
        var result = AttributedString(text)
        result.font = .system(size: size)
        result.foregroundColor = .secondary
        return result
    }

    static func emphasis(_ text: String, size: CGFloat = 13) -> AttributedString {
        var result = AttributedString(text)
        result.font = .system(size: size, weight: .semibold)
        result.foregroundColor = .primary
        return result
    }

    static func link(_ label: String, destination: URL, size: CGFloat = 13) -> AttributedString {
        var result = AttributedString(label + " ↗")
        result.font = .system(size: size, weight: .medium)
        result.foregroundColor = BoundaryConsensusStyle.linkBlue
        result.underlineStyle = .single
        result.link = destination
        return result
    }

    /// 组合「行内加粗小标题 + 正文」。
    static func leadAndBody(lead: String, body: AttributedString, size: CGFloat = 13) -> AttributedString {
        var result = emphasis(lead, size: size)
        result.append(body)
        return result
    }

    /// 按模板中的 `%1$@`、`%2$@` 或顺序 `%@` 占位符拼接富文本片段。
    static func format(_ template: String, segments: [AttributedString], size: CGFloat = 13) -> AttributedString {
        var result = AttributedString()
        let nsTemplate = template as NSString
        let matches = placeholderRegex.matches(
            in: template,
            range: NSRange(location: 0, length: nsTemplate.length)
        )

        var cursor = 0
        var sequentialIndex = 0
        for match in matches {
            if match.range.location > cursor {
                let chunk = nsTemplate.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(body(chunk, size: size))
            }

            let segmentIndex: Int
            if match.range(at: 1).location != NSNotFound,
               let positional = Int(nsTemplate.substring(with: match.range(at: 1))) {
                segmentIndex = positional - 1
            } else {
                segmentIndex = sequentialIndex
                sequentialIndex += 1
            }

            if segments.indices.contains(segmentIndex) {
                result.append(segments[segmentIndex])
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < nsTemplate.length {
            let trailing = nsTemplate.substring(from: cursor)
            result.append(body(trailing, size: size))
        }
        return result
    }
}

// MARK: - 共享正文组件

/// 「关于 AppPorts 的边界与共识」共享内容视图，供欢迎页与设置页弹窗复用。
struct BoundaryConsensusContentView: View {
    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some View {
        let docsURL = DocumentationLink.homeURL(language: languageManager.language == "system"
            ? DocumentationLink.currentLanguage
            : languageManager.language)

        VStack(alignment: .leading, spacing: 13) {
            Text("AppPorts 做的，是改变 macOS 与许多应用在设计上的默认前提——在尽量不破坏原有签名与沙盒机制的前提下，将原本默认驻留在内置盘的应用本体与数据，通过启动壳、符号链接或 APFS 卷挂载等方式迁移到你指定的外部存储。".localized)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.primary)
                    .frame(width: 3, height: 20)
                    .accessibilityHidden(true)

                Text("但请记住：AppPorts 不是神，它只是一把精密的手术刀。".localized)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(BoundaryConsensusStyle.quoteSurface)
            )

            VStack(spacing: 10) {
                EditorialBoundaryCard(
                    icon: "square.grid.2x2",
                    color: BoundaryConsensusStyle.mutedSlateBlue,
                    attributedText: EditorialRichText.leadAndBody(
                        lead: "无法穷举的生态：".localized,
                        body: EditorialRichText.body(
                            "macOS 生态下有成千上万款应用，每款软件对路径硬编码、沙盒与权限校验（Sandbox / TCC）、文件所有权、签名与自更新机制及后台守护进程的实现各不相同。我们无法穷举测试所有应用，也无法保证 AppPorts 对你电脑里的每一个软件都 100% 兼容。".localized
                        )
                    )
                )

                EditorialBoundaryCard(
                    icon: "exclamationmark.triangle",
                    color: BoundaryConsensusStyle.mutedAmber,
                    attributedText: EditorialRichText.leadAndBody(
                        lead: "风险与自由并存：".localized,
                        body: EditorialRichText.body(
                            "脱离系统和应用默认的本地盘假设，意味着你需要承担相应的不确定性。轻则应用闪退、配置重置、更新异常或权限失效；重则因外盘意外断开、离线写入分叉或操作失误，引发数据不可见、损坏甚至丢失。".localized
                        )
                    )
                )

                EditorialBoundaryCard(
                    icon: "exclamationmark.shield",
                    color: BoundaryConsensusStyle.mutedTeal,
                    attributedText: EditorialRichText.leadAndBody(
                        lead: "对数据保持敬畏：".localized,
                        body: EditorialRichText.format(
                            "在点击任何迁移、还原、解绑、重签名或清理旧副本等操作前，请务必仔细核对状态与提示。操作前建议先查阅 %1$@；你也可以将对应文档页（或页面内的 Markdown 内容）发给 AI，让它帮你快速解读原理并评估目标应用的迁移风险。同时，请务必确认目标磁盘的连接稳定性，%2$@。".localized,
                            segments: [
                                EditorialRichText.link("AppPorts 官方文档".localized, destination: docsURL),
                                EditorialRichText.emphasis(
                                    "操作前先做好备份；另外注意，Time Machine 默认只备份 Mac 内置硬盘，迁到外置盘里的重要数据请自己另外留一份备份".localized
                                )
                            ]
                        )
                    )
                )
            }

            Text(
                EditorialRichText.format(
                    "AppPorts 的各项保护机制，正是在一次次真实实验与踩坑中逐步打磨出来的。如果你在使用过程中遇到了异常、兼容性问题，或者有更好的改进建议，欢迎通过 %@（提交 Bug 时建议通过「日志 → 导出诊断包」附带诊断信息）或其他社区渠道反馈给我。".localized,
                    segments: [
                        EditorialRichText.link(BoundaryConsensusStyle.githubIssuesLabel, destination: BoundaryConsensusStyle.githubIssuesURL)
                    ]
                )
            )
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 1)

            Text("AppPorts 赋予你掌控存储空间的自由，但数据的最终安全，永远掌握在你自己手中。".localized)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

private struct EditorialBoundaryCard: View {
    let icon: String
    let color: Color
    let attributedText: AttributedString

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.10))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(color)
                }
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text(attributedText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .editorialCardStyle(padding: 13)
    }
}

// MARK: - 设置页阅读弹窗

/// 设置页「边界与共识」按钮弹出的只读面板。
struct BoundaryConsensusSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)

                Text("关于 AppPorts 的边界与共识".localized)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("关闭".localized)
                .accessibilityLabel("关闭".localized)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView(.vertical) {
                BoundaryConsensusContentView()
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 22)
            }

            HStack {
                Spacer(minLength: 0)
                Button("关闭".localized) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .background(AppSurfaceColors.content)
        }
        .background(AppSurfaceColors.content)
        .frame(width: 620, height: 670)
    }
}
