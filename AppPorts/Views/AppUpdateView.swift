import SwiftUI

/// The same value supplies both presentation and content. A separate Boolean
/// can open a sheet while its optional content still captures an empty value.
struct AppUpdatePresentation: ViewModifier {
    @Binding var update: AppUpdateInfo?

    func body(content: Content) -> some View {
        content
            .sheet(item: $update) { update in AppUpdateSheet(update: update) }
            .modifier(AppUpdatePresentationDismissal { update = nil })
    }
}

/// Attach at each presentation owner so AppKit dismissal cannot leave a true
/// SwiftUI binding that recreates the sheet during application termination.
struct AppUpdatePresentationDismissal: ViewModifier {
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .appPortsWillInstallUpdate)) { _ in
            dismiss()
        }
    }
}

struct AppUpdateActions: View {
    let update: AppUpdateInfo
    let dismiss: () -> Void
    @ObservedObject private var updater = AppUpdateController.shared
    @ObservedObject private var operations = AppOperationState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GitHubUpdateStatus()
            HStack(alignment: .center, spacing: 12) {
                Button("以后再说".localized, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                GitHubUpdateControls(update: update, showsStatus: false)
            }
            if updater.errorMessage != nil && !updater.isPreparing && !updater.isInstalling {
                Link("国内下载".localized, destination: update.chinaDownloadURL)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .buttonStyle(.bordered)
    }
}

struct GitHubUpdateStatus: View {
    @ObservedObject private var updater = AppUpdateController.shared
    @ObservedObject private var operations = AppOperationState.shared

    var body: some View {
        if let error = updater.errorMessage {
            AppUpdateErrorRow(message: error)
        } else if updater.isInstalling {
            Text("正在退出并安装更新…".localized).foregroundStyle(.secondary)
        } else if updater.isPreparing {
            VStack(alignment: .leading, spacing: 8) {
                Text(updater.progress < 1 ? "正在下载更新…".localized : "正在准备安装…".localized)
                    .foregroundStyle(.secondary)
                ProgressView(value: updater.progress)
            }
        } else if updater.prepared != nil {
            Text(updater.installationBlocked ? "请先结束迁移任务后再安装更新。".localized : "更新已准备好".localized)
                .foregroundStyle(.secondary)
        }
    }
}

struct AppUpdateErrorRow: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.red)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(message)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GitHubUpdateControls: View {
    var update: AppUpdateInfo?
    var showsStatus = true
    @ObservedObject private var updater = AppUpdateController.shared
    @ObservedObject private var operations = AppOperationState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsStatus { GitHubUpdateStatus() }
            HStack(spacing: 10) {
                if updater.isPreparing {
                    Button("取消".localized) { updater.cancel() }
                } else if updater.prepared != nil {
                    Button("取消".localized) { updater.cancel() }
                    Button("安装并重新启动".localized) { updater.install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.installationBlocked || updater.isInstalling)
                } else if let update {
                    Button("GitHub 更新".localized) { updater.download(update) }
                    Button("国内更新".localized) { updater.download(update, channel: .official) }
                }
            }
        }
    }
}

struct AppUpdateSheet: View {
    let update: AppUpdateInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("发现新版本".localized).font(AppDialogTypography.title)
                Text(verbatim: update.version).foregroundStyle(.secondary)
                Spacer()
            }
            MarkdownTextView(markdown: update.releaseNotesMarkdown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            AppUpdateActions(update: update, dismiss: { dismiss() })
        }
        .padding(20)
        .frame(width: 500, height: 400)
        .appDialogTypography()
    }
}

// MARK: - MarkdownTextView (NSTextView wrapper for Markdown rendering)
private struct MarkdownTextView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = NSColor.labelColor
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.boldSystemFont(ofSize: 13)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let codeBg = NSColor.separatorColor.withAlphaComponent(0.3)
        let textColor = NSColor.labelColor
        let linkColor = NSColor.linkColor
        let indentStyle: NSMutableParagraphStyle = {
            let s = NSMutableParagraphStyle()
            s.headIndent = 16
            s.firstLineHeadIndent = 16
            s.paragraphSpacing = 4
            return s
        }()

        var inCodeBlock = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                result.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: monoFont, .foregroundColor: textColor, .backgroundColor: codeBg
                ]))
                continue
            }

            let headingLevel = line.prefix(while: { $0 == "#" }).count
            let headingContent = line.dropFirst(headingLevel)
            if (1...6).contains(headingLevel), headingContent.first?.isWhitespace == true {
                let sizes: [CGFloat] = [22, 18, 15, 14, 13, 13]
                let font = NSFont.boldSystemFont(ofSize: sizes[headingLevel - 1])
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 8
                let content = headingContent.trimmingCharacters(in: .whitespaces)
                result.append(parseInlineMarkdown(content, baseFont: font, boldFont: font,
                    monoFont: monoFont, codeBg: codeBg, textColor: textColor,
                    linkColor: linkColor, paragraphStyle: style))
                result.append(NSAttributedString(string: "\n"))
            }
            // Unordered list
            else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = "• " + String(line.dropFirst(2))
                result.append(parseInlineMarkdown(content, baseFont: baseFont, boldFont: boldFont,
                    monoFont: monoFont, codeBg: codeBg, textColor: textColor, linkColor: linkColor, paragraphStyle: indentStyle))
                result.append(NSAttributedString(string: "\n"))
            }
            // Ordered list
            else if let dotRange = line.range(of: ". "),
                    let firstNum = Int(line[line.startIndex..<dotRange.lowerBound]),
                    line.startIndex != dotRange.lowerBound {
                let content = "\(firstNum). " + String(line[dotRange.upperBound...])
                result.append(parseInlineMarkdown(content, baseFont: baseFont, boldFont: boldFont,
                    monoFont: monoFont, codeBg: codeBg, textColor: textColor, linkColor: linkColor, paragraphStyle: indentStyle))
                result.append(NSAttributedString(string: "\n"))
            }
            // Empty line
            else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(NSAttributedString(string: "\n"))
            }
            // Normal text
            else {
                result.append(parseInlineMarkdown(line, baseFont: baseFont, boldFont: boldFont,
                    monoFont: monoFont, codeBg: codeBg, textColor: textColor, linkColor: linkColor))
                result.append(NSAttributedString(string: "\n"))
            }
        }
        textView.textStorage?.setAttributedString(result)
    }

    private func parseInlineMarkdown(_ text: String, baseFont: NSFont, boldFont: NSFont,
        monoFont: NSFont, codeBg: NSColor, textColor: NSColor, linkColor: NSColor,
        paragraphStyle: NSMutableParagraphStyle? = nil) -> NSAttributedString {
        var baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont, .foregroundColor: textColor
        ]
        if let paragraphStyle { baseAttributes[.paragraphStyle] = paragraphStyle }
        guard let parsed = try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: baseAttributes)
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = baseAttributes
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.stronglyEmphasized) ? boldFont : baseFont
            if intent.contains(.code) {
                font = monoFont
                attributes[.backgroundColor] = codeBg
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            attributes[.font] = font
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
