//
//  ContentView.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

    @ObservedObject private var operationState = AppOperationState.shared
    private typealias ScanRequest = AppListScanState.Request
    @State private var localScanState = AppListScanState()
    @State private var externalScanState = AppListScanState()
    @State private var isVisible = false
    @State private var needsAppRescan = false

    @State private var localApps: [AppItem] = []
    @State private var externalApps: [AppItem] = []
    /// 会话级应用体积缓存（key = AppItem.id，即标准化路径）。
    /// 独立于 localApps/externalApps（每次扫描都会重建），因此会话内不会因重扫而丢失已算出的体积。
    @State private var sizeCache: [String: CachedAppSize] = [:]
    
    @State private var searchText: String = ""
    
    private let localAppsURL = URL(fileURLWithPath: "/Applications")
    @State private var externalDriveURL: URL?
    @State private var customLocalScanPaths: [String] = UserDefaults.standard.stringArray(forKey: "customLocalScanPaths") ?? []
    @State private var customLocalMonitors: [FolderMonitor] = []

    // 多选支持
    @State private var selectedLocalApps: Set<String> = []
    @State private var selectedExternalApps: Set<String> = []
    
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    @State private var showUpdateAlert = false
    @State private var updateGitHubURL: URL?
    @State private var updateChinaDownloadURL: URL?
    @State private var updateReleaseBody = ""
    
    // 受保护应用迁移预警（App Store / root 拥有，自动迁移可能因权限失败）
    @State private var protectedAppsRequest: WarningSheetRequest?
    // 经典模式下重签名沙盒应用前的二次确认
    @State private var classicResignRequest: WarningSheetRequest?
    @State private var pendingClassicResignApp: AppItem? = nil
    @State private var pendingClassicResignTarget: DataMigrationWorkflow.SigningTarget?
    @State private var pendingProtectedApps: [AppItem] = []
    @State private var pendingMigrationAfterWarning: [AppItem] = []

    // 自更新应用迁移确认（Sparkle/Electron，锁定模式保护）
    @State private var selfUpdaterRequest: WarningSheetRequest?
    @State private var pendingSelfUpdaterApps: [AppItem] = []
    @State private var pendingRemainingAppsForSelfUpdater: [AppItem] = []
    @State private var selfUpdaterIsLinkIn = false // true = 链接回本地, false = 迁移到外部

    @State private var pendingRemainingApps: [AppItem] = []
    
    // 进度弹窗状态
    @State private var showProgress = false
    @State private var progressTitle = "正在迁移应用...".localized
    @State private var progressCurrent = 0
    @State private var progressTotal = 0
    @State private var progressAppName = ""
    @State private var isMigrating = false
    
    // App Store 外部安装引导
    @State private var masGuidanceRequest: WarningSheetRequest?

    // 设置页面
    @State private var showAppStoreSettings = false
    
    // 单应用复制进度
    @State private var progressBytes: Int64 = 0
    @State private var progressTotalBytes: Int64 = 0
    @State private var progressFileName = ""

    private let fileManager = FileManager.default

    // Monitors
    @State private var localMonitor: FolderMonitor?
    @State private var externalMonitor: FolderMonitor?

    // Monitor 防抖：合并两个 monitor 的扫描请求
    @State private var monitorRescanDebouncer = RescanDebouncer()

    // Track previous external drive URL for logging
    @State private var previousExternalDriveURL: URL?

    // 插盘通知：重新挂载容器卷
    @State private var volumeMountObserver: NSObjectProtocol?
    @State private var volumeUnmountObserver: NSObjectProtocol?

    enum SortOption {
        case name, size
    }
    @State private var sortOption: SortOption = .name

    // MARK: - Tab
    enum MainTab { case apps, dataDirs, customDirs }
    @State private var mainTab: MainTab = .apps
    @State private var selectedDataDirsTab: DataDirsView.DataTab = .toolDirs
    @State private var selectedDataDirsApp: AppItem? = nil
    @State private var isDataDirsScanning = false
    @State private var dataDirsRefreshTrigger = 0
    @AppStorage("autoResignEnabled") private var autoResignEnabled = false
    @AppStorage(MigrationPreferences.classicDataMigrationKey) private var classicDataMigrationEnabled = false

    // 签名被替换的应用：启动提醒与修复面板
    @State private var signatureRepairApp: AppItem? = nil
    @State private var signatureRepairReminderRequest: WarningSheetRequest?
    @State private var signatureRestoreSourceRequest: WarningSheetRequest?
    @State private var signatureRepairReminderApps: [SignatureReplacedApp] = []
    @State private var hasShownSignatureRepairReminder = false
    @State private var localAppFilter: LocalAppFilter = .all

    enum LocalAppFilter { case all, signatureReplaced }

    /// 经典模式生效：用户开启且系统版本允许
    private var classicModeActive: Bool {
        classicDataMigrationEnabled && MigrationPreferences.isClassicModeSupported
    }

    var body: some View {
        mainContent
        .disabled(operationState.isBusy)
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            // A unit-test host must not scan apps, refresh agents, or observe real volumes.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            isVisible = true
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
            scanBothAppsAtomic()

            // 「签名已被替换」提醒只需要签名备份目录和每个应用的签名状态，
            // 不依赖体积扫描，所以单独查一次：首次完整扫描可能要十几分钟，不能把提醒压在它后面。
            checkSignatureReplacedAppsOnLaunch()

            // Start local monitoring
            startMonitoringLocal()

            // 重新挂载在线的容器卷（挂载迁移），插盘时同样触发
            remountContainerVolumes(trigger: "launch")
            startObservingVolumeMounts()
            
            // Check for updates
            Task {
                if let update = await UpdateChecker.shared.checkForUpdates() {
                    AppLogger.shared.logContext(
                        "检测到新版本",
                        details: [
                            ("version", update.version),
                            ("source", update.source.rawValue),
                            ("github_url", update.githubURL?.absoluteString),
                            ("china_download_url", update.chinaDownloadURL.absoluteString)
                        ]
                    )
                    await MainActor.run {
                        self.updateReleaseBody = update.releaseNotesMarkdown
                        self.updateGitHubURL = update.githubURL
                        self.updateChinaDownloadURL = update.chinaDownloadURL
                        self.showUpdateAlert = true
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let latest = UserDefaults.standard.stringArray(forKey: "customLocalScanPaths") ?? []
            guard isVisible, latest != customLocalScanPaths else { return }
            customLocalScanPaths = latest
            startMonitoringLocal()
            scanBothAppsAtomic()
        }
        .onDisappear {
            monitorRescanDebouncer.cancel()
            isVisible = false
            localScanState.invalidate()
            externalScanState.invalidate()
            localMonitor?.stopMonitoring()
            customLocalMonitors.forEach { $0.stopMonitoring() }
            stopMonitoringExternal()
            stopObservingVolumeMounts()
        }
        .onChange(of: operationState.isBusy) { isBusy in
            // 补上操作期间延后的监控刷新，也初始化操作期间新打开的窗口。
            if !isBusy, needsAppRescan || localScanState.request == nil || externalScanState.request == nil {
                scanBothAppsAtomic()
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
            scanBothAppsAtomic()

            // macOS >= 15.1: 检查外部磁盘的 Applications 目录
            if let url = newValue, AppMigrationService.isMASExternalInstallSupported {
                let masDir = AppMigrationService.masApplicationsURL(for: url)
                if !fileManager.fileExists(atPath: masDir.path) {
                    masGuidanceRequest = makeMASGuidanceRequest()
                }
            }
        }
        
        .alert(LocalizedStringKey(alertTitle.localized), isPresented: $showAlert) {
            Button("好的".localized, role: .cancel) { }
        } message: {
            Text(LocalizedStringKey(alertMessage.localized))
        }
        .warningSheet($signatureRepairReminderRequest)
        .warningSheet($signatureRestoreSourceRequest)
        .warningSheet($classicResignRequest)
        .sheet(item: $signatureRepairApp) { app in
            signatureRepairSheet(for: app)
        }
        .sheet(isPresented: $showUpdateAlert) {
            updateSheetContent
        }
        // 受保护应用（App Store / root）迁移预警
        .warningSheet($protectedAppsRequest)
        // 自更新应用迁移确认弹窗
        .warningSheet($selfUpdaterRequest)
        // App Store 外部安装引导弹窗
        .warningSheet($masGuidanceRequest)
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
                        title: progressTitle,
                        current: progressCurrent,
                        total: progressTotal,
                        appName: progressAppName,
                        copiedBytes: progressBytes,
                        totalBytes: progressTotalBytes,
                        currentFile: progressFileName
                    )
                }
            }
        }
    }
    
    // MARK: - 过滤逻辑
    
    var filteredLocalApps: [AppItem] {
        let apps = localAppFilter == .signatureReplaced ? localApps.filter(\.signatureReplaced) : localApps
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
        @Environment(\.colorScheme) private var colorScheme

        let title: String
        let subtitle: String // subtitle 可能是路径，也可能是 "未选择"
        let icon: String
        var iconColumnWidth: CGFloat = 32
        var tint: Color = .accentColor
        var actionButtonText: String? = nil
        var onAction: (() -> Void)? = nil
        var onRefresh: (() -> Void)? = nil
        var isRefreshing = false
        var accessory: AnyView? = nil
        
        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    )
                    .frame(width: iconColumnWidth, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 8)

                        HStack(spacing: 8) {
                            if let btnText = actionButtonText, let action = onAction {
                                Button(action: action) {
                                    Text(btnText)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 10)
                                        .frame(minWidth: 28, minHeight: 26)
                                        .background(Color.accentColor.opacity(0.10))
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }

                            if let accessory {
                                accessory
                            }

                            if let onRefresh {
                                Button(action: onRefresh) {
                                    Group {
                                        if isRefreshing {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(width: 26, height: 26)
                                }
                                .buttonStyle(.borderless)
                                .disabled(isRefreshing)
                                .accessibilityLabel(isRefreshing ? "正在扫描...".localized : "刷新列表".localized)
                                .help(isRefreshing ? "正在扫描...".localized : "刷新列表".localized)
                            }
                        }
                        .fixedSize()
                    }
                    .frame(minHeight: 24)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(subtitle)
                }
            }
            // 列表内容起点：系统外边距 8 + 行 inset 10 + 行内边距 12。
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.09 : 0.045))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
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
                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(title)
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
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
    
    struct RowSeparatorVisibility: ViewModifier {
        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 13.0, *) {
                content.listRowSeparator(.hidden)
            } else {
                content
            }
        }
    }

    struct TransparentListBackground: ViewModifier {
        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 13.0, *) {
                content.scrollContentBackground(.hidden)
            } else {
                content
            }
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

                Text(text)
                .foregroundColor(.secondary.opacity(0.7))
            }
            .accessibilityElement(children: .combine)
        }
    }


    // MARK: - 主内容（拆出以减轻 body 的类型推断负担）

    private var mainContent: some View {
        VStack(spacing: 0) {
            // MARK: - Top Toolbar
            topToolbar

            // MARK: - 主内容区（Tab 切换）
            if mainTab == .dataDirs {
                DataDirsView(
                    externalDriveURL: externalDriveURL,
                    localApps: localApps,
                    selectedTab: $selectedDataDirsTab,
                    selectedApp: $selectedDataDirsApp,
                    isScanning: $isDataDirsScanning,
                    autoResignEnabled: $autoResignEnabled,
                    classicModeActive: classicModeActive,
                    refreshTrigger: dataDirsRefreshTrigger,
                    onSelectExternalDrive: openPanelForExternalDrive,
                    onRepairSignature: { app in signatureRepairApp = app },
                    onResignApp: { app, silent in performSingleResign(app: app, silent: silent) },
                    onRestoreSignature: performRestoreSignature,
                    onBackupSignature: performBackupSignature,
                    resolveRealAppURL: resolveRealAppURL(for:),
                    onResignAppAtURL: { url, sandboxedAppApproved in
                        try await performResign(at: url, bundleID: getBundleIdentifier(from: url), allowSandboxed: classicModeActive && sandboxedAppApproved)
                    },
                    onBackupSignatureForURL: { url in
                        try await performBackupSignature(at: url, bundleID: getBundleIdentifier(from: url))
                    }
                )
            } else if mainTab == .customDirs {
                CustomDirsView()
            } else {

            HSplitView {
                localAppsPane
                externalAppsPane
            } // end HSplitView for mainTab == .apps
            } // end else for mainTab == .apps
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var updateSheetContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("发现新版本".localized)
                .font(.headline)
            MarkdownTextView(markdown: updateReleaseBody)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("GitHub".localized) {
                    showUpdateAlert = false
                    if let url = updateGitHubURL { NSWorkspace.shared.open(url) }
                }
                .disabled(updateGitHubURL == nil)
                .keyboardShortcut(.defaultAction)
                Button("国内下载".localized) {
                    showUpdateAlert = false
                    if let url = updateChinaDownloadURL { NSWorkspace.shared.open(url) }
                }
                Button("以后再说".localized) {
                    showUpdateAlert = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

    // MARK: - 顶部工具栏（拆出以减轻 body 的类型推断负担）

    private var topToolbar: some View {
    HStack(spacing: 14) {
        // Tab 切换器
        HStack(spacing: 2) {
            TabButton(title: "应用".localized, systemImage: "cube", isSelected: mainTab == .apps) {
                withAnimation { mainTab = .apps }
            }
            TabButton(title: "数据目录".localized, systemImage: "cylinder", isSelected: mainTab == .dataDirs) {
                withAnimation { mainTab = .dataDirs }
            }
            TabButton(title: "目录迁移".localized, systemImage: "folder.badge.gearshape", isSelected: mainTab == .customDirs) {
                withAnimation { mainTab = .customDirs }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )

        if mainTab == .dataDirs {
            HStack(spacing: 2) {
                TabButton(title: "工具目录".localized, isSelected: selectedDataDirsTab == .toolDirs) {
                    withAnimation { selectedDataDirsTab = .toolDirs }
                }
                TabButton(title: "应用数据".localized, isSelected: selectedDataDirsTab == .appDirs) {
                    withAnimation { selectedDataDirsTab = .appDirs }
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .transition(.opacity.combined(with: .move(edge: .leading)))
        }

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
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

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

        if mainTab == .dataDirs {
            dataDirsToolbarControls
        }

        // App Store Settings Button（始终显示）
        Button(action: { showAppStoreSettings = true }) {
            Label("设置".localized, systemImage: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help("App Store 应用迁移设置".localized)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 应用页两个面板（拆出以减轻 body 的类型推断负担）

    private var localAppsPane: some View {
        VStack(spacing: 0) {
            HeaderView(
                title: "Mac 本地应用".localized,
                subtitle: localAppsSubtitle,
                icon: "desktopcomputer",
                iconColumnWidth: 40,
                actionButtonText: "＋",
                onAction: addCustomLocalScanPath,
                onRefresh: { scanLocalApps(forceSizeRefresh: true) },
                isRefreshing: localScanState.isScanning,
                accessory: customLocalScanPaths.isEmpty ? nil : AnyView(localScanSourcesMenu)
            )

            if localAppFilter == .signatureReplaced {
                signatureReplacedFilterBanner
            }

            ZStack {
                Color(nsColor: .controlBackgroundColor).ignoresSafeArea()

                if filteredLocalApps.isEmpty {
                    if localScanState.isScanning && localApps.isEmpty {
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
                            onMoveOutWholeSymlink: performMoveOutWholeSymlink,
                            onRepairDock: performRepairDockShortcuts,
                            onRepairSignature: { signatureRepairApp = $0 }
                        )
                        .tag(app.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)) // Add spacing around rows
                        .modifier(RowSeparatorVisibility())
                    }
                    .listStyle(.plain)
                    .modifier(TransparentListBackground())
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

    }

    private var externalAppsPane: some View {
        VStack(spacing: 0) {
            HeaderView(
                title: "外部应用库".localized,
                subtitle: externalDriveURL?.path ?? "未选择".localized,
                icon: "externaldrive.fill",
                iconColumnWidth: 40,
                tint: .teal,
                actionButtonText: "选择文件夹".localized,
                onAction: { _ = openPanelForExternalDrive() },
                onRefresh: { scanExternalApps(forceSizeRefresh: true) },
                isRefreshing: externalScanState.isScanning
            )

        ZStack {
            Color(nsColor: .controlBackgroundColor).ignoresSafeArea()

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
                if externalScanState.isScanning && externalApps.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", text: "正在扫描...".localized)
                } else if !externalApps.isEmpty || !searchText.isEmpty {
                    EmptyStateView(icon: "doc.text.magnifyingglass", text: "未找到匹配应用".localized)
                } else {
                    EmptyStateView(icon: "folder", text: "空文件夹".localized)
                }
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
                        onRestoreSignature: performRestoreSignature,
                        onRepairSignature: { signatureRepairApp = $0 }
                    )
                    .tag(app.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                    .modifier(RowSeparatorVisibility())
                }
                .listStyle(.plain)
                .modifier(TransparentListBackground())
            }
        }

        // 双按钮底部栏
        VStack(spacing: 0) {
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
        .background(Color(nsColor: .controlBackgroundColor))
    }
    .frame(minWidth: 320, maxWidth: .infinity)
    }

    private var signatureReplacedFilterBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill").foregroundColor(.red)
            Text("只显示签名已被替换的应用".localized)
                .font(.system(size: 12))
            Spacer()
            Button("显示全部".localized) { localAppFilter = .all }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.06))
    }

    private var dataDirsToolbarControls: some View {
        HStack(spacing: 10) {
            if classicModeActive {
            HStack(spacing: 6) {
                Image(systemName: autoResignEnabled ? "seal.fill" : "seal")
                    .font(.system(size: 12))
                    .foregroundColor(autoResignEnabled ? .teal : .secondary)

                Text("迁移后重签名".localized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Toggle("迁移后重签名".localized, isOn: $autoResignEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()

                HelpButton(content: """
                **什么是重签名？**

                数据目录迁移到外部存储后，macOS 可能认为应用已被修改，在 Finder 中提示「已损坏」或「无法打开」。

                开启此选项后，AppPorts 会在数据迁移完成后自动对关联应用执行 **Ad-hoc 自签名**，绕过此限制。

                **通常不需要开启。** 重签名会替换应用的开发者签名并移除部分授权。新版会先保存完整原始应用，可用「恢复原始签名」还原，不需要开发者私钥。

                **沙盒应用默认不重签名**：经典模式需确认风险，系统升级后应用可能无法启动。恢复签名前应先还原经典模式迁移的容器数据；容器数据请优先使用「挂载迁移」。
                """.localized)
            }
            .help("数据迁移完成后，完整备份并重签关联应用。经典模式可能影响应用启动和登录态，通常不需要开启".localized)
            }

            if selectedDataDirsTab == .appDirs, let app = selectedDataDirsApp, app.isResigned {
                Button(action: { performRestoreSignature(app: app) }) {
                    Label("恢复原始签名".localized, systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.teal)
                .help("恢复选中应用的原始代码签名".localized)
            }

            Button(action: { dataDirsRefreshTrigger += 1 }) {
                Group {
                    if isDataDirsScanning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(width: 16, height: 16)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(isDataDirsScanning)
            .help("刷新列表".localized)
            .accessibilityLabel(isDataDirsScanning ? "正在扫描...".localized : "刷新列表".localized)
        }
    }

    /// Tab 切换按钮（顶部工具栏用）
    struct TabButton: View {
        let title: String
        var systemImage: String? = nil
        let isSelected: Bool
        let action: () -> Void

        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .medium))
                    }
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                }
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected
                              ? Color.accentColor.opacity(0.12)
                              : (isHovered ? Color.primary.opacity(0.04) : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
        }
    }

    // MARK: - 逻辑函数
    
    func getMoveButtonTitle() -> (text: String, isError: Bool) {
        // 获取所有选中且可迁移的应用
        let validApps = selectedLocalApps.compactMap { id in
            localApps.first { $0.id == id }
        }.filter { !$0.isSystemApp && !$0.isRunning && $0.status != AppStatus.linked }
        
        if selectedLocalApps.isEmpty {
            return ("迁移到外部".localized, false)
        }

        if validApps.isEmpty {
            // 检查是否全是不可迁移的
            let selectedAppsData = selectedLocalApps.compactMap { id in localApps.first { $0.id == id } }
            if selectedAppsData.contains(where: { $0.isSystemApp }) { return ("含系统应用".localized, true) }
            if selectedAppsData.contains(where: { $0.isRunning }) { return ("含运行中应用".localized, true) }
            if selectedAppsData.contains(where: { $0.status == AppStatus.linked }) { return ("已链接".localized, false) }
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
        }.filter { !$0.isSystemApp && !$0.isRunning && $0.status != AppStatus.linked }
        
        return !validApps.isEmpty
    }
    
    var canLinkIn: Bool {
        // 至少有一个可链接的应用
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { $0.status == AppStatus.unlinked || $0.status == AppStatus.external }
        
        return !validApps.isEmpty
    }
    
    func getLinkButtonTitle() -> String {
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { $0.status == AppStatus.unlinked || $0.status == AppStatus.external }
        
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
        if app.status == AppStatus.linked {
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
    
    @MainActor
    func scanLocalApps(forceSizeRefresh: Bool = false) {
        guard isVisible else { return }
        guard let request = localScanState.begin(externalDirectory: externalDriveURL,
                                                customPaths: customLocalScanPaths,
                                                isManual: forceSizeRefresh) else { return }
        let scanID = AppLogger.shared.makeOperationID(prefix: "scan-local-apps")
        AppLogger.shared.logContext(
            "开始扫描本地应用",
            details: [("scan_id", scanID), ("directory", localAppsURL.path)]
        )
        // Run on background task to avoid blocking Main Thread
        let maintenanceGeneration = AppMigrationService.maintenanceGeneration
        Task.detached(priority: .userInitiated) {
            // Gather data needed for scanning
            let runningAppURLs = await MainActor.run { self.getRunningAppURLs() }
            let externalAppsDir = request.externalDirectory
            let customPaths = request.customPaths

            // Use Actor
            let scanner = AppScanner()
            var allApps = await scanner.scanLocalApps(
                at: self.localAppsURL,
                runningAppURLs: runningAppURLs,
                externalAppsDir: externalAppsDir
            )

            // 扫描自定义目录
            for path in customPaths {
                let customApps = await scanner.scanLocalApps(
                    at: URL(fileURLWithPath: path),
                    runningAppURLs: runningAppURLs,
                    externalAppsDir: externalAppsDir
                )
                let existingPaths = Set(allApps.map { $0.path.path })
                for app in customApps where !existingPaths.contains(app.path.path) {
                    allApps.append(app)
                }
            }

            let finalApps = allApps

            guard await MainActor.run(body: { self.isCurrentScan(request, isLocal: true) }) else { return }

            // Follow each surviving portal's recorded target, not a same-named app.
            for localApp in finalApps {
                guard await MainActor.run(body: {
                    self.isCurrentScan(request, isLocal: true) && !self.operationState.isBusy
                }) else { break }
                _ = AppPortalMaintenance.refreshEntries(at: localApp.path, expectedGeneration: maintenanceGeneration)
            }
            do { try AppSearchRecordStore.shared.reconcileLocalPresence() }
            catch { AppLogger.shared.logError("核对本地入口搜索状态失败", error: error) }

            AppLogger.shared.logContext(
                "本地应用扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("count", String(finalApps.count)),
                    ("custom_dirs", String(customPaths.count)),
                    ("status_summary", self.summarizeStatuses(for: finalApps))
                ]
            )

            // 会话缓存填充 + 后台计算缺失项（命中项瞬时显示，无“计算中”闪烁）
            await self.applySizes(for: finalApps, isLocal: true, scanner: scanner, request: request)
        }
    }

    private func readVersion(from appURL: URL) -> String {
        let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        return (plist?["CFBundleShortVersionString"] as? String) ?? ""
    }

    @MainActor
    func scanExternalApps(forceSizeRefresh: Bool = false) {
        guard isVisible else { return }
        guard let request = externalScanState.begin(externalDirectory: externalDriveURL,
                                                   customPaths: customLocalScanPaths,
                                                   isManual: forceSizeRefresh) else { return }
        guard let dir = externalDriveURL else {
            AppLogger.shared.log("未选择外部路径，清空外部应用列表", level: "TRACE")
            self.externalApps = []
            self.selectedExternalApps.removeAll()
            externalScanState.finish(request)
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
            let customPaths = request.customPaths
            let localDirs = [URL(fileURLWithPath: "/Applications")]
                + customPaths.map { URL(fileURLWithPath: $0) }
            
            let scanner = AppScanner()
            var newApps: [AppItem] = []
            for localDir in localDirs {
                let scannedApps = await scanner.scanExternalApps(at: scanDir, localAppsDir: localDir)
                newApps = self.mergeExternalApps(newApps, with: scannedApps)
            }
            
            AppLogger.shared.logContext(
                "外部应用扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("count", String(newApps.count)),
                    ("status_summary", self.summarizeStatuses(for: newApps))
                ]
            )
            // 会话缓存填充 + 后台计算缺失项（命中项瞬时显示，无“计算中”闪烁）
            await self.applySizes(for: newApps, isLocal: false, scanner: scanner, request: request)
        }
    }

    nonisolated func mergeExternalApps(_ existingApps: [AppItem], with scannedApps: [AppItem]) -> [AppItem] {
        var mergedApps = existingApps
        for app in scannedApps {
            if let index = mergedApps.firstIndex(where: { $0.path.standardizedFileURL == app.path.standardizedFileURL }) {
                if shouldPreferExternalApp(app, over: mergedApps[index]) {
                    mergedApps[index] = app
                }
            } else {
                mergedApps.append(app)
            }
        }
        return mergedApps
    }

    nonisolated private func shouldPreferExternalApp(_ candidate: AppItem, over existing: AppItem) -> Bool {
        externalAppStatusRank(candidate.status) > externalAppStatusRank(existing.status)
    }

    nonisolated private func externalAppStatusRank(_ status: String) -> Int {
        switch status {
        case AppStatus.linked:
            return 3
        case AppStatus.partialLinked:
            return 2
        case AppStatus.unlinked, AppStatus.external:
            return 1
        default:
            return 0
        }
    }
    
    /// 目录 mtime 仅用于自动扫描的快速缓存判断；手动刷新始终重测包内内容。
    struct CachedAppSize {
        let size: String
        let bytes: Int64
        let mtime: Date?
        let isLocalPortal: Bool

        init(size: String, bytes: Int64, mtime: Date?, isLocalPortal: Bool = false) {
            self.size = size
            self.bytes = bytes
            self.mtime = mtime
            self.isLocalPortal = isLocalPortal
        }
    }

    nonisolated func bundleModificationDate(for app: AppItem) -> Date? {
        (try? app.path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 强制刷新时先保留可用的旧大小以免闪烁，同时将所有条目加入重测队列。
    nonisolated func fillCachedSizes(
        into apps: [AppItem],
        cache: [String: CachedAppSize],
        isLocal: Bool = true,
        forceRefresh: Bool = false
    ) -> (filled: [AppItem], misses: [(app: AppItem, mtime: Date?)]) {
        var filled = apps
        var misses: [(app: AppItem, mtime: Date?)] = []
        for i in filled.indices {
            let currentMtime = bundleModificationDate(for: filled[i])
            let isLocalPortal = isLocal && filled[i].status == AppStatus.linked
            let entry = cache[filled[i].id]
            let valid = currentMtime != nil && entry?.mtime == currentMtime
                && entry?.isLocalPortal == isLocalPortal
            if let entry, valid {
                filled[i].size = entry.size
                filled[i].sizeBytes = entry.bytes
            }
            if forceRefresh || !valid {
                misses.append((filled[i], currentMtime))
            }
        }
        return (filled, misses)
    }

    /// AppScanner 串行读取目录；每完成一项便更新大小，避免慢目录拖住所有行。
    private func computeAndStoreSizes(
        misses: [(app: AppItem, mtime: Date?)],
        isLocal: Bool,
        scanner: AppScanner,
        request: ScanRequest
    ) async {
        for miss in misses {
            guard await MainActor.run(body: { self.isCurrentScan(request, isLocal: isLocal) }) else { return }
            let bytes = await scanner.calculateDisplayedSize(for: miss.app, isLocalEntry: isLocal)
            await MainActor.run {
                guard self.isCurrentScan(request, isLocal: isLocal) else { return }
                let id = miss.app.id
                let sizeString = LocalizedByteCountFormatter.string(fromByteCount: bytes)
                self.sizeCache[id] = CachedAppSize(size: sizeString, bytes: bytes, mtime: miss.mtime,
                                                  isLocalPortal: isLocal && miss.app.status == AppStatus.linked)
                if isLocal {
                    if let index = self.localApps.firstIndex(where: { $0.id == id }) {
                        self.localApps[index].size = sizeString
                        self.localApps[index].sizeBytes = bytes
                    }
                } else {
                    if let index = self.externalApps.firstIndex(where: { $0.id == id }) {
                        self.externalApps[index].size = sizeString
                        self.externalApps[index].sizeBytes = bytes
                    }
                }
            }
        }
        // 空列表或全部命中缓存时也必须结束进度；过期请求不能结束新一轮扫描。
        await MainActor.run {
            guard self.isCurrentScan(request, isLocal: isLocal) else { return }
            if isLocal {
                self.localScanState.finish(request)
            } else {
                self.externalScanState.finish(request)
            }
        }
    }

    /// 统一的体积应用入口：先用会话缓存填充列表后赋值（命中项瞬时显示、无“计算中”闪烁），
    /// 再在后台计算缺失/失效项并写回缓存。所有扫描路径都走这里。
    @MainActor
    private func isCurrentScan(_ request: ScanRequest, isLocal: Bool) -> Bool {
        isVisible
            && (isLocal ? localScanState.request : externalScanState.request) == request
            && externalDriveURL == request.externalDirectory
            && customLocalScanPaths == request.customPaths
    }

    private func applySizes(for apps: [AppItem], isLocal: Bool, scanner: AppScanner, request: ScanRequest) async {
        guard await MainActor.run(body: { self.isCurrentScan(request, isLocal: isLocal) }) else { return }
        let cache = await MainActor.run { self.sizeCache }
        let (filled, misses) = fillCachedSizes(into: apps, cache: cache, isLocal: isLocal,
                                             forceRefresh: request.forceSizeRefresh)
        let committed = await MainActor.run {
            guard self.isCurrentScan(request, isLocal: isLocal) else { return false }
            if isLocal {
                self.localApps = filled
                self.selectedLocalApps.formIntersection(Set(filled.map(\.id)))
                // 兜底路径：启动快检之后本会话新签名的应用，仍然会在扫描完成时提醒一次。
                self.presentSignatureRepairReminderIfNeeded(
                    apps: filled.filter(\.signatureReplaced).map(\.signatureRepairEntry)
                )
            } else {
                self.externalApps = filled
                self.selectedExternalApps.formIntersection(Set(filled.map(\.id)))
            }
            return true
        }
        guard committed else { return }
        await computeAndStoreSizes(misses: misses, isLocal: isLocal, scanner: scanner, request: request)
    }

    @discardableResult
    func openPanelForExternalDrive() -> URL? {
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
            return url
        } else {
            AppLogger.shared.log("用户取消选择外部路径", level: "TRACE")
            return nil
        }
    }

    // MARK: - 自定义本地扫描目录

    private var localAppsSubtitle: String {
        let base = "/Applications"
        if customLocalScanPaths.isEmpty {
            return base
        }
        return "\(base) + \(customLocalScanPaths.count) \("个目录".localized)"
    }

    private var localScanSourcesMenu: some View {
        Menu {
            Text(verbatim: "/Applications")
                .foregroundColor(.secondary)

            Divider()

            ForEach(customLocalScanPaths, id: \.self) { path in
                Button(role: .destructive) {
                    removeCustomLocalScanPath(path)
                } label: {
                    Label((path as NSString).lastPathComponent, systemImage: "xmark.circle")
                }
                .help(path)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                Text("\(customLocalScanPaths.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(localAppsSubtitle)
    }

    func addCustomLocalScanPath() {
        let panel = NSOpenPanel()
        panel.prompt = "选择文件夹".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择要额外扫描的应用目录".localized
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        customLocalScanPaths = UserDefaults.standard.stringArray(forKey: "customLocalScanPaths") ?? []
        guard !customLocalScanPaths.contains(path) else { return }
        customLocalScanPaths.append(path)
        UserDefaults.standard.set(customLocalScanPaths, forKey: "customLocalScanPaths")
        startMonitoringLocal()
        scanBothAppsAtomic()
    }

    func removeCustomLocalScanPath(_ path: String) {
        customLocalScanPaths = UserDefaults.standard.stringArray(forKey: "customLocalScanPaths") ?? []
        customLocalScanPaths.removeAll { $0 == path }
        UserDefaults.standard.set(customLocalScanPaths, forKey: "customLocalScanPaths")
        startMonitoringLocal()
        scanBothAppsAtomic()
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
        AppRunningState.isRunning(
            appURL: url,
            applications: NSWorkspace.shared.runningApplications.map {
                AppRunningState.RunningApplication(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
            }
        )
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

    /// 先发布已完成的迁移状态，再安排完整扫描；迁移前启动的旧扫描不可覆盖此结果。
    @MainActor
    private func recordCompletedTransfer(_ transfer: AppListTransfer) {
        do { try AppPortalMaintenance.recordCompletedTransfer(transfer) }
        catch { AppLogger.shared.logError("保存应用搜索记录失败", error: error) }
        localScanState.invalidate()
        externalScanState.invalidate()
        let changedIDs = transfer.apply(localApps: &localApps, externalApps: &externalApps)
        for id in changedIDs { sizeCache.removeValue(forKey: id) }
        selectedLocalApps.formIntersection(Set(localApps.map(\.id)))
        selectedExternalApps.formIntersection(Set(externalApps.map(\.id)))
        needsAppRescan = true
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
        guard let activityToken = operationState.begin() else { return }
        isMigrating = true
        progressTotal = 1
        progressCurrent = 1
        progressAppName = app.name
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        progressTitle = "正在迁移应用...".localized
        showProgress = true

        Task { @MainActor in
            defer { operationState.finish(activityToken) }
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
                            self.progressFileName = progress.currentFile
                        }
                    }
                )
                recordCompletedTransfer(.movedOut(app, destination: destURL, isMASExternal: false))
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
                scanBothAppsAtomic()
            }
        }
    }

    func linkApp(appToLink: AppItem, destinationURL: URL) throws {
        try AppMigrationService().linkApp(appToLink: appToLink, destinationURL: destinationURL)
    }
    
    func deleteLink(app: AppItem) throws {
        // Capture targets while the entry still exists. Search exclusion outlives deletion.
        do { try AppPortalMaintenance.rememberEntries(at: app.path) }
        catch { AppLogger.shared.logError("保存删除前的应用搜索记录失败", error: error) }
        try AppMigrationService().deleteLink(app: app)
        do { try AppPortalMaintenance.recordDeletion(at: app.path) }
        catch { AppLogger.shared.logError("保存入口删除后的搜索状态失败", error: error) }
    }
    
    @discardableResult
    func moveBack(app: AppItem, localDestinationURL: URL, progressHandler: FileCopier.ProgressHandler?) async throws -> AppMigrationService.RestoreResult {
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
            guard !app.isSystemApp && !app.isRunning && app.status != AppStatus.linked else { return false }
            
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
            guard !app.isSystemApp && app.status != AppStatus.linked else { return false }
            
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

        // 受保护应用（App Store / root 拥有）预警：自动迁移可能因权限被拒，先提示用户
        let protectedApps = validApps.filter { protectedMigrationReason(for: $0) != nil }
        if !protectedApps.isEmpty {
            pendingProtectedApps = protectedApps
            pendingMigrationAfterWarning = validApps
            protectedAppsRequest = makeProtectedAppsRequest()
            return
        }

        proceedWithMigration(validApps: validApps, dest: dest)
    }

    /// 校验通过后的迁移收尾：先处理自更新应用确认，否则直接批量迁移。
    func proceedWithMigration(validApps: [AppItem], dest: URL) {
        // 检查是否包含自更新应用（Sparkle/Electron）
        let selfUpdaterApps = validApps.filter { $0.hasSelfUpdater }
        if !selfUpdaterApps.isEmpty {
            pendingSelfUpdaterApps = selfUpdaterApps
            pendingRemainingAppsForSelfUpdater = validApps.filter { !($0.hasSelfUpdater) }
            selfUpdaterIsLinkIn = false
            selfUpdaterRequest = makeSelfUpdaterRequest()
            return
        }

        // 直接迁移符合条件的应用
        executeBatchMove(apps: validApps, destination: dest)
    }

    /// 组装「App Store 应用外部安装」引导弹窗的内容快照。
    private func makeMASGuidanceRequest() -> WarningSheetRequest {
        WarningSheetRequest(
            title: "App Store 应用外部安装".localized,
            icon: "info.circle.fill",
            tint: .blue,
            intro: "macOS 15.1+ 支持将 App Store 应用安装到外部磁盘。\n\n请在 App Store → 设置中勾选「将大型 App 下载并安装到独立磁盘」，并选择当前外部驱动器。\n\n设置完成后点击「我已设置」，AppPorts 会自动创建 Applications 目录并检测管理这些应用。".localized,
            cancelTitle: "稍后".localized,
            actions: [
                WarningAction("打开 App Store 设置".localized) {
                    if let url = URL(string: "macappstores://settings") {
                        NSWorkspace.shared.open(url)
                    }
                },
                WarningAction("我已设置".localized, style: .preferred) {
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
            ]
        )
    }

    /// 组装「受保护应用」迁移预警的内容快照。
    private func makeProtectedAppsRequest() -> WarningSheetRequest {
        let names = pendingProtectedApps.map { $0.displayName }.joined(separator: "、")
        return WarningSheetRequest(
            title: "受保护的应用".localized,
            tint: .orange,
            intro: String(format: "以下应用来自 App Store 或归属系统（root），受 macOS 保护：\n\n%@\n\n迁移时 AppPorts 会先把应用完整复制到外部存储，再删除本地副本。\n\n删除本地副本时系统会要求输入管理员密码，你也会听到垃圾桶的声音 —— 这都是正常的，点允许即可，AppPorts 会自动完成后续步骤。".localized, names),
            onCancel: {
                pendingProtectedApps = []
                pendingMigrationAfterWarning = []
            },
            actions: [
                WarningAction("继续迁移".localized, style: .preferred) {
                    let apps = pendingMigrationAfterWarning
                    pendingProtectedApps = []
                    pendingMigrationAfterWarning = []
                    if let dest = externalDriveURL {
                        proceedWithMigration(validApps: apps, dest: dest)
                    }
                }
            ]
        )
    }

    /// 组装「自更新应用迁移」确认弹窗的内容快照。
    private func makeSelfUpdaterRequest() -> WarningSheetRequest {
        let names = pendingSelfUpdaterApps.map { $0.displayName }.joined(separator: "、")
        return WarningSheetRequest(
            title: "自更新应用迁移".localized,
            icon: "arrow.triangle.2.circlepath",
            tint: .orange,
            intro: String(format: "以下应用支持自动更新，迁移后应用内更新可能导致外部应用丢失：\n\n%@\n\n• 锁定迁移：外部应用被锁定，阻止更新破坏，需通过 AppPorts 迁回后更新\n• 非锁定迁移：不锁定外部应用，应用内更新可能删除外部应用\n\n建议选择锁定迁移以保护数据安全。".localized, names),
            onCancel: {
                pendingSelfUpdaterApps = []
                pendingRemainingAppsForSelfUpdater = []
            },
            actions: [
                WarningAction("非锁定迁移".localized) {
                    let allApps = pendingSelfUpdaterApps + pendingRemainingAppsForSelfUpdater
                    if selfUpdaterIsLinkIn {
                        executeBatchLinkIn(apps: allApps, lockExternal: false)
                    } else if let dest = externalDriveURL {
                        executeBatchMove(apps: allApps, destination: dest, lockExternal: false)
                    }
                    pendingSelfUpdaterApps = []
                    pendingRemainingAppsForSelfUpdater = []
                },
                WarningAction("锁定迁移".localized, style: .preferred) {
                    let allApps = pendingSelfUpdaterApps + pendingRemainingAppsForSelfUpdater
                    if selfUpdaterIsLinkIn {
                        executeBatchLinkIn(apps: allApps, lockExternal: true)
                    } else if let dest = externalDriveURL {
                        executeBatchMove(apps: allApps, destination: dest, lockExternal: true)
                    }
                    pendingSelfUpdaterApps = []
                    pendingRemainingAppsForSelfUpdater = []
                }
            ]
        )
    }

    /// 应用是否“受保护、难以自动迁移”：App Store 应用或归属 root 的包。
    /// 这类应用从 /Applications 删除/替换通常会因权限被拒（NSFileWriteNoPermissionError 513）。
    func protectedMigrationReason(for app: AppItem) -> String? {
        if app.isAppStoreApp { return "App Store".localized }
        if isRootOwnedBundle(at: app.path) { return "root" }
        return nil
    }

    /// 判断包是否归属 root（且当前用户不是 root）——普通删除会因权限失败。
    func isRootOwnedBundle(at url: URL) -> Bool {
        guard getuid() != 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let ownerID = (attrs[.ownerAccountID] as? NSNumber)?.uintValue else {
            return false
        }
        return ownerID == 0
    }

    /// 将迁移失败的底层错误转成更友好的说明：权限类错误指向“受保护应用”原因，避免直接抛出晦涩的系统错误。
    func friendlyMigrationFailure(appName: String, error: Error) -> String {
        let nsError = error as NSError
        let isPermissionDenied =
            (nsError.domain == NSCocoaErrorDomain &&
                (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError)) ||
            (nsError.domain == NSPOSIXErrorDomain &&
                (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)))
        if isPermissionDenied {
            return String(
                format: "%@：权限不足，无法删除或替换本地副本。该应用可能来自 App Store 或归属系统（root）。建议在访达中手动迁移后，再用 AppPorts 创建链接。".localized,
                appName
            )
        }
        return "\(appName): \(error.localizedDescription)"
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
        
        guard let activityToken = operationState.begin() else { return }
        isMigrating = true
        progressTotal = apps.count
        progressCurrent = 0
        progressTitle = "正在迁移应用...".localized
        showProgress = true
        
        var errors: [String] = []
        
        Task { @MainActor in
            defer { operationState.finish(activityToken) }
            for app in apps {
                await MainActor.run {
                    progressAppName = app.name
                    progressCurrent += 1
                    progressBytes = 0
                    progressTotalBytes = 0
                    progressFileName = ""
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
                            self.progressFileName = progress.currentFile
                        }
                    }
                    recordCompletedTransfer(.movedOut(app, destination: destURL,
                                                       isMASExternal: app.isAppStoreApp && AppMigrationService.isMASExternalInstallSupported))
                    AppLogger.shared.logContext(
                        "批量迁移单项成功",
                        details: [("batch_id", batchID), ("app_name", app.displayName)]
                    )
                } catch {
                    errors.append(friendlyMigrationFailure(appName: app.name, error: error))
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
                scanBothAppsAtomic()

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
        }.filter { $0.status == AppStatus.unlinked || $0.status == AppStatus.external || $0.status == AppStatus.partialLinked }

        guard !validApps.isEmpty else { return }

        // 检查是否包含自更新应用
        let selfUpdaterApps = validApps.filter { $0.hasSelfUpdater }
        if !selfUpdaterApps.isEmpty {
            pendingSelfUpdaterApps = selfUpdaterApps
            pendingRemainingAppsForSelfUpdater = validApps.filter { !($0.hasSelfUpdater) }
            selfUpdaterIsLinkIn = true
            selfUpdaterRequest = makeSelfUpdaterRequest()
            return
        }

        executeBatchLinkIn(apps: validApps, lockExternal: true)
    }

    private func executeBatchLinkIn(apps: [AppItem], lockExternal: Bool) {
        guard !apps.isEmpty else { return }

        guard let activityToken = operationState.begin() else { return }
        isMigrating = true
        progressTitle = "链接回本地".localized
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
        
        Task { @MainActor in
            defer { operationState.finish(activityToken) }
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
                    status: AppStatus.unlinked,
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
                    recordCompletedTransfer(.linkedIn(item.app, localDestination: destination))
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
                scanBothAppsAtomic()

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
        guard let activityToken = operationState.begin() else { return }
        defer { operationState.finish(activityToken) }
        AppLogger.shared.logContext(
            "用户请求删除本地入口",
            details: [("app_name", app.displayName), ("path", app.path.path), ("status", app.status)]
        )
        do {
            try deleteLink(app: app)
            scanLocalApps(); scanExternalApps()
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

    func performRepairDockShortcuts(app: AppItem) {
        guard let activityToken = operationState.begin() else { return }
        progressTitle = "修复 Dock 图标".localized
        progressAppName = app.displayName
        progressCurrent = 1
        progressTotal = 1
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        showProgress = true

        Task { @MainActor in
            defer {
                showProgress = false
                operationState.finish(activityToken)
            }
            do {
                let updatedCount = try await Task.detached(priority: .userInitiated) {
                    try AppMigrationService().repairDockShortcuts(for: app)
                }.value
                AppLogger.shared.logContext(
                    "用户修复 Dock 固定项完成",
                    details: [("app_name", app.displayName), ("updated_count", String(updatedCount))]
                )
                alertTitle = updatedCount > 0 ? "Dock 图标已修复".localized : "Dock 图标无需修复".localized
                alertMessage = updatedCount > 0
                    ? "已更新现有 Dock 固定项，位置保持不变。Dock 将短暂刷新；从 Dock 打开此应用需要连接外部存储。".localized
                    : "没有需要更新的 Dock 固定项。如果还未固定此应用，请打开应用后选择“在程序坞中保留”。".localized
                showAlert = true
            } catch {
                AppLogger.shared.logError(
                    "修复 Dock 固定项失败", error: error, errorCode: "APP-DOCK-REPAIR-FAILED",
                    context: [("app_name", app.displayName)], relatedURLs: [("local", app.path)]
                )
                showError(
                    title: "Dock 图标修复失败".localized,
                    message: "无法更新 Dock 固定项。请确认外部存储已连接后重试；也可以移除旧图标，再将运行中的应用保留在程序坞中。".localized
                )
            }
        }
    }

    private func localDestinationForMoveBack(app: AppItem) -> URL {
        AppMigrationService().localDestinationForRestore(
            of: app,
            defaultDirectory: localAppsURL,
            additionalDirectories: customLocalScanPaths.map { URL(fileURLWithPath: $0) }
        )
    }

    func performMoveBack(app: AppItem) {
        // 已链接的应用：传进来的可能是本地入口记录，不是本体。直接用它会变成「入口还原到入口自己」，
        // 入口检查认不出，于是报「本地已存在同名真实文件，无法覆盖」。先换成外部本体记录。
        let target = AppMigrationService().externalCounterpart(of: app, in: externalApps) ?? app
        let operationID = AppLogger.shared.makeOperationID(prefix: "single-move-back")
        let destination = localDestinationForMoveBack(app: target)
        AppLogger.shared.logContext(
            "用户请求还原单个应用",
            details: [
                ("operation_id", operationID),
                ("app_name", target.displayName),
                ("source", target.path.path),
                ("destination", destination.path),
                ("resolved_from_local_portal", target.path == app.path ? "false" : "true")
            ]
        )
        guard let activityToken = operationState.begin() else { return }
        isMigrating = true
        progressTotal = 1
        progressCurrent = 1
        progressAppName = target.displayName
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        progressTitle = "还原".localized
        showProgress = true
        
        Task { @MainActor in
            defer { operationState.finish(activityToken) }
            do {
                let result = try await moveBack(app: target, localDestinationURL: destination) { progress in
                    await MainActor.run {
                        self.progressBytes = progress.copiedBytes
                        self.progressTotalBytes = progress.totalBytes
                        self.progressFileName = progress.currentFile
                    }
                }
                recordCompletedTransfer(.movedBack(target, localDestination: destination,
                                                    externalSourceRemains: result.externalSourceRemains,
                                                    retiredLocalURLs: result.retiredLocalPortalURLs))
                AppLogger.shared.logContext(
                    "单个应用还原成功",
                    details: [("operation_id", operationID), ("app_name", target.displayName)]
                )
            } catch {
                AppLogger.shared.logError(
                    "单个应用还原失败",
                    error: error,
                    context: [("operation_id", operationID), ("app_name", target.displayName)],
                    relatedURLs: [("source", target.path), ("destination", destination)]
                )
                await MainActor.run {
                    showError(title: "错误".localized, message: error.localizedDescription)
                }
            }
            
            await MainActor.run {
                showProgress = false
                isMigrating = false
                scanBothAppsAtomic()
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
        
        guard let activityToken = operationState.begin() else { return }
        isMigrating = true
        progressTotal = validApps.count
        progressCurrent = 0
        progressTitle = "还原".localized
        showProgress = true
        
        var errors: [String] = []
        
        Task { @MainActor in
            defer { operationState.finish(activityToken) }
            for app in validApps {
                await MainActor.run {
                    progressAppName = app.displayName
                    progressCurrent += 1
                    progressBytes = 0
                    progressTotalBytes = 0
                    progressFileName = ""
                }
                
                let destination = localDestinationForMoveBack(app: app)
                AppLogger.shared.logContext(
                    "批量还原单项开始",
                    details: [("batch_id", batchID), ("app_name", app.displayName), ("destination", destination.path)],
                    level: "TRACE"
                )
                
                do {
                    let result = try await moveBack(app: app, localDestinationURL: destination) { progress in
                        await MainActor.run {
                            self.progressBytes = progress.copiedBytes
                            self.progressTotalBytes = progress.totalBytes
                            self.progressFileName = progress.currentFile
                        }
                    }
                    recordCompletedTransfer(.movedBack(app, localDestination: destination,
                                                        externalSourceRemains: result.externalSourceRemains,
                                                        retiredLocalURLs: result.retiredLocalPortalURLs))
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
                scanBothAppsAtomic()

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

    /// 迁移前备份完整原始应用（不执行签名），确保之后可恢复原始签名与授权
    func performBackupSignature(app: AppItem) {
        guard let activityToken = operationState.begin() else { return }
        Task { @MainActor in
            defer { operationState.finish(activityToken) }
            do {
                let realURL = try resolveRealAppURL(for: app)
                try await performBackupSignature(at: realURL, bundleID: getBundleIdentifier(from: realURL))
            } catch {
                AppLogger.shared.logError(
                    "备份原始应用失败",
                    error: error,
                    errorCode: "BACKUP-SIGNATURE-FAILED",
                    context: [("app_name", app.displayName)],
                    relatedURLs: [("target_app", app.displayURL)]
                )
            }
        }
    }

    func performSingleResign(
        app: AppItem,
        silent: Bool = false,
        approvedSandboxedTarget: DataMigrationWorkflow.SigningTarget? = nil
    ) {
        guard !isAppRunning(url: app.displayURL) else {
            showError(title: "签名失败".localized, message: AppMoverError.appIsRunning.localizedDescription)
            return
        }
        // 经典模式允许对沙盒应用重签名，但每次都要说明后果；非经典模式由 CodeSigner 拒绝。
        if classicModeActive, !silent,
           let target = try? DataMigrationWorkflow.signingTarget(at: app.displayURL),
           target.isSandboxed, approvedSandboxedTarget != target {
            pendingClassicResignApp = app
            pendingClassicResignTarget = target
            classicResignRequest = WarningSheetRequest(
                title: "对沙盒应用重签名".localized,
                intro: classicResignConfirmMessage,
                acknowledgementTitle: "我已了解以上风险".localized,
                onCancel: {
                    pendingClassicResignApp = nil
                    pendingClassicResignTarget = nil
                },
                actions: [
                    WarningAction("仍然重签名".localized, style: .destructive, requiresAcknowledgement: true) {
                        confirmClassicResign()
                    }
                ]
            )
            return
        }
        AppLogger.shared.logContext(
            "用户请求重签名单个应用",
            details: [("app_name", app.displayName), ("path", app.path.path), ("silent", silent ? "true" : "false")]
        )

        guard let activityToken = operationState.begin() else { return }
        progressTitle = "重签名此应用".localized
        progressAppName = app.displayName
        progressCurrent = 1
        progressTotal = 1
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        showProgress = true
        Task { @MainActor in
            defer {
                showProgress = false
                operationState.finish(activityToken)
            }
            do {
                let target = try DataMigrationWorkflow.signingTarget(at: app.displayURL)
                if let approvedSandboxedTarget, approvedSandboxedTarget != target {
                    throw CodeSigner.SigningError.applicationChanged
                }
                let sandboxedAppApproved = target.isSandboxed
                    && classicModeActive && approvedSandboxedTarget == target
                try await performResign(at: target.url, bundleID: getBundleIdentifier(from: target.url), allowSandboxed: sandboxedAppApproved)
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
        restoreSignature(app: app, originalApplication: nil)
    }

    private func restoreSignature(app: AppItem, originalApplication: URL?) {
        guard !isAppRunning(url: app.displayURL) else {
            showError(title: "签名失败".localized, message: AppMoverError.appIsRunning.localizedDescription)
            return
        }
        guard let activityToken = operationState.begin() else { return }
        progressTitle = "恢复原始签名".localized
        progressAppName = app.displayName
        progressCurrent = 1
        progressTotal = 1
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        showProgress = true
        Task { @MainActor in
            defer {
                showProgress = false
                operationState.finish(activityToken)
            }
            let signer = CodeSigner()
            do {
                // 恢复沙盒身份后，符号链接不能再用于访问容器外的数据。
                let directories = await DataDirScanner().scanLibraryDirs(for: app)
                let hasLinkedContainers = directories.contains {
                    ($0.type == .containers || $0.type == .groupContainers)
                        && [DataDirStatus.linked, DataDirStatus.needsNormalization, DataDirStatus.existingSymlink].contains($0.status)
                        && $0.linkedDestination != nil
                }
                guard !hasLinkedContainers else {
                    throw CodeSigner.SigningError.restoreFailed("请先在「应用数据」中还原经典模式迁移的容器目录，再恢复签名。恢复沙盒身份后，应用无法通过符号链接读取容器外的数据。".localized)
                }
                let realURL = try resolveRealAppURL(for: app)
                guard let bundleID = getBundleIdentifier(from: realURL) else {
                    throw CodeSigner.SigningError.restoreFailed("无法读取应用 Bundle Identifier".localized)
                }
                AppLogger.shared.logContext(
                    "用户请求恢复原始签名",
                    details: [("app_name", app.displayName), ("real_path", realURL.path), ("bundle_id", bundleID)]
                )
                guard !isAppRunning(url: realURL) else { throw AppMoverError.appIsRunning }
                try await signer.restoreSignature(appURL: realURL, bundleIdentifier: bundleID, originalApplication: originalApplication)
                await MainActor.run {
                    scanLocalApps()
                    scanExternalApps()
                }
            } catch CodeSigner.SigningError.legacyBackupIncomplete {
                offerOriginalApplication(for: app, reason: CodeSigner.SigningError.legacyBackupIncomplete.localizedDescription)
            } catch CodeSigner.SigningError.applicationChanged {
                offerOriginalApplication(for: app, reason: CodeSigner.SigningError.applicationChanged.localizedDescription)
            } catch {
                await MainActor.run {
                    showError(title: "恢复签名失败".localized, message: error.localizedDescription)
                }
            }
        }
    }

    private func offerOriginalApplication(for app: AppItem, reason: String) {
        signatureRestoreSourceRequest = WarningSheetRequest(
            title: "恢复原始签名".localized,
            icon: "arrow.counterclockwise",
            tint: .blue,
            intro: reason + "\n\n" + "选择同版本的官方原版 .app 后，AppPorts 会校验并替换当前应用文件。应用数据目录不会被替换；本地启动入口仍指向当前应用位置。".localized,
            onCancel: {},
            actions: [WarningAction("选择原版应用…".localized, style: .preferred) {
                let panel = NSOpenPanel()
                panel.title = "选择同版本的官方原版应用".localized
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.treatsFilePackagesAsDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.applicationBundle]
                panel.begin { response in
                    guard response == .OK, let source = panel.url else { return }
                    restoreSignature(app: app, originalApplication: source)
                }
            }]
        )
    }

    /// 从指定 URL 读取 Bundle Identifier
    nonisolated func getBundleIdentifier(from url: URL) -> String? {
        CodeSigner.bundleIdentifier(at: url)
    }

    /// 解析应用的真实路径（外部真实应用或本地真实应用），而非假壳
    /// 单应用文件夹从 displayURL 解析其内部 .app；找不到目标时终止签名。
    nonisolated func resolveRealAppURL(for app: AppItem) throws -> URL {
        try CodeSigner.resolveAppURL(at: app.displayURL)
    }

    /// 解析符号链接目标
    private func resolveSymlinkDestination(of url: URL) -> URL? {
        guard let rawPath = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        return URL(fileURLWithPath: rawPath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    /// 对指定 URL 执行重签名（用于数据目录迁移后签名真实应用）
    func performResign(at url: URL, bundleID: String?, allowSandboxed: Bool = false) async throws {
        AppLogger.shared.logContext(
            "重签名真实应用",
            details: [("path", url.path), ("bundle_id", bundleID ?? "nil"), ("allow_sandboxed", allowSandboxed ? "true" : "false")]
        )

        let signer = CodeSigner()
        do {
            try await signer.sign(appURL: url, bundleIdentifier: bundleID, allowSandboxed: allowSandboxed)
            AppLogger.shared.logContext(
                "重签名成功",
                details: [("path", url.path), ("bundle_id", bundleID ?? "nil")]
            )
            await MainActor.run {
                scanLocalApps()
                scanExternalApps()
            }
        } catch {
            AppLogger.shared.logError(
                "重签名失败（应用可能无法通过 macOS 签名校验）",
                error: error,
                errorCode: "RESIGN-FAILED",
                context: [("path", url.path), ("bundle_id", bundleID ?? "nil")],
                relatedURLs: [("target_app", url)]
            )
            throw error
        }
    }

    /// 对指定 URL 备份原始签名（用于数据目录迁移前）
    func performBackupSignature(at url: URL, bundleID: String?) async throws {
        guard let bundleID else {
            throw CodeSigner.SigningError.backupFailed("无法读取应用 Bundle Identifier".localized)
        }
        let signer = CodeSigner()
        do {
            try await signer.backupOriginalSignature(appURL: url, bundleIdentifier: bundleID)
            AppLogger.shared.logContext(
                "数据迁移前备份完整原始应用",
                details: [("path", url.path), ("bundle_id", bundleID)]
            )
        } catch {
            AppLogger.shared.logError(
                "数据迁移前备份原始应用失败，已中止迁移",
                error: error,
                errorCode: "DATA-BACKUP-SIGNATURE-FAILED",
                context: [("path", url.path), ("bundle_id", bundleID)],
                relatedURLs: [("target_app", url)]
            )
            throw error
        }
    }

    // MARK: - Monitoring Helpers
    
    func startMonitoringLocal() {
        localMonitor?.stopMonitoring()
        customLocalMonitors.forEach { $0.stopMonitoring() }
        customLocalMonitors.removeAll()

        AppLogger.shared.logContext("启动本地目录监控", details: [("path", localAppsURL.path)])

        let monitor = FolderMonitor(url: localAppsURL)
        monitor.startMonitoring { [self] in
            scheduleMonitorRescan(local: true)
        }
        self.localMonitor = monitor

        // 监控自定义目录
        for path in customLocalScanPaths {
            let url = URL(fileURLWithPath: path)
            let customMonitor = FolderMonitor(url: url)
            customMonitor.startMonitoring { [self] in
                scheduleMonitorRescan(local: true)
            }
            customLocalMonitors.append(customMonitor)
        }
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
        monitorRescanDebouncer.schedule { [self] in
            Task { @MainActor in
                AppLogger.shared.logContext("Monitor 防抖触发扫描", details: [("trigger", local ? "local" : "external")], level: "TRACE")
                self.scanBothAppsAtomic()
            }
        }
    }

    /// 同轮扫描本地和外部应用，一次性更新仍有效的结果，避免列表跳两下。
    @MainActor
    private func scanBothAppsAtomic() {
        guard isVisible else { return }
        guard !operationState.isBusy else {
            needsAppRescan = true
            return
        }
        needsAppRescan = false
        guard let localRequest = localScanState.begin(externalDirectory: externalDriveURL, customPaths: customLocalScanPaths),
              let externalRequest = externalScanState.begin(externalDirectory: externalDriveURL, customPaths: customLocalScanPaths) else { return }
        let externalDir = localRequest.externalDirectory
        let maintenanceGeneration = AppMigrationService.maintenanceGeneration
        Task.detached(priority: .userInitiated) {
            let scanner = AppScanner()
            let runningAppURLs = await MainActor.run { self.getRunningAppURLs() }
            let localDir = self.localAppsURL
            let customPaths = localRequest.customPaths

            // 扫描默认目录和自定义目录
            var newLocalApps = await scanner.scanLocalApps(
                at: localDir,
                runningAppURLs: runningAppURLs,
                externalAppsDir: externalDir
            )

            // 扫描自定义目录
            for path in customPaths {
                let customApps = await scanner.scanLocalApps(
                    at: URL(fileURLWithPath: path),
                    runningAppURLs: runningAppURLs,
                    externalAppsDir: externalDir
                )
                let existingPaths = Set(newLocalApps.map { $0.path.path })
                for app in customApps where !existingPaths.contains(app.path.path) {
                    newLocalApps.append(app)
                }
            }

            var newExternalApps: [AppItem] = []
            if let externalDir {
                let localDirs = [localDir] + customPaths.map { URL(fileURLWithPath: $0) }
                for directory in localDirs {
                    let scannedApps = await scanner.scanExternalApps(at: externalDir, localAppsDir: directory)
                    newExternalApps = self.mergeExternalApps(newExternalApps, with: scannedApps)
                }
            }

            guard await MainActor.run(body: {
                self.isCurrentScan(localRequest, isLocal: true) || self.isCurrentScan(externalRequest, isLocal: false)
            }) else { return }

            for localApp in newLocalApps {
                guard await MainActor.run(body: {
                    self.isCurrentScan(localRequest, isLocal: true) && !self.operationState.isBusy
                }) else { break }
                _ = AppPortalMaintenance.refreshEntries(at: localApp.path, expectedGeneration: maintenanceGeneration)
            }
            do { try AppSearchRecordStore.shared.reconcileLocalPresence() }
            catch { AppLogger.shared.logError("核对本地入口搜索状态失败", error: error) }

            // 会话缓存填充后一次性原子赋值，避免列表跳动与“计算中”闪烁；缺失项后台计算
            let cache = await MainActor.run { self.sizeCache }
            let (filledLocal, missesLocal) = self.fillCachedSizes(into: newLocalApps, cache: cache, isLocal: true,
                                                                  forceRefresh: localRequest.forceSizeRefresh)
            let (filledExternal, missesExternal) = self.fillCachedSizes(into: newExternalApps, cache: cache, isLocal: false,
                                                                        forceRefresh: externalRequest.forceSizeRefresh)
            let committed = await MainActor.run {
                let localIsCurrent = self.isCurrentScan(localRequest, isLocal: true)
                let externalIsCurrent = self.isCurrentScan(externalRequest, isLocal: false)
                // 单侧手动刷新可能已取代本轮请求，另一侧仍应完成更新。
                if localIsCurrent {
                    self.localApps = filledLocal
                    self.selectedLocalApps.formIntersection(Set(filledLocal.map(\.id)))
                    if missesLocal.isEmpty {
                        self.localScanState.finish(localRequest)
                    }
                }
                if externalIsCurrent {
                    self.externalApps = filledExternal
                    self.selectedExternalApps.formIntersection(Set(filledExternal.map(\.id)))
                    // 此侧已经完成时立即恢复按钮，不等待另一侧的目录体积计算。
                    if missesExternal.isEmpty {
                        self.externalScanState.finish(externalRequest)
                    }
                }
                return localIsCurrent || externalIsCurrent
            }
            guard committed else { return }
            await self.computeAndStoreSizes(misses: missesLocal, isLocal: true, scanner: scanner, request: localRequest)
            await self.computeAndStoreSizes(misses: missesExternal, isLocal: false, scanner: scanner, request: externalRequest)
        }
    }
    
    func stopMonitoringExternal() {
        AppLogger.shared.log("停止外部目录监控", level: "TRACE")
        externalMonitor?.stopMonitoring()
        externalMonitor = nil
    }

    // MARK: - 签名被替换的应用提醒

    private var signatureRepairReminderMessage: String {
        let names = signatureRepairReminderApps.map(\.displayName).joined(separator: "、")
        let count = Int64(signatureRepairReminderApps.count)
        if !MigrationPreferences.isMacOS27OrLater {
            return String(format: "AppPorts 曾用 Ad-hoc 签名替换了 %lld 个应用的开发者签名：\n\n%@\n\n升级到 macOS 27 后它们可能无法打开。建议升级前检查一遍：点这些应用右侧的「修复」按钮。".localized, count, names)
        }
        return String(format: "AppPorts 曾用 Ad-hoc 签名替换了 %lld 个应用的开发者签名：\n\n%@\n\n在 macOS 27 上它们可能无法打开。能正常打开的可以先不处理；打不开的点右侧的「修复」按钮。".localized, count, names)
    }

    private var classicResignConfirmMessage: String {
        String(format: "「%@」是沙盒应用。经典模式会先完整备份原应用，再重签并移除沙盒、应用组和钥匙串授权。在 macOS 27 上此应用可能无法打开；需要恢复时，先还原容器数据，再恢复原始签名。".localized, pendingClassicResignTarget?.url.lastPathComponent ?? "")
    }

    private func confirmClassicResign() {
        let app = pendingClassicResignApp
        let approvedTarget = pendingClassicResignTarget
        pendingClassicResignApp = nil
        pendingClassicResignTarget = nil
        guard let app, let approvedTarget else { return }
        DispatchQueue.main.async {
            self.performSingleResign(app: app, approvedSandboxedTarget: approvedTarget)
        }
    }

    private func signatureRepairSheet(for app: AppItem) -> some View {
        SignatureRepairSheet(
            app: localApps.first(where: { $0.id == app.id }) ?? app,
            onRestoreSignature: { performRestoreSignature(app: $0) },
            onMoveBack: { performMoveBack(app: $0) },
            onOpenDataDirs: { target in
                selectedDataDirsApp = target
                selectedDataDirsTab = .appDirs
                withAnimation { mainTab = .dataDirs }
            },
            onDismiss: { signatureRepairApp = nil }
        )
    }

    /// 启动时的独立检查：不等首次完整扫描，直接查「签名已被替换」的应用并提醒。
    @MainActor
    private func checkSignatureReplacedAppsOnLaunch() {
        guard !hasShownSignatureRepairReminder else { return }
        let roots = [localAppsURL] + customLocalScanPaths.map { URL(fileURLWithPath: $0) }
        Task.detached(priority: .userInitiated) {
            let scanner = AppScanner()
            let replaced = await scanner.signatureReplacedApps(searchRoots: roots)
            await MainActor.run {
                self.presentSignatureRepairReminderIfNeeded(apps: replaced)
            }
        }
    }

    /// 提醒一次；「以后再说」按当前应用集合记住，集合变化才再提醒。
    /// 本会话已提醒过就不再弹（含扫描完成时的兜底路径）。
    @MainActor
    private func presentSignatureRepairReminderIfNeeded(apps: [SignatureReplacedApp]) {
        guard !hasShownSignatureRepairReminder, !operationState.isBusy else { return }
        guard !apps.isEmpty else { return }
        let keys = Set(apps.map(\.dismissalKey))
        if keys.isSubset(of: MigrationPreferences.dismissedSignatureRepairApps) { return }
        hasShownSignatureRepairReminder = true
        signatureRepairReminderApps = apps
        AppLogger.shared.logContext(
            "提醒用户处理签名已被替换的应用",
            details: [("count", String(apps.count)), ("apps", apps.map(\.displayName).joined(separator: ", "))],
            level: "WARN"
        )
        signatureRepairReminderRequest = WarningSheetRequest(
            title: "检测到签名已被替换的应用".localized,
            icon: "exclamationmark.shield.fill",
            tint: .red,
            intro: signatureRepairReminderMessage,
            cancelTitle: "以后再说".localized,
            onCancel: { dismissSignatureRepairReminder() },
            actions: [
                WarningAction("查看".localized, style: .preferred) {
                    localAppFilter = .signatureReplaced
                    withAnimation { mainTab = .apps }
                }
            ]
        )
    }

    private func dismissSignatureRepairReminder() {
        var dismissed = MigrationPreferences.dismissedSignatureRepairApps
        for app in signatureRepairReminderApps {
            dismissed.insert(app.dismissalKey)
        }
        MigrationPreferences.dismissedSignatureRepairApps = dismissed
    }

    // MARK: - 容器卷自动挂载

    /// 挂载迁移的记录在 AppPorts 运行期间自动重挂：启动时一次，之后每次有卷挂载到系统时再试一次。
    private func startObservingVolumeMounts() {
        stopObservingVolumeMounts()
        let center = NSWorkspace.shared.notificationCenter
        volumeMountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                self.remountContainerVolumes(trigger: "volume-mounted")
            }
        }
        // 卷也可能被别的进程卸掉（拔盘、命令行）。这种情况没有重挂动作可做，
        // 但列表里的大小和状态已经过期，要刷新一次。
        volumeUnmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                self.refreshAfterExternalUnmount()
            }
        }
    }

    private func stopObservingVolumeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        if let volumeMountObserver {
            center.removeObserver(volumeMountObserver)
        }
        volumeMountObserver = nil
        if let volumeUnmountObserver {
            center.removeObserver(volumeUnmountObserver)
        }
        volumeUnmountObserver = nil
    }

    /// 挂载点被外部卸载：刷新列表。大小缓存按挂载状态分键，重算时会自己回到空目录的真实大小。
    @MainActor
    private func refreshAfterExternalUnmount() {
        let records = ContainerMountStore.shared.records()
        guard !records.isEmpty else { return }
        guard records.contains(where: { !DiskUtility.isMountPoint($0.mountPointURL) }) else { return }
        AppLogger.shared.logContext(
            "检测到容器挂载点被外部卸载，刷新数据目录",
            details: [("record_count", String(records.count))]
        )
        dataDirsRefreshTrigger += 1
    }

    @MainActor
    private func remountContainerVolumes(trigger: String) {
        // 测试宿主不应自动操作开发机上的真实容器卷。
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !ContainerMountStore.shared.records().isEmpty else { return }
        // 迁移进行中不动挂载点；操作结束后的目录变更刷新会再触发扫描。
        guard !operationState.isBusy else { return }
        Task.detached(priority: .utility) {
            // 登录代理（监听 /Volumes）可能正在挂同一批卷：拿到锁再动手，拿不到就交给它。
            let operationLock = OperationLock()
            guard await operationLock.acquire(timeout: OperationLock.appWaitTimeout) else {
                AppLogger.shared.logContext(
                    "容器卷自动挂载跳过",
                    details: [("trigger", trigger), ("reason", "挂载代理正在运行")]
                )
                return
            }
            defer { operationLock.release() }
            let outcomes = await ContainerVolumeMigrator().remountAvailableRecords()
            let mountedCount = outcomes.filter { $0.state == .mounted }.count
            AppLogger.shared.logContext(
                "容器卷自动挂载完成",
                details: [
                    ("trigger", trigger),
                    ("record_count", String(outcomes.count)),
                    ("newly_mounted", String(mountedCount)),
                    ("unavailable", String(outcomes.filter { $0.state == .unavailable }.count))
                ]
            )
            // 卷也可能是后台代理在别的进程里挂好的，这时 mountedCount 是 0，
            // 但列表里的大小还是挂载前的旧值，同样要刷新一次。
            let mountedRecords = outcomes.filter { $0.state == .mounted || $0.state == .alreadyMounted }
            if !mountedRecords.isEmpty {
                await MainActor.run { self.dataDirsRefreshTrigger += 1 }
            }
        }
    }
}

/// 统一防抖器：合并 FolderMonitor 的扫描请求，避免列表连续跳动
final class RescanDebouncer {
    private var work: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.rescanDebounce")

    func cancel() {
        queue.async { self.work?.cancel(); self.work = nil }
    }

    func schedule(action: @escaping () -> Void) {
        queue.async {
            self.work?.cancel()
            let item = DispatchWorkItem { action() }
            self.work = item
            self.queue.asyncAfter(deadline: .now() + 1.0, execute: item)
        }
    }
}
