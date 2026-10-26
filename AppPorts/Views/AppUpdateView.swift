import SwiftUI

struct AppUpdateActions: View {
    let update: AppUpdateInfo

    var body: some View {
        if update.source == .official {
            Link("国内下载".localized, destination: update.chinaDownloadURL)
        } else {
            GitHubUpdateControls(update: update)
        }
    }
}

struct GitHubUpdateControls: View {
    var update: AppUpdateInfo?
    @ObservedObject private var updater = AppUpdateController.shared
    @ObservedObject private var operations = AppOperationState.shared
    @State private var confirmInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if updater.isPreparing {
                Text(updater.progress < 1 ? "正在下载更新…".localized : "正在准备安装…".localized)
                ProgressView(value: updater.progress)
                Button("取消".localized) { updater.cancel() }
            } else if let prepared = updater.prepared {
                HStack {
                    Text(verbatim: prepared.version).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消".localized) { updater.cancel() }
                    Button("安装并重新启动".localized) { confirmInstall = true }
                        .disabled(operations.isBusy)
                }
                if operations.isBusy {
                    Text("还有任务尚未结束".localized).foregroundStyle(.secondary)
                }
            } else if let update {
                HStack(spacing: 16) {
                    if update.githubAsset != nil {
                        Button("下载更新".localized) { updater.download(update) }
                    }
                    if let url = update.githubURL {
                        Link("GitHub".localized, destination: url)
                    }
                }
                if update.githubAsset == nil {
                    Text(AppUpdateError.package.localizedDescription).foregroundStyle(.secondary)
                }
            }
            if let error = updater.errorMessage {
                Text(error).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("安装并重新启动".localized, isPresented: $confirmInstall) {
            Button("取消".localized, role: .cancel) {}
            Button("安装并重新启动".localized) { updater.install() }
        } message: {
            Text("安装后将退出并重新打开 AppPorts。".localized)
        }
    }
}

struct AppUpdateSheet: View {
    let update: AppUpdateInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("发现新版本".localized).font(.headline)
                Text(verbatim: update.version).foregroundStyle(.secondary)
                Spacer()
                Button("以后再说".localized) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            MarkdownTextView(markdown: update.releaseNotesMarkdown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            AppUpdateActions(update: update)
        }
        .padding(20)
        .frame(width: 500, height: 400)
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

        for line in text.components(separatedBy: "\n") {
            // Header
            if line.hasPrefix("### ") {
                let s = NSMutableParagraphStyle(); s.paragraphSpacing = 8
                result.append(NSAttributedString(string: String(line.dropFirst(4)) + "\n",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: textColor, .paragraphStyle: s]))
            } else if line.hasPrefix("## ") {
                let s = NSMutableParagraphStyle(); s.paragraphSpacing = 8
                result.append(NSAttributedString(string: String(line.dropFirst(3)) + "\n",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: textColor, .paragraphStyle: s]))
            } else if line.hasPrefix("# ") {
                let s = NSMutableParagraphStyle(); s.paragraphSpacing = 8
                result.append(NSAttributedString(string: String(line.dropFirst(2)) + "\n",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: textColor, .paragraphStyle: s]))
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
            // Code block separator
            else if line.hasPrefix("```") {
                // skip
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
        let result = NSMutableAttributedString()
        var remaining = text[...]
        let baseAttrs: [NSAttributedString.Key: Any] = {
            var a: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: textColor]
            if let ps = paragraphStyle { a[.paragraphStyle] = ps }
            return a
        }()
        let boldAttrs: [NSAttributedString.Key: Any] = {
            var a: [NSAttributedString.Key: Any] = [.font: boldFont, .foregroundColor: textColor]
            if let ps = paragraphStyle { a[.paragraphStyle] = ps }
            return a
        }()

        while !remaining.isEmpty {
            // **bold**
            if let r = remaining.range(of: "**") {
                if let end = remaining[r.upperBound...].range(of: "**") {
                    // text before bold
                    if r.lowerBound > remaining.startIndex {
                        result.append(NSAttributedString(string: String(remaining[..<r.lowerBound]), attributes: baseAttrs))
                    }
                    // bold text
                    result.append(NSAttributedString(string: String(remaining[r.upperBound..<end.lowerBound]), attributes: boldAttrs))
                    remaining = remaining[end.upperBound...]
                    continue
                }
            }
            // *italic*
            if let r = remaining.range(of: "*") {
                if let end = remaining[r.upperBound...].range(of: "*") {
                    if r.lowerBound > remaining.startIndex {
                        result.append(NSAttributedString(string: String(remaining[..<r.lowerBound]), attributes: baseAttrs))
                    }
                    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                    var attrs = baseAttrs; attrs[.font] = italicFont
                    result.append(NSAttributedString(string: String(remaining[r.upperBound..<end.lowerBound]), attributes: attrs))
                    remaining = remaining[end.upperBound...]
                    continue
                }
            }
            // `code`
            if let r = remaining.range(of: "`") {
                if let end = remaining[r.upperBound...].range(of: "`") {
                    if r.lowerBound > remaining.startIndex {
                        result.append(NSAttributedString(string: String(remaining[..<r.lowerBound]), attributes: baseAttrs))
                    }
                    var attrs: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: textColor, .backgroundColor: codeBg]
                    if let ps = paragraphStyle { attrs[.paragraphStyle] = ps }
                    result.append(NSAttributedString(string: String(remaining[r.upperBound..<end.lowerBound]), attributes: attrs))
                    remaining = remaining[end.upperBound...]
                    continue
                }
            }
            // [text](url)
            if let r = remaining.range(of: "[") {
                if let paren = remaining[r.upperBound...].range(of: "]("),
                   let end = remaining[paren.upperBound...].range(of: ")") {
                    if r.lowerBound > remaining.startIndex {
                        result.append(NSAttributedString(string: String(remaining[..<r.lowerBound]), attributes: baseAttrs))
                    }
                    let linkText = String(remaining[r.upperBound..<paren.lowerBound])
                    let linkURL = String(remaining[paren.upperBound..<end.lowerBound])
                    var attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
                    if let url = URL(string: linkURL) { attrs[.link] = url }
                    if let ps = paragraphStyle { attrs[.paragraphStyle] = ps }
                    result.append(NSAttributedString(string: linkText, attributes: attrs))
                    remaining = remaining[end.upperBound...]
                    continue
                }
            }
            // plain text
            result.append(NSAttributedString(string: String(remaining), attributes: baseAttrs))
            break
        }
        return result
    }
}
