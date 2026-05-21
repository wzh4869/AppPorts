//
//  ContentView.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI
import AppKit

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

// NOTE: AppItem and AppMoverError are in AppModels.swift
// NOTE: AppLogger is in Services/AppLogger.swift

// MARK: - UI 组件 (已提取到 Views/Components/)
// ProgressOverlay -> Views/Components/ProgressOverlay.swift
// StatusBadge -> Views/Components/StatusBadge.swift
// AppIconView -> Views/Components/AppIconView.swift
// AppRowView -> Views/Components/AppRowView.swift



// MARK: - 主视图
struct ContentView: View {

    @State private var localApps: [AppItem] = []
    @State private var externalApps: [AppItem] = []
    
    @State private var searchText: String = ""
    
    private let localAppsURL = URL(fileURLWithPath: "/Applications")
    @State private var externalDriveURL: URL?

    // 多选支持
    @State private var selectedLocalApps: Set<String> = []
    @State private var selectedExternalApps: Set<String> = []
    
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    @State private var showUpdateAlert = false
    @State private var updateURL: URL?
    @State private var updateReleaseBody = ""
    
    // App Store 应用迁移确认
    @State private var showAppStoreConfirm = false
    @State private var pendingAppStoreApps: [AppItem] = []

    // 自更新应用迁移确认（Sparkle/Electron，锁定模式保护）
    @State private var showSelfUpdaterConfirm = false
    @State private var pendingSelfUpdaterApps: [AppItem] = []
    @State private var pendingRemainingAppsForSelfUpdater: [AppItem] = []
    @State private var selfUpdaterIsLinkIn = false // true = 链接回本地, false = 迁移到外部

    @State private var pendingRemainingApps: [AppItem] = []
    
    // 进度弹窗状态
    @State private var showProgress = false
    @State private var progressCurrent = 0
    @State private var progressTotal = 0
    @State private var progressAppName = ""
    @State private var isMigrating = false
    
    // App Store 外部安装引导
    @State private var showMASGuidance = false

    // 设置页面
    @State private var showAppStoreSettings = false
    
    // 单应用复制进度
    @State private var progressBytes: Int64 = 0
    @State private var progressTotalBytes: Int64 = 0

    private let fileManager = FileManager.default

    // Monitors
    @State private var localMonitor: FolderMonitor?
    @State private var externalMonitor: FolderMonitor?

    // Monitor 防抖：合并两个 monitor 的扫描请求
    private static let monitorRescanDebouncer = RescanDebouncer()

    // Track previous external drive URL for logging
    @State private var previousExternalDriveURL: URL?

    enum SortOption {
        case name, size
    }
    @State private var sortOption: SortOption = .name

    // MARK: - Tab
    enum MainTab { case apps, dataDirs }
    @State private var mainTab: MainTab = .apps

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Toolbar
            HStack(spacing: 16) {
                // Tab 切换器
                HStack(spacing: 2) {
                    TabButton(title: "📦 " + "应用".localized, isSelected: mainTab == .apps) {
                        withAnimation { mainTab = .apps }
                    }
                    TabButton(title: "🗄️ " + "数据目录".localized, isSelected: mainTab == .dataDirs) {
                        withAnimation { mainTab = .dataDirs }
                    }
                }
                .padding(3)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                if mainTab == .apps {
                    // Search Bar
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("搜索应用 (本地 / 外部)...".localized, text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )

                    // Sort Button
                    Menu {
                        Button(action: { sortOption = .name }) {
                            HStack {
                                Text("按名称".localized)
                                Spacer()
                                if sortOption == .name { Image(systemName: "checkmark") }
                            }
                        }
                        Button(action: { sortOption = .size }) {
                            HStack {
                                Text("按大小".localized)
                                Spacer()
                                if sortOption == .size { Image(systemName: "checkmark") }
                            }
                        }
                    } label: {
                        Label("排序".localized, systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("排序方式".localized)
                }

                Spacer()

                // App Store Settings Button（始终显示）
                Button(action: { showAppStoreSettings = true }) {
                    Label("设置".localized, systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("App Store 应用迁移设置".localized)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider()

            // MARK: - 主内容区（Tab 切换）
            if mainTab == .dataDirs {
                DataDirsView(
                    externalDriveURL: externalDriveURL,
                    localApps: localApps,
                    onSelectExternalDrive: openPanelForExternalDrive,
                    onResignApp: performSingleResign,
                    onRestoreSignature: performRestoreSignature,
                    onBackupSignature: performBackupSignature,
                    resolveRealAppURL: resolveRealAppURL(for:),
                    onResignAppAtURL: { url, silent in
                        performResign(at: url, bundleID: getBundleIdentifier(from: url), silent: silent)
                    },
                    onBackupSignatureForURL: { url in
                        performBackupSignature(at: url, bundleID: getBundleIdentifier(from: url))
                    }
                )
            } else {

            HSplitView {
                // --- 左侧：本地应用 ---
                VStack(spacing: 0) {
                    // Header Area (Restored to original simple style)
                    HeaderView(title: "Mac 本地应用".localized, subtitle: "/Applications", icon: "macmini") {
                        scanLocalApps()
                    }
                    
                    ZStack {
                        Color(nsColor: .controlBackgroundColor).ignoresSafeArea()
                        
                        if filteredLocalApps.isEmpty {
                            if searchText.isEmpty {
                                EmptyStateView(icon: "magnifyingglass", text: "正在扫描...".localized)
                            } else {
                                EmptyStateView(icon: "doc.text.magnifyingglass", text: "未找到匹配应用".localized)
                            }
                        } else {
                            List(filteredLocalApps, selection: $selectedLocalApps) { app in
                                AppRowView(
                                    app: app,
                                    isSelected: selectedLocalApps.contains(app.id),
                                    showDeleteLinkButton: true,
                                    showMoveBackButton: false,
                                    onDeleteLink: performDeleteLink,
                                    onMoveBack: performMoveBack,
                                    onResign: { performSingleResign(app: $0) },
                                    onRestoreSignature: performRestoreSignature,
                                    onMoveOutWholeSymlink: performMoveOutWholeSymlink
                                )
                                .tag(app.id)
                                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)) // Add spacing around rows
                            }
                            .listStyle(.plain)
                        }
                    }
                    
                    let buttonStatus = getMoveButtonTitle()
                    
                    ActionFooter(
                        title: buttonStatus.text,
                        icon: "arrow.right",
                        isEnabled: canMoveOut,
                        action: performMoveOut
                    )
                }
                .frame(minWidth: 320, maxWidth: .infinity)
                
                // --- 右侧：外部应用 ---
                VStack(spacing: 0) {
                    HeaderView(
                        title: "外部应用库".localized,
                        subtitle: externalDriveURL?.path ?? "未选择".localized,
                        icon: "externaldrive.fill",
                        actionButtonText: "选择文件夹".localized,
                        onAction: openPanelForExternalDrive,
                        onRefresh: { scanExternalApps() }
                    )
                
                ZStack {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                    
                    if externalDriveURL == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "externaldrive.badge.plus")
                                .font(.system(size: 40))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(.accentColor)
                            
                            // 【修复点 2】直接使用字面量，SwiftUI 会自动翻译
                            Text("请选择外部存储路径".localized)
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            Button("选择文件夹".localized) { openPanelForExternalDrive() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                    } else if filteredExternalApps.isEmpty {
                        EmptyStateView(icon: "folder", text: "空文件夹".localized)
                    } else {
                        List(filteredExternalApps, selection: $selectedExternalApps) { app in
                            AppRowView(
                                app: app,
                                isSelected: selectedExternalApps.contains(app.id),
                                showDeleteLinkButton: false,
                                showMoveBackButton: false,
                                onDeleteLink: performDeleteLink,
                                onMoveBack: performMoveBack,
                                onResign: { performSingleResign(app: $0) },
                                onRestoreSignature: performRestoreSignature
                            )
                            .tag(app.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        }
                        .listStyle(.plain)
                    }
                }
                
                // 双按钮底部栏
                VStack(spacing: 0) {
                    Divider()
                        .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: -1)

                    HStack(spacing: 8) {
                        Button(action: performLinkIn) {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.system(size: 12, weight: .medium))
                                Text(getLinkButtonTitle())
                                    .fontWeight(.medium)
                                    .font(.system(size: 13))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(!canLinkIn)

                        Button(action: performBatchMoveBack) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.up.left")
                                    .font(.system(size: 12, weight: .medium))
                                Text(getMoveBackButtonTitle())
                                    .fontWeight(.medium)
                                    .font(.system(size: 13))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange.opacity(0.85))
                        .disabled(selectedExternalApps.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(.bar)
            }
            .frame(minWidth: 320, maxWidth: .infinity)
            } // end HSplitView for mainTab == .apps
            } // end else for mainTab == .apps
        }
        .frame(minWidth: 900, minHeight: 600) // Increased window size
        .onAppear {
            // Restore persistence
            if let savedPath = UserDefaults.standard.string(forKey: "ExternalDrivePath") {
                let url = URL(fileURLWithPath: savedPath)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: savedPath, isDirectory: &isDir), isDir.boolValue {
                    self.externalDriveURL = url
                    AppLogger.shared.logContext(
                        "恢复已保存的外部路径",
                        details: [("path", savedPath), ("is_directory", isDir.boolValue ? "true" : "false")]
                    )
                    AppLogger.shared.logExternalDriveInfo(at: url)
                } else {
                    AppLogger.shared.logContext(
                        "已保存的外部路径无效，忽略",
                        details: [("path", savedPath)],
                        level: "WARN"
                    )
                }
            }
            
            AppLogger.shared.log("主界面已出现，开始初始化扫描与监控")
            scanLocalApps()
            
            // Start local monitoring
            startMonitoringLocal()
            
            // Check for updates
            Task {
                do {
                    if let release = try await UpdateChecker.shared.checkForUpdates() {
                        AppLogger.shared.logContext(
                            "检测到新版本",
                            details: [
                                ("tag", release.tagName),
                                ("url", release.htmlUrl)
                            ]
                        )
                        await MainActor.run {
                            self.updateReleaseBody = release.body
                            self.updateURL = URL(string: release.htmlUrl)
                            self.showUpdateAlert = true
                        }
                    }
                } catch {
                    AppLogger.shared.logError("检查更新失败", error: error)
                }
            }
        }
        .onChange(of: externalDriveURL) { newValue in
            AppLogger.shared.logContext(
                "外部路径变更",
                details: [
                    ("old_path", previousExternalDriveURL?.path),
                    ("new_path", newValue?.path)
                ]
            )
            previousExternalDriveURL = newValue
            // Persistence
            if let url = newValue {
                UserDefaults.standard.set(url.path, forKey: "ExternalDrivePath")
                startMonitoringExternal(url: url)
            } else {
                UserDefaults.standard.removeObject(forKey: "ExternalDrivePath")
                stopMonitoringExternal()
            }
            scanExternalApps()

            // macOS >= 15.1: 检查外部磁盘的 Applications 目录
            if let url = newValue, AppMigrationService.isMASExternalInstallSupported {
                let masDir = AppMigrationService.masApplicationsURL(for: url)
                if !fileManager.fileExists(atPath: masDir.path) {
                    showMASGuidance = true
                }
            }
        }
        
        .alert(LocalizedStringKey(alertTitle.localized), isPresented: $showAlert) {
            Button("好的".localized, role: .cancel) { }
        } message: {
            Text(LocalizedStringKey(alertMessage.localized))
        }
        .sheet(isPresented: $showUpdateAlert) {
            VStack(alignment: .leading, spacing: 16) {
                Text("发现新版本".localized)
                    .font(.headline)
                MarkdownTextView(markdown: updateReleaseBody)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Spacer()
                    Button("以后再说".localized) {
                        showUpdateAlert = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("前往下载".localized) {
                        showUpdateAlert = false
                        if let url = updateURL { NSWorkspace.shared.open(url) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 480, height: 360)
        }
        // App Store 应用迁移确认弹窗
        .alert("App Store 应用".localized, isPresented: $showAppStoreConfirm) {
            Button("继续迁移".localized, role: .none) {
                if let dest = externalDriveURL {
                    executeBatchMove(apps: pendingAppStoreApps, destination: dest)
                }
                pendingAppStoreApps = []
            }
            Button("取消".localized, role: .cancel) {
                pendingAppStoreApps = []
            }
        } message: {
            let count = Int64(pendingAppStoreApps.filter { isAppStoreApp(at: $0.displayURL) }.count)
            let totalCount = Int64(pendingAppStoreApps.count)
            if count == totalCount {
                Text(String(format: "选中的 %lld 个应用均来自 App Store，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\n\n这是正常的，应用会被安全地移动到外部存储。".localized, totalCount))
            } else {
                Text(String(format: "选中的 %lld 个应用包含 %lld 个 App Store 应用，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\n\n这是正常的，应用会被安全地移动到外部存储。".localized, totalCount, count))
            }
        }
        // 自更新应用迁移确认弹窗
        .alert("自更新应用迁移".localized, isPresented: $showSelfUpdaterConfirm) {
            Button("锁定迁移".localized) {
                let allApps = pendingSelfUpdaterApps + pendingRemainingAppsForSelfUpdater
                if selfUpdaterIsLinkIn {
                    executeBatchLinkIn(apps: allApps, lockExternal: true)
                } else if let dest = externalDriveURL {
                    executeBatchMove(apps: allApps, destination: dest, lockExternal: true)
                }
                pendingSelfUpdaterApps = []
                pendingRemainingAppsForSelfUpdater = []
            }
            Button("非锁定迁移".localized) {
                let allApps = pendingSelfUpdaterApps + pendingRemainingAppsForSelfUpdater
                if selfUpdaterIsLinkIn {
                    executeBatchLinkIn(apps: allApps, lockExternal: false)
                } else if let dest = externalDriveURL {
                    executeBatchMove(apps: allApps, destination: dest, lockExternal: false)
                }
                pendingSelfUpdaterApps = []
                pendingRemainingAppsForSelfUpdater = []
            }
            Button("取消".localized, role: .cancel) {
                pendingSelfUpdaterApps = []
                pendingRemainingAppsForSelfUpdater = []
            }
        } message: {
            let names = pendingSelfUpdaterApps.map { $0.displayName }.joined(separator: "、")
            Text(String(format: "以下应用支持自动更新，迁移后应用内更新可能导致外部应用丢失：\n\n%@\n\n• 锁定迁移：外部应用被锁定，阻止更新破坏，需通过 AppPorts 迁回后更新\n• 非锁定迁移：不锁定外部应用，应用内更新可能删除外部应用\n\n建议选择锁定迁移以保护数据安全。".localized, names))
        }
        // App Store 外部安装引导弹窗
        .alert("App Store 应用外部安装".localized, isPresented: $showMASGuidance) {
            Button("打开 App Store 设置".localized) {
                if let url = URL(string: "macappstores://settings") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("我已设置".localized) {
                // 检查 Applications 目录是否存在，不存在则创建
                if let url = externalDriveURL {
                    let masDir = AppMigrationService.masApplicationsURL(for: url)
                    if !fileManager.fileExists(atPath: masDir.path) {
                        try? fileManager.createDirectory(at: masDir, withIntermediateDirectories: true)
                        AppLogger.shared.logContext(
                            "已创建外部磁盘 Applications 目录",
                            details: [("path", masDir.path)]
                        )
                    }
                }
                scanExternalApps()
            }
            Button("稍后".localized, role: .cancel) {}
        } message: {
            Text("macOS 15.1+ 支持将 App Store 应用安装到外部磁盘。\n\n请在 App Store → 设置中勾选「将大型 App 下载并安装到独立磁盘」，并选择当前外部驱动器。\n\n设置完成后点击「我已设置」，AppPorts 会自动创建 Applications 目录并检测管理这些应用。".localized)
        }
        // App Store 设置页面
        .sheet(isPresented: $showAppStoreSettings) {
            AppStoreSettingsView()
        }
        // 进度覆盖层
        .overlay {
            if showProgress {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    ProgressOverlay(
                        current: progressCurrent,
                        total: progressTotal,
                        appName: progressAppName,
                        copiedBytes: progressBytes,
                        totalBytes: progressTotalBytes
                    )
                }
            }
        }
    }
    
    // MARK: - 过滤逻辑
    
    var filteredLocalApps: [AppItem] {
        let apps = localApps
        let filtered = searchText.isEmpty ? apps : apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) || $0.name.localizedCaseInsensitiveContains(searchText)
        }
        
        return sortApps(filtered)
    }
    
    var filteredExternalApps: [AppItem] {
        let apps = externalApps
        let filtered = searchText.isEmpty ? apps : apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) || $0.name.localizedCaseInsensitiveContains(searchText)
        }
        
        return sortApps(filtered)
    }
    
    func sortApps(_ apps: [AppItem]) -> [AppItem] {
        switch sortOption {
        case .name:
            // Already sorted by name in scanner, but good to ensure
            return apps // Scanner already sorts by Link status then Name
        case .size:
            return apps.sorted { 
                 // Keep "Linked" on top? Maybe not for size sort. Let's strict size sort.
                 // Or, if user wants size, we just sort by size.
                 if $0.sizeBytes == $1.sizeBytes {
                     return $0.displayName < $1.displayName
                 }
                 return $0.sizeBytes > $1.sizeBytes // Descending
            }
        }
    }
    
    // MARK: - 辅助组件
    
    struct HeaderView: View {
        let title: String
        let subtitle: String // subtitle 可能是路径，也可能是 "未选择"
        let icon: String
        var actionButtonText: String? = nil
        var onAction: (() -> Void)? = nil
        let onRefresh: () -> Void
        
        var body: some View {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                        .frame(width: 32)
                        
                    VStack(alignment: .leading, spacing: 4) {
                        // 将传入的 title 字符串转换为 Key，触发翻译
                        Text(title.localized)
                            .font(.headline)
                        
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(subtitle)
                    }
                    Spacer()
                    
                    if let btnText = actionButtonText, let action = onAction {

                        Button(btnText.localized, action: action)
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                    
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
                    .help("刷新列表".localized)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                Divider()
            }
            .background(.ultraThinMaterial) // Glassmorphism
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
    
    struct ActionFooter: View {
        let title: String
        let icon: String
        let isEnabled: Bool
        let action: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                Divider()
                    .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: -1)

                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(title.localized)
                            .fontWeight(.medium)
                            .font(.system(size: 13))
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isEnabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.bar)
        }
    }
    
    struct EmptyStateView: View {
        let icon: String
        let text: String
        
        var body: some View {
            VStack(spacing: 10) {
                Image(systemName: icon)
                .font(.largeTitle)
                .foregroundColor(.secondary.opacity(0.3))

                Text(text.localized)
                .foregroundColor(.secondary.opacity(0.7))
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Tab 切换按钮（顶部工具栏用）
    struct TabButton: View {
        let title: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title.localized)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 逻辑函数
    
    func getMoveButtonTitle() -> (text: String, isError: Bool) {
        // 获取所有选中且可迁移的应用
        let validApps = selectedLocalApps.compactMap { id in
            localApps.first { $0.id == id }
        }.filter { !$0.isSystemApp && !$0.isRunning && $0.status != "已链接" }
        
        if selectedLocalApps.isEmpty {
            return ("迁移到外部".localized, false)
        }

        if validApps.isEmpty {
            // 检查是否全是不可迁移的
            let selectedAppsData = selectedLocalApps.compactMap { id in localApps.first { $0.id == id } }
            if selectedAppsData.contains(where: { $0.isSystemApp }) { return ("含系统应用".localized, true) }
            if selectedAppsData.contains(where: { $0.isRunning }) { return ("含运行中应用".localized, true) }
            if selectedAppsData.contains(where: { $0.status == "已链接" }) { return ("已链接".localized, false) }
            return ("迁移到外部".localized, false)
        }

        if validApps.count == 1 {
            return ("迁移到外部".localized, false)
        }
        
        return (String(format: "迁移 %lld 个应用".localized, Int64(validApps.count)), false)
    }
    
    var canMoveOut: Bool {
        guard externalDriveURL != nil else { return false }
        
        // 至少有一个可迁移的应用
        let validApps = selectedLocalApps.compactMap { id in
            localApps.first { $0.id == id }
        }.filter { !$0.isSystemApp && !$0.isRunning && $0.status != "已链接" }
        
        return !validApps.isEmpty
    }
    
    var canLinkIn: Bool {
        // 至少有一个可链接的应用
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { $0.status == "未链接" || $0.status == "外部" }
        
        return !validApps.isEmpty
    }
    
    func getLinkButtonTitle() -> String {
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { $0.status == "未链接" || $0.status == "外部" }
        
        if selectedExternalApps.isEmpty || validApps.isEmpty {
            return "链接回本地".localized
        }
        
        if validApps.count == 1 {
            return "链接回本地".localized
        }
        
        return String(format: "链接 %lld 个应用".localized, Int64(validApps.count))
    }
    
    func getRunningAppURLs() -> Set<URL> {
        let runningApps = NSWorkspace.shared.runningApplications
        let urls = runningApps.compactMap { $0.bundleURL }
        return Set(urls)
    }

    nonisolated func joinedAppNames(_ apps: [AppItem]) -> String {
        guard !apps.isEmpty else { return "(none)" }
        return apps.map(\.displayName).joined(separator: ", ")
    }

    nonisolated func summarizeStatuses(for apps: [AppItem]) -> String {
        guard !apps.isEmpty else { return "(none)" }
        let counts = Dictionary(grouping: apps, by: \.status).map { key, value in
            "\(key)=\(value.count)"
        }
        return counts.sorted().joined(separator: ", ")
    }

    nonisolated func migrationSkipReason(
        for app: AppItem,
        allowAppStoreMigration: Bool,
        allowIOSAppMigration: Bool
    ) -> String? {
        if app.isSystemApp {
            return "system_app"
        }
        if app.isRunning {
            return "running"
        }
        if app.status == "已链接" {
            return "already_linked"
        }
        if app.isIOSApp && !allowIOSAppMigration {
            return "ios_migration_disabled"
        }
        if app.isAppStoreApp && !allowAppStoreMigration {
            return "app_store_migration_disabled"
        }
        return nil
    }
    
    func scanLocalApps(calculateSizes: Bool = true) {
        let scanID = AppLogger.shared.makeOperationID(prefix: "scan-local-apps")
        AppLogger.shared.logContext(
            "开始扫描本地应用",
            details: [("scan_id", scanID), ("directory", localAppsURL.path)]
        )
        // Run on background task to avoid blocking Main Thread
        Task.detached(priority: .userInitiated) {
            // Gather data needed for scanning
            let runningAppURLs = await MainActor.run { self.getRunningAppURLs() }
            let scanDir = self.localAppsURL
            
            // Use Actor
            let scanner = AppScanner()
            let newApps = await scanner.scanLocalApps(at: scanDir, runningAppURLs: runningAppURLs)
            
            await MainActor.run {
                self.localApps = newApps
            }
            AppLogger.shared.logContext(
                "本地应用扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("count", String(newApps.count)),
                    ("status_summary", self.summarizeStatuses(for: newApps))
                ]
            )
            
            if calculateSizes {
                await self.calculateSizesProgressive(for: newApps, isLocal: true, scanner: scanner)
            }
        }
    }

    private func readVersion(from appURL: URL) -> String {
        let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        return (plist?["CFBundleShortVersionString"] as? String) ?? ""
    }

    func scanExternalApps(calculateSizes: Bool = true) {
        guard let dir = externalDriveURL else {
            AppLogger.shared.log("未选择外部路径，清空外部应用列表", level: "TRACE")
            self.externalApps = []
            return
        }
        
        let scanID = AppLogger.shared.makeOperationID(prefix: "scan-external-apps")
        AppLogger.shared.logContext(
            "开始扫描外部应用",
            details: [
                ("scan_id", scanID),
                ("directory", dir.path),
                ("local_directory", "/Applications")
            ]
        )
        
        Task.detached(priority: .userInitiated) {
            let scanDir = dir
            let localDir = URL(fileURLWithPath: "/Applications")
            
            let scanner = AppScanner()
            let newApps = await scanner.scanExternalApps(at: scanDir, localAppsDir: localDir)
            
            await MainActor.run {
                self.externalApps = newApps
            }
            AppLogger.shared.logContext(
                "外部应用扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("count", String(newApps.count)),
                    ("status_summary", self.summarizeStatuses(for: newApps))
                ]
            )
            if calculateSizes {
                await self.calculateSizesProgressive(for: newApps, isLocal: false, scanner: scanner)
            }
        }
    }
    
    func calculateSizesProgressive(for apps: [AppItem], isLocal: Bool, scanner: AppScanner) async {
        // 并行计算所有大小，再一次性批量更新 UI，避免列表反复重排
        let results = await withTaskGroup(of: (String, Int64).self) { group in
            for app in apps {
                group.addTask {
                    let size = await scanner.calculateDisplayedSize(for: app, isLocalEntry: isLocal)
                    return (app.id, size)
                }
            }
            var dict: [String: Int64] = [:]
            for await (id, size) in group { dict[id] = size }
            return dict
        }

        await MainActor.run {
            for (id, sizeBytes) in results {
                let sizeString = LocalizedByteCountFormatter.string(fromByteCount: sizeBytes)
                if isLocal {
                    if let index = self.localApps.firstIndex(where: { $0.id == id }) {
                        withAnimation {
                            self.localApps[index].size = sizeString
                            self.localApps[index].sizeBytes = sizeBytes
                        }
                    }
                } else {
                    if let index = self.externalApps.firstIndex(where: { $0.id == id }) {
                        withAnimation {
                            self.externalApps[index].size = sizeString
                            self.externalApps[index].sizeBytes = sizeBytes
                        }
                    }
                }
            }
        }
    }

    /// 只重算指定 app 的大小（迁移/迁回后调用，避免全量重算）
    func recalculateAppSize(appName: String) {
        Task.detached(priority: .userInitiated) {
            let scanner = AppScanner()

            // 在本地列表中查找
            let localApp = await MainActor.run { self.localApps.first(where: { $0.name == appName }) }
            if let localApp {
                let size = await scanner.calculateDisplayedSize(for: localApp, isLocalEntry: true)
                let sizeString = LocalizedByteCountFormatter.string(fromByteCount: size)
                await MainActor.run {
                    if let index = self.localApps.firstIndex(where: { $0.name == appName }) {
                        self.localApps[index].size = sizeString
                        self.localApps[index].sizeBytes = size
                    }
                }
            }

            // 在外部列表中查找
            let externalApp = await MainActor.run { self.externalApps.first(where: { $0.name == appName }) }
            if let externalApp {
                let size = await scanner.calculateDisplayedSize(for: externalApp, isLocalEntry: false)
                let sizeString = LocalizedByteCountFormatter.string(fromByteCount: size)
                await MainActor.run {
                    if let index = self.externalApps.firstIndex(where: { $0.name == appName }) {
                        self.externalApps[index].size = sizeString
                        self.externalApps[index].sizeBytes = size
                    }
                }
            }
        }
    }

    func openPanelForExternalDrive() {
        let openPanel = NSOpenPanel()
        openPanel.prompt = "选择文件夹".localized
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        AppLogger.shared.log("打开外部路径选择面板")
        if openPanel.runModal() == .OK, let url = openPanel.urls.first {
            self.externalDriveURL = url
            AppLogger.shared.logContext("用户选择外部路径", details: [("path", url.path)])
            // 记录外接硬盘信息
            AppLogger.shared.logExternalDriveInfo(at: url)
        } else {
            AppLogger.shared.log("用户取消选择外部路径", level: "TRACE")
        }
    }
    
    func showError(title: String, message: String) {
        AppLogger.shared.logContext(
            "向用户展示错误",
            details: [("title", title), ("message", message)],
            level: "ERROR"
        )
        self.alertTitle = title
        self.alertMessage = message
        self.showAlert = true
    }
    
    func isAppRunning(url: URL) -> Bool {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        return runningApps.contains { app in
            return app.bundleURL == url
        }
    }
    
    /// 检测应用是否来自 App Store（包括 iOS 应用）
    func isAppStoreApp(at url: URL) -> Bool {
        // 检测 _MASReceipt（Mac App Store 收据）
        let receiptPath = url.appendingPathComponent("Contents/_MASReceipt")
        if fileManager.fileExists(atPath: receiptPath.path) {
            return true
        }
        
        // 检测 iOS 应用
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        if let plistData = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
            
            // UIDeviceFamily: 1=iPhone, 2=iPad
            if let deviceFamily = plist["UIDeviceFamily"] as? [Int] {
                let hasIPhoneOrIPad = deviceFamily.contains(1) || deviceFamily.contains(2)
                let isMacCatalyst = deviceFamily.contains(6)
                if hasIPhoneOrIPad && !isMacCatalyst {
                    return true
                }
            }
            
            // LSRequiresIPhoneOS 仅 iOS 应用有
            if plist["LSRequiresIPhoneOS"] as? Bool == true {
                return true
            }
            
            // DTPlatformName 检测
            if let platform = plist["DTPlatformName"] as? String,
               platform == "iphoneos" || platform == "iphonesimulator" {
                return true
            }
        }
        
        // WrappedBundle 也是 iOS 应用
        let wrappedBundleURL = url.appendingPathComponent("WrappedBundle")
        if fileManager.fileExists(atPath: wrappedBundleURL.path) {
            return true
        }
        
        return false
    }

    func moveAndLink(appToMove: AppItem, destinationURL: URL, lockExternal: Bool = true, progressHandler: FileCopier.ProgressHandler?) async throws {
        let service = AppMigrationService()
        try await service.moveAndLink(
            appToMove: appToMove,
            destinationURL: destinationURL,
            isRunning: isAppRunning(url: appToMove.displayURL),
            lockExternal: lockExternal,
            deleteSourceFallback: AppMigrationService.removeItemViaFinder(at:),
            progressHandler: progressHandler
        )
    }

    func performMoveOutWholeSymlink(_ app: AppItem) {
        guard let dest = externalDriveURL else { return }
        let destURL = dest.appendingPathComponent(app.name)
        AppLogger.shared.logContext(
            "用户请求传统链接迁移",
            details: [("app_name", app.displayName), ("destination", destURL.path)]
        )
        isMigrating = true
        progressTotal = 1
        progressCurrent = 1
        progressAppName = app.name
        progressBytes = 0
        progressTotalBytes = 0
        showProgress = true

        Task {
            do {
                let service = AppMigrationService(portalCreationOverride: { appItem, externalURL in
                    try FileManager.default.createSymbolicLink(at: appItem.path, withDestinationURL: externalURL)
                })
                try await service.moveAndLink(
                    appToMove: app,
                    destinationURL: destURL,
                    isRunning: isAppRunning(url: app.displayURL),
                    deleteSourceFallback: AppMigrationService.removeItemViaFinder(at:),
                    progressHandler: { progress in
                        await MainActor.run {
                            self.progressBytes = progress.copiedBytes
                            self.progressTotalBytes = progress.totalBytes
                        }
                    }
                )
                AppLogger.shared.logContext("传统链接迁移成功", details: [("app_name", app.displayName)])
            } catch {
                AppLogger.shared.logError("传统链接迁移失败", error: error, context: [("app_name", app.displayName)])
                await MainActor.run {
                    showError(title: "迁移失败".localized, message: error.localizedDescription)
                }
            }
            await MainActor.run {
                showProgress = false
                isMigrating = false
                scanLocalApps(calculateSizes: false)
                scanExternalApps(calculateSizes: false)
                recalculateAppSize(appName: app.name)
            }
        }
    }

    func linkApp(appToLink: AppItem, destinationURL: URL) throws {
        try AppMigrationService().linkApp(appToLink: appToLink, destinationURL: destinationURL)
    }
    
    func deleteLink(app: AppItem) throws {
        try AppMigrationService().deleteLink(app: app)
    }
    
    func moveBack(app: AppItem, localDestinationURL: URL, progressHandler: FileCopier.ProgressHandler?) async throws {
        try await AppMigrationService().moveBack(
            app: app,
            localDestinationURL: localDestinationURL,
            progressHandler: progressHandler
        )
    }
    
    func performMoveOut() {
        guard let dest = externalDriveURL else { return }
        
        // 读取用户设置（macOS 15.1+ 自动启用）
        let masSupported = AppMigrationService.isMASExternalInstallSupported
        let allowAppStoreMigration = masSupported || UserDefaults.standard.bool(forKey: "allowAppStoreMigration")
        let allowIOSAppMigration = masSupported || UserDefaults.standard.bool(forKey: "allowIOSAppMigration")
        
        // 获取所有选中且可迁移的应用
        let validApps = selectedLocalApps.compactMap { id in
            localApps.first { $0.id == id }
        }.filter { app in
            // 基本过滤条件
            guard !app.isSystemApp && !app.isRunning && app.status != "已链接" else { return false }
            
            // 如果启用了迁移 iOS 应用，iOS 应用可以迁移
            if app.isIOSApp {
                return allowIOSAppMigration
            }
            
            // 如果启用了迁移 App Store 应用，App Store 应用可以迁移
            if app.isAppStoreApp {
                return allowAppStoreMigration
            }
            
            // 普通应用始终可以迁移
            return true
        }
        
        // 检查是否有应用被跳过
        let skippedApps = selectedLocalApps.compactMap { id in
            localApps.first { $0.id == id }
        }.filter { app in
            guard !app.isSystemApp && app.status != "已链接" else { return false }
            
            if app.isIOSApp && !allowIOSAppMigration {
                return true
            }
            if app.isAppStoreApp && !allowAppStoreMigration {
                return true
            }
            return false
        }
        
        let selectedApps = selectedLocalApps.compactMap { id in
            localApps.first { $0.id == id }
        }
        let skippedDetails = selectedApps.compactMap { app -> String? in
            guard let reason = migrationSkipReason(
                for: app,
                allowAppStoreMigration: allowAppStoreMigration,
                allowIOSAppMigration: allowIOSAppMigration
            ) else {
                return nil
            }
            return "\(app.displayName)=\(reason)"
        }
        AppLogger.shared.logContext(
            "用户请求迁移应用",
            details: [
                ("selected_count", String(selectedApps.count)),
                ("selected_apps", joinedAppNames(selectedApps)),
                ("valid_count", String(validApps.count)),
                ("valid_apps", joinedAppNames(validApps)),
                ("skipped_count", String(skippedApps.count)),
                ("skipped_details", skippedDetails.isEmpty ? "(none)" : skippedDetails.joined(separator: "; ")),
                ("destination", dest.path),
                ("allow_app_store", allowAppStoreMigration ? "true" : "false"),
                ("allow_ios", allowIOSAppMigration ? "true" : "false")
            ]
        )
        
        if !skippedApps.isEmpty && validApps.isEmpty {
            // 生成提示信息
            var message = ""
            let hasIOSApps = skippedApps.contains { $0.isIOSApp }
            let hasAppStoreApps = skippedApps.contains { $0.isAppStoreApp && !$0.isIOSApp }
            
            if hasIOSApps && hasAppStoreApps {
                message = "选中的应用包含 App Store 应用和非原生应用。\n\n如需迁移，请在设置中启用相应选项。".localized
            } else if hasIOSApps {
                message = "非原生 (iPhone/iPad) 应用不支持迁移。\n\n如需迁移，请在设置中启用「允许迁移非原生应用」选项。".localized
            } else {
                message = "App Store 应用不支持迁移，因为迁移后将无法通过 App Store 更新。\n\n如需强制迁移，请在设置中启用相应选项。".localized
            }
            
            showError(title: "无法迁移".localized, message: message)
            return
        }
        
        guard !validApps.isEmpty else { return }

        // 检查是否包含自更新应用（Sparkle/Electron）
        let selfUpdaterApps = validApps.filter { $0.hasSelfUpdater }
        if !selfUpdaterApps.isEmpty {
            pendingSelfUpdaterApps = selfUpdaterApps
            pendingRemainingAppsForSelfUpdater = validApps.filter { !($0.hasSelfUpdater) }
            selfUpdaterIsLinkIn = false
            showSelfUpdaterConfirm = true
            return
        }

        // 直接迁移符合条件的应用
        executeBatchMove(apps: validApps, destination: dest)
    }
    
    /// 批量迁移应用
    func executeBatchMove(apps: [AppItem], destination: URL, lockExternal: Bool = true) {
        guard !apps.isEmpty else { return }
        let batchID = AppLogger.shared.makeOperationID(prefix: "batch-move-out")
        AppLogger.shared.logContext(
            "开始批量迁移应用",
            details: [
                ("batch_id", batchID),
                ("count", String(apps.count)),
                ("apps", joinedAppNames(apps)),
                ("destination", destination.path)
            ]
        )
        
        isMigrating = true
        progressTotal = apps.count
        progressCurrent = 0
        showProgress = true
        
        var errors: [String] = []
        
        Task {
            for app in apps {
                await MainActor.run {
                    progressAppName = app.name
                    progressCurrent += 1
                    progressBytes = 0
                    progressTotalBytes = 0
                }
                
                // App Store 应用 + macOS >= 15.1 → 迁移到外部磁盘的 Applications 目录
                let destURL: URL
                if app.isAppStoreApp && AppMigrationService.isMASExternalInstallSupported {
                    let masDir = AppMigrationService.masApplicationsURL(for: destination)
                    try? fileManager.createDirectory(at: masDir, withIntermediateDirectories: true)
                    destURL = masDir.appendingPathComponent(app.name)
                } else {
                    destURL = destination.appendingPathComponent(app.name)
                }
                AppLogger.shared.logContext(
                    "批量迁移单项开始",
                    details: [("batch_id", batchID), ("app_name", app.displayName), ("destination", destURL.path)],
                    level: "TRACE"
                )
                
                do {
                    try await moveAndLink(appToMove: app, destinationURL: destURL, lockExternal: lockExternal) { progress in
                        await MainActor.run {
                            self.progressBytes = progress.copiedBytes
                            self.progressTotalBytes = progress.totalBytes
                        }
                    }
                    AppLogger.shared.logContext(
                        "批量迁移单项成功",
                        details: [("batch_id", batchID), ("app_name", app.displayName)]
                    )
                } catch {
                    errors.append("\(app.name): \(error.localizedDescription)")
                    AppLogger.shared.logError(
                        "批量迁移单项失败",
                        error: error,
                        context: [("batch_id", batchID), ("app_name", app.displayName), ("destination", destURL.path)],
                        relatedURLs: [("source", app.path), ("destination", destURL)]
                    )
                }
            }
            
            await MainActor.run {
                showProgress = false
                isMigrating = false
                selectedLocalApps.removeAll()
                scanLocalApps(calculateSizes: false)
                scanExternalApps(calculateSizes: false)
                // 只重算被迁移的 app 的大小
                for app in apps { recalculateAppSize(appName: app.name) }

                if !errors.isEmpty {
                    showError(title: "部分迁移失败".localized, message: errors.joined(separator: "\n"))
                }
            }
            AppLogger.shared.logContext(
                "批量迁移应用结束",
                details: [
                    ("batch_id", batchID),
                    ("success_count", String(apps.count - errors.count)),
                    ("failure_count", String(errors.count))
                ]
            )
        }
    }
    
    func performLinkIn() {
        // 获取所有选中且可链接的应用
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { $0.status == "未链接" || $0.status == "外部" || $0.status == "部分链接" }

        guard !validApps.isEmpty else { return }

        // 检查是否包含自更新应用
        let selfUpdaterApps = validApps.filter { $0.hasSelfUpdater }
        if !selfUpdaterApps.isEmpty {
            pendingSelfUpdaterApps = selfUpdaterApps
            pendingRemainingAppsForSelfUpdater = validApps.filter { !($0.hasSelfUpdater) }
            selfUpdaterIsLinkIn = true
            showSelfUpdaterConfirm = true
            return
        }

        executeBatchLinkIn(apps: validApps, lockExternal: true)
    }

    private func executeBatchLinkIn(apps: [AppItem], lockExternal: Bool) {
        guard !apps.isEmpty else { return }

        isMigrating = true
        showProgress = true
        
        var errors: [String] = []
        
        let appsToLink = apps.map { (app: $0, sourcePath: $0.path) }
        let batchID = AppLogger.shared.makeOperationID(prefix: "batch-link-in")
        AppLogger.shared.logContext(
            "开始批量链接应用",
            details: [
                ("batch_id", batchID),
                ("selected_count", String(apps.count)),
                ("selected_items", joinedAppNames(apps)),
                ("expanded_app_count", String(appsToLink.count)),
                ("expanded_sources", appsToLink.map { $0.sourcePath.lastPathComponent }.joined(separator: ", "))
            ]
        )
        
        progressTotal = appsToLink.count
        progressCurrent = 0
        
        Task {
            for item in appsToLink {
                let appName = item.sourcePath.lastPathComponent
                await MainActor.run {
                    progressAppName = appName
                    progressCurrent += 1
                }
                
                let destination = localAppsURL.appendingPathComponent(appName)
                let tempAppItem = AppItem(
                    name: appName,
                    path: item.sourcePath,
                    bundleURL: item.app.bundleURL,
                    status: "未链接",
                    isFolder: item.app.isFolder,
                    containerKind: item.app.containerKind,
                    appCount: item.app.appCount
                )
                AppLogger.shared.logContext(
                    "批量链接单项开始",
                    details: [("batch_id", batchID), ("app_name", appName), ("destination", destination.path)],
                    level: "TRACE"
                )
                
                do {
                    try linkApp(appToLink: tempAppItem, destinationURL: destination)
                    // 锁定外部 app（仅 Sparkle/Electron 有更新器的应用）
                    if lockExternal && item.app.needsLock {
                        AppMigrationService().lockExternalApp(at: item.sourcePath)
                    }
                    AppLogger.shared.logContext(
                        "批量链接单项成功",
                        details: [("batch_id", batchID), ("app_name", appName)]
                    )
                } catch {
                    errors.append("\(appName): \(error.localizedDescription)")
                    AppLogger.shared.logError(
                        "批量链接单项失败",
                        error: error,
                        context: [("batch_id", batchID), ("app_name", appName), ("folder_item", item.app.displayName)],
                        relatedURLs: [("source", item.sourcePath), ("destination", destination)]
                    )
                }
                
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            await MainActor.run {
                showProgress = false
                isMigrating = false
                selectedExternalApps.removeAll()
                scanLocalApps(calculateSizes: false)
                scanExternalApps(calculateSizes: false)
                for item in appsToLink { recalculateAppSize(appName: item.sourcePath.lastPathComponent) }

                if !errors.isEmpty {
                    showError(title: "部分链接失败".localized, message: errors.joined(separator: "\n"))
                }
            }
            AppLogger.shared.logContext(
                "批量链接应用结束",
                details: [
                    ("batch_id", batchID),
                    ("success_count", String(appsToLink.count - errors.count)),
                    ("failure_count", String(errors.count))
                ]
            )
        }
    }
    
    func performDeleteLink(app: AppItem) {
        AppLogger.shared.logContext(
            "用户请求删除本地入口",
            details: [("app_name", app.displayName), ("path", app.path.path), ("status", app.status)]
        )
        do {
            try deleteLink(app: app)
            scanLocalApps(calculateSizes: false); scanExternalApps(calculateSizes: false)
            recalculateAppSize(appName: app.name)
        } catch {
            AppLogger.shared.logError(
                "删除本地入口失败",
                error: error,
                context: [("app_name", app.displayName)],
                relatedURLs: [("path", app.path)]
            )
            showError(title: "错误".localized, message: error.localizedDescription)
        }
    }
    
    
    func performMoveBack(app: AppItem) {
        let operationID = AppLogger.shared.makeOperationID(prefix: "single-move-back")
        AppLogger.shared.logContext(
            "用户请求还原单个应用",
            details: [
                ("operation_id", operationID),
                ("app_name", app.displayName),
                ("source", app.path.path),
                ("destination", localAppsURL.appendingPathComponent(app.name).path)
            ]
        )
        isMigrating = true
        progressTotal = 1
        progressCurrent = 1
        progressAppName = app.displayName
        progressBytes = 0
        progressTotalBytes = 0
        showProgress = true
        
        Task {
            let destination = localAppsURL.appendingPathComponent(app.name)
            do {
                try await moveBack(app: app, localDestinationURL: destination) { progress in
                    await MainActor.run {
                        self.progressBytes = progress.copiedBytes
                        self.progressTotalBytes = progress.totalBytes
                    }
                }
                AppLogger.shared.logContext(
                    "单个应用还原成功",
                    details: [("operation_id", operationID), ("app_name", app.displayName)]
                )
            } catch {
                AppLogger.shared.logError(
                    "单个应用还原失败",
                    error: error,
                    context: [("operation_id", operationID), ("app_name", app.displayName)],
                    relatedURLs: [("source", app.path), ("destination", destination)]
                )
                await MainActor.run {
                    showError(title: "错误".localized, message: error.localizedDescription)
                }
            }
            
            await MainActor.run {
                showProgress = false
                isMigrating = false
                scanLocalApps(calculateSizes: false)
                scanExternalApps(calculateSizes: false)
                recalculateAppSize(appName: app.name)
            }
        }
    }

    /// 批量迁移回本地
    func performBatchMoveBack() {
        // 获取所有选中的外部应用
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }
        
        guard !validApps.isEmpty else { return }
        let batchID = AppLogger.shared.makeOperationID(prefix: "batch-move-back")
        AppLogger.shared.logContext(
            "开始批量还原应用",
            details: [
                ("batch_id", batchID),
                ("count", String(validApps.count)),
                ("apps", joinedAppNames(validApps))
            ]
        )
        
        isMigrating = true
        progressTotal = validApps.count
        progressCurrent = 0
        showProgress = true
        
        var errors: [String] = []
        
        Task {
            for app in validApps {
                await MainActor.run {
                    progressAppName = app.displayName
                    progressCurrent += 1
                    progressBytes = 0
                    progressTotalBytes = 0
                }
                
                let destination = localAppsURL.appendingPathComponent(app.name)
                AppLogger.shared.logContext(
                    "批量还原单项开始",
                    details: [("batch_id", batchID), ("app_name", app.displayName), ("destination", destination.path)],
                    level: "TRACE"
                )
                
                do {
                    try await moveBack(app: app, localDestinationURL: destination) { progress in
                        await MainActor.run {
                            self.progressBytes = progress.copiedBytes
                            self.progressTotalBytes = progress.totalBytes
                        }
                    }
                    AppLogger.shared.logContext(
                        "批量还原单项成功",
                        details: [("batch_id", batchID), ("app_name", app.displayName)]
                    )
                } catch {
                    errors.append("\(app.displayName): \(error.localizedDescription)")
                    AppLogger.shared.logError(
                        "批量还原单项失败",
                        error: error,
                        context: [("batch_id", batchID), ("app_name", app.displayName)],
                        relatedURLs: [("source", app.path), ("destination", destination)]
                    )
                }
            }
            
            await MainActor.run {
                showProgress = false
                isMigrating = false
                selectedExternalApps.removeAll()
                scanLocalApps(calculateSizes: false)
                scanExternalApps(calculateSizes: false)
                for app in validApps { recalculateAppSize(appName: app.name) }

                if !errors.isEmpty {
                    showError(title: "部分迁移失败".localized, message: errors.joined(separator: "\n"))
                }
            }
            AppLogger.shared.logContext(
                "批量还原应用结束",
                details: [
                    ("batch_id", batchID),
                    ("success_count", String(validApps.count - errors.count)),
                    ("failure_count", String(errors.count))
                ]
            )
        }
    }
    
    func getMoveBackButtonTitle() -> String {
        if selectedExternalApps.isEmpty {
            return "迁移回本地".localized
        }
        
        if selectedExternalApps.count == 1 {
            return "迁移回本地".localized
        }
        
        return String(format: "迁移 %lld 个应用".localized, Int64(selectedExternalApps.count))
    }
    
    // MARK: - 签名备份/恢复逻辑

    /// 迁移前备份原始签名身份（不执行签名），确保迁移后恢复按钮立即可用
    func performBackupSignature(app: AppItem) {
        guard let bundleID = getBundleIdentifier(for: app) else { return }
        Task {
            let signer = CodeSigner()
            do {
                try await signer.backupOriginalSignature(appURL: app.displayURL, bundleIdentifier: bundleID)
                AppLogger.shared.logContext(
                    "迁移前备份签名身份",
                    details: [("app_name", app.displayName), ("bundle_id", bundleID)]
                )
            } catch {
                AppLogger.shared.logError(
                    "备份签名身份失败",
                    error: error,
                    errorCode: "BACKUP-SIGNATURE-FAILED",
                    context: [("app_name", app.displayName), ("bundle_id", bundleID)],
                    relatedURLs: [("target_app", app.displayURL)]
                )
            }
        }
    }

    func performSingleResign(app: AppItem, silent: Bool = false) {
        AppLogger.shared.logContext(
            "用户请求重签名单个应用",
            details: [("app_name", app.displayName), ("path", app.path.path), ("silent", silent ? "true" : "false")]
        )

        Task {
            let signer = CodeSigner()
            do {
                try await signer.sign(appURL: app.displayURL, bundleIdentifier: getBundleIdentifier(for: app))
                AppLogger.shared.logContext(
                    "重签名成功",
                    details: [("app_name", app.displayName), ("path", app.path.path)],
                    level: "INFO"
                )
                await MainActor.run {
                    scanLocalApps(calculateSizes: false)
                    scanExternalApps(calculateSizes: false)
                }
            } catch {
                AppLogger.shared.logError(
                    "重签名失败（应用可能无法通过 macOS 签名校验）",
                    error: error,
                    errorCode: "RESIGN-FAILED",
                    context: [("app_name", app.displayName), ("path", app.path.path), ("silent", silent ? "true" : "false")],
                    relatedURLs: [("target_app", app.displayURL)]
                )
                if !silent {
                    await MainActor.run {
                        showError(title: "签名失败".localized, message: error.localizedDescription)
                    }
                }
            }
        }
    }

    func performRestoreSignature(app: AppItem) {
        let realURL = resolveRealAppURL(for: app)
        guard let bundleID = getBundleIdentifier(from: realURL) else {
            showError(title: "恢复签名失败".localized, message: "无法读取应用 Bundle Identifier".localized)
            return
        }

        AppLogger.shared.logContext(
            "用户请求恢复原始签名",
            details: [("app_name", app.displayName), ("real_path", realURL.path), ("bundle_id", bundleID)]
        )

        Task {
            let signer = CodeSigner()
            do {
                try await signer.restoreSignature(appURL: realURL, bundleIdentifier: bundleID)
                await MainActor.run {
                    scanLocalApps(calculateSizes: false)
                    scanExternalApps(calculateSizes: false)
                }
            } catch {
                await MainActor.run {
                    showError(title: "恢复签名失败".localized, message: error.localizedDescription)
                }
            }
        }
    }

    nonisolated func getBundleIdentifier(for app: AppItem) -> String? {
        let infoPlistURL = app.displayURL.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    /// 从指定 URL 读取 Bundle Identifier
    nonisolated func getBundleIdentifier(from url: URL) -> String? {
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    /// 解析应用的真实路径（外部真实应用或本地真实应用），而非假壳
    /// - 已链接应用：返回外部真实 .app 路径
    /// - 未链接应用：返回本地真实 .app 路径
    nonisolated func resolveRealAppURL(for app: AppItem) -> URL {
        // 未链接：返回本地路径
        guard app.status == "已链接" else {
            return app.displayURL
        }

        // Whole-app symlink：解析符号链接目标
        if let rawPath = try? FileManager.default.destinationOfSymbolicLink(atPath: app.path.path) {
            return URL(fileURLWithPath: rawPath, relativeTo: app.path.deletingLastPathComponent()).standardizedFileURL
        }

        // Stub Portal：从原生 launcher 的 real_app_path.txt 解析外部路径
        let realAppPathFile = app.path.appendingPathComponent("Contents/Resources/real_app_path.txt")
        if let realPath = try? String(contentsOf: realAppPathFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !realPath.isEmpty,
           FileManager.default.fileExists(atPath: realPath) {
            return URL(fileURLWithPath: realPath)
        }

        // Stub Portal（旧版 bash launcher）：从 launcher 脚本解析外部路径
        let launcherPath = app.path.appendingPathComponent("Contents/MacOS/launcher")
        if let script = try? String(contentsOf: launcherPath, encoding: .utf8) {
            // 匹配 REAL_APP='...' 中的路径
            let pattern = "REAL_APP='([^']+)'"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
               let range = Range(match.range(at: 1), in: script) {
                let path = String(script[range])
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }

        // 兜底：返回本地路径
        return app.displayURL
    }

    /// 解析符号链接目标
    private func resolveSymlinkDestination(of url: URL) -> URL? {
        guard let rawPath = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        return URL(fileURLWithPath: rawPath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    /// 对指定 URL 执行重签名（用于数据目录迁移后签名真实应用）
    func performResign(at url: URL, bundleID: String?, silent: Bool = false) {
        AppLogger.shared.logContext(
            "数据迁移后重签名真实应用",
            details: [("path", url.path), ("bundle_id", bundleID ?? "nil"), ("silent", silent ? "true" : "false")]
        )

        Task {
            let signer = CodeSigner()
            do {
                try await signer.sign(appURL: url, bundleIdentifier: bundleID)
                AppLogger.shared.logContext(
                    "数据迁移后重签名成功",
                    details: [("path", url.path), ("bundle_id", bundleID ?? "nil")],
                    level: "INFO"
                )
                await MainActor.run {
                    scanLocalApps(calculateSizes: false)
                    scanExternalApps(calculateSizes: false)
                }
            } catch {
                AppLogger.shared.logError(
                    "数据迁移后重签名失败（应用可能无法通过 macOS 签名校验）",
                    error: error,
                    errorCode: "DATA-RESIGN-FAILED",
                    context: [("path", url.path), ("bundle_id", bundleID ?? "nil"), ("silent", silent ? "true" : "false")],
                    relatedURLs: [("target_app", url)]
                )
                if !silent {
                    await MainActor.run {
                        showError(title: "签名失败".localized, message: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// 对指定 URL 备份原始签名（用于数据目录迁移前）
    func performBackupSignature(at url: URL, bundleID: String?) {
        guard let bundleID = bundleID else { return }
        Task {
            let signer = CodeSigner()
            do {
                try await signer.backupOriginalSignature(appURL: url, bundleIdentifier: bundleID)
                AppLogger.shared.logContext(
                    "数据迁移前备份签名身份",
                    details: [("path", url.path), ("bundle_id", bundleID)]
                )
            } catch {
                AppLogger.shared.logError(
                    "数据迁移前备份签名身份失败（后续恢复签名将无法使用原始身份）",
                    error: error,
                    errorCode: "DATA-BACKUP-SIGNATURE-FAILED",
                    context: [("path", url.path), ("bundle_id", bundleID)],
                    relatedURLs: [("target_app", url)]
                )
            }
        }
    }

    // MARK: - Monitoring Helpers
    
    func startMonitoringLocal() {
        localMonitor?.stopMonitoring()
        AppLogger.shared.logContext("启动本地目录监控", details: [("path", localAppsURL.path)])

        let monitor = FolderMonitor(url: localAppsURL)
        monitor.startMonitoring { [self] in
            scheduleMonitorRescan(local: true)
        }
        self.localMonitor = monitor
    }

    func startMonitoringExternal(url: URL) {
        externalMonitor?.stopMonitoring()
        AppLogger.shared.logContext("启动外部目录监控", details: [("path", url.path)])

        let monitor = FolderMonitor(url: url)
        monitor.startMonitoring { [self] in
            scheduleMonitorRescan(local: false)
        }
        self.externalMonitor = monitor
    }

    /// 统一防抖：合并两个 monitor 的扫描请求，避免列表连续跳两下
    private func scheduleMonitorRescan(local: Bool) {
        Self.monitorRescanDebouncer.schedule { [self] in
            AppLogger.shared.logContext("Monitor 防抖触发扫描", details: [("trigger", local ? "local" : "external")], level: "TRACE")
            self.scanBothAppsAtomic()
        }
    }

    /// 原子扫描：并行扫描本地和外部应用，一次性更新 UI，避免列表跳两下
    private func scanBothAppsAtomic() {
        let externalDir = externalDriveURL
        Task.detached(priority: .userInitiated) {
            let scanner = AppScanner()
            let runningAppURLs = await MainActor.run { self.getRunningAppURLs() }
            let localDir = self.localAppsURL
            let externalLocalDir = URL(fileURLWithPath: "/Applications")

            // 保留旧的大小信息
            let oldLocalSizes = await MainActor.run {
                Dictionary(uniqueKeysWithValues: self.localApps.compactMap { app -> (String, (String?, Int64))? in
                    guard app.size != nil else { return nil }
                    return (app.id, (app.size, app.sizeBytes))
                })
            }
            let oldExternalSizes = await MainActor.run {
                Dictionary(uniqueKeysWithValues: self.externalApps.compactMap { app -> (String, (String?, Int64))? in
                    guard app.size != nil else { return nil }
                    return (app.id, (app.size, app.sizeBytes))
                })
            }

            // 并行扫描
            async let localResult = scanner.scanLocalApps(at: localDir, runningAppURLs: runningAppURLs)
            let externalResult: [AppItem]
            if let externalDir {
                externalResult = await scanner.scanExternalApps(at: externalDir, localAppsDir: externalLocalDir)
            } else {
                externalResult = []
            }
            var newLocalApps = await localResult

            // 恢复旧的大小信息，只对变化的 app 标记需要重算
            for i in newLocalApps.indices {
                if let (size, sizeBytes) = oldLocalSizes[newLocalApps[i].id] {
                    newLocalApps[i].size = size
                    newLocalApps[i].sizeBytes = sizeBytes
                }
            }
            var newExternalApps = externalResult
            for i in newExternalApps.indices {
                if let (size, sizeBytes) = oldExternalSizes[newExternalApps[i].id] {
                    newExternalApps[i].size = size
                    newExternalApps[i].sizeBytes = sizeBytes
                }
            }

            let finalLocalApps = newLocalApps
            let finalExternalApps = newExternalApps
            await MainActor.run {
                self.localApps = finalLocalApps
                self.externalApps = finalExternalApps
            }

            // 只重算没有大小信息的 app（新增的或状态变化的）
            let appsToRecalculate = newLocalApps.filter { $0.size == nil } + newExternalApps.filter { $0.size == nil }
            for app in appsToRecalculate {
                await self.recalculateAppSize(appName: app.name)
            }
        }
    }
    
    func stopMonitoringExternal() {
        AppLogger.shared.log("停止外部目录监控", level: "TRACE")
        externalMonitor?.stopMonitoring()
        externalMonitor = nil
    }
}

/// 统一防抖器：合并 FolderMonitor 的扫描请求，避免列表连续跳动
private class RescanDebouncer {
    private var work: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.rescanDebounce")

    func schedule(action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { action() }
        work = item
        queue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }
}
