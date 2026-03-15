//
//  ContentView.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI
import AppKit

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
    @State private var selectedLocalApps: Set<UUID> = []
    @State private var selectedExternalApps: Set<UUID> = []
    
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    @State private var showUpdateAlert = false
    @State private var updateURL: URL?
    
    // App Store 应用迁移确认
    @State private var showAppStoreConfirm = false
    @State private var pendingAppStoreApps: [AppItem] = []
    
    // 进度弹窗状态
    @State private var showProgress = false
    @State private var progressCurrent = 0
    @State private var progressTotal = 0
    @State private var progressAppName = ""
    @State private var isMigrating = false
    
    // 设置页面
    @State private var showAppStoreSettings = false
    
    // 单应用复制进度
    @State private var progressBytes: Int64 = 0
    @State private var progressTotalBytes: Int64 = 0

    private let fileManager = FileManager.default

    // Monitors
    @State private var localMonitor: FolderMonitor?
    @State private var externalMonitor: FolderMonitor?

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
                        Picker("排序方式".localized, selection: $sortOption) {
                            Text("按名称".localized).tag(SortOption.name)
                            Text("按大小".localized).tag(SortOption.size)
                        }
                    } label: {
                        Label("排序".localized, systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("排序方式")
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
                    onSelectExternalDrive: openPanelForExternalDrive
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
                                    onMoveBack: performMoveBack
                                )
                                .tag(app.id)
                                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)) // Add spacing around rows
                                .listRowSeparator(.hidden) // Keep hidden separators
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
                                onMoveBack: performMoveBack
                            )
                            .tag(app.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                            .listRowSeparator(.hidden)
                        }
                        .listStyle(.plain)
                    }
                }
                
                // 双按钮底部栏
                HStack(spacing: 8) {
                    // 链接回本地按钮
                    Button(action: performLinkIn) {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text(getLinkButtonTitle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!canLinkIn)
                    
                    // 迁移回本地按钮
                    Button(action: performBatchMoveBack) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.up.left")
                            Text(getMoveBackButtonTitle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(selectedExternalApps.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
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
                            self.alertTitle = "发现新版本".localized
                            self.alertMessage = String(format: "发现新版本 %@。\n%@".localized, release.tagName, release.body)
                            self.updateURL = URL(string: release.htmlUrl)
                            self.showUpdateAlert = true
                        }
                    }
                } catch {
                    AppLogger.shared.logError("检查更新失败", error: error)
                }
            }
        }
        .onChange(of: externalDriveURL) { oldValue, newValue in
            AppLogger.shared.logContext(
                "外部路径变更",
                details: [
                    ("old_path", oldValue?.path),
                    ("new_path", newValue?.path)
                ]
            )
            // Persistence
            if let url = newValue {
                UserDefaults.standard.set(url.path, forKey: "ExternalDrivePath")
                startMonitoringExternal(url: url)
            } else {
                UserDefaults.standard.removeObject(forKey: "ExternalDrivePath")
                stopMonitoringExternal()
            }
            scanExternalApps()
        }
        
        .alert(LocalizedStringKey(alertTitle.localized), isPresented: $showAlert) {
            Button("好的".localized, role: .cancel) { }
        } message: {
            Text(LocalizedStringKey(alertMessage.localized))
        }
        .alert("发现新版本".localized, isPresented: $showUpdateAlert) {
            Button("前往下载".localized, role: .none) {
                if let url = updateURL { NSWorkspace.shared.open(url) }
            }
            Button("以后再说".localized, role: .cancel) {}
        } message: {
            Text(alertMessage.localized)
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
                
                HStack {
                    Spacer()
                    Button(action: action) {
                        HStack(spacing: 8) {
                            Text(title.localized)
                                .fontWeight(.semibold)
                            Image(systemName: icon)
                        }
                        .frame(maxWidth: .infinity) // Fill width
                        .frame(height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEnabled)
                    .controlSize(.large)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .background(.bar) // Standard bar material
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
            return ("迁移到外部", false)
        }
        
        if validApps.isEmpty {
            // 检查是否全是不可迁移的
            let selectedAppsData = selectedLocalApps.compactMap { id in localApps.first { $0.id == id } }
            if selectedAppsData.contains(where: { $0.isSystemApp }) { return ("含系统应用", true) }
            if selectedAppsData.contains(where: { $0.isRunning }) { return ("含运行中应用", true) }
            if selectedAppsData.contains(where: { $0.status == "已链接" }) { return ("已链接", false) }
            return ("迁移到外部", false)
        }
        
        if validApps.count == 1 {
            return ("迁移到外部", false)
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
    
    func scanLocalApps() {
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
            
            // Update UI
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
            
            // Calculate sizes progressively using the same scanner actor
            await self.calculateSizesProgressive(for: newApps, isLocal: true, scanner: scanner)
        }
    }
    
    func scanExternalApps() {
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
             
            // Calculate sizes progressively
            await self.calculateSizesProgressive(for: newApps, isLocal: false, scanner: scanner)
        }
    }
    
    func calculateSizesProgressive(for apps: [AppItem], isLocal: Bool, scanner: AppScanner) async {
        for app in apps {
             let sizeBytes = await scanner.calculateDisplayedSize(for: app, isLocalEntry: isLocal)
             
             await MainActor.run {
                 let sizeString = LocalizedByteCountFormatter.string(fromByteCount: sizeBytes)
                 
                 if isLocal {
                     if let index = self.localApps.firstIndex(where: { $0.id == app.id }) {
                         withAnimation { 
                            self.localApps[index].size = sizeString 
                            self.localApps[index].sizeBytes = sizeBytes
                         }
                     }
                 } else {
                     if let index = self.externalApps.firstIndex(where: { $0.id == app.id }) {
                         withAnimation { 
                            self.externalApps[index].size = sizeString 
                            self.externalApps[index].sizeBytes = sizeBytes
                         }
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

    func moveAndLink(appToMove: AppItem, destinationURL: URL, progressHandler: FileCopier.ProgressHandler?) async throws {
        let service = AppMigrationService()
        try await service.moveAndLink(
            appToMove: appToMove,
            destinationURL: destinationURL,
            isRunning: isAppRunning(url: appToMove.displayURL),
            deleteSourceFallback: AppMigrationService.removeItemViaFinder(at:),
            progressHandler: progressHandler
        )
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
        
        // 读取用户设置
        let allowAppStoreMigration = UserDefaults.standard.bool(forKey: "allowAppStoreMigration")
        let allowIOSAppMigration = UserDefaults.standard.bool(forKey: "allowIOSAppMigration")
        
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
                message = "选中的应用包含 App Store 应用和非原生应用。\n\n如需迁移，请在设置中启用相应选项。"
            } else if hasIOSApps {
                message = "非原生 (iPhone/iPad) 应用不支持迁移。\n\n如需迁移，请在设置中启用「允许迁移非原生应用」选项。"
            } else {
                message = "App Store 应用不支持迁移，因为迁移后将无法通过 App Store 更新。\n\n如需强制迁移，请在设置中启用相应选项。"
            }
            
            showError(title: "无法迁移", message: message)
            return
        }
        
        guard !validApps.isEmpty else { return }
        
        // 直接迁移符合条件的应用
        executeBatchMove(apps: validApps, destination: dest)
    }
    
    /// 批量迁移应用
    func executeBatchMove(apps: [AppItem], destination: URL) {
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
                
                let destURL = destination.appendingPathComponent(app.name)
                AppLogger.shared.logContext(
                    "批量迁移单项开始",
                    details: [("batch_id", batchID), ("app_name", app.displayName), ("destination", destURL.path)],
                    level: "TRACE"
                )
                
                do {
                    try await moveAndLink(appToMove: app, destinationURL: destURL) { progress in
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
                scanLocalApps()
                scanExternalApps()
                
                if !errors.isEmpty {
                    showError(title: "部分迁移失败", message: errors.joined(separator: "\n"))
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
        
        isMigrating = true
        showProgress = true
        
        var errors: [String] = []
        
        let appsToLink = validApps.map { (app: $0, sourcePath: $0.path) }
        let batchID = AppLogger.shared.makeOperationID(prefix: "batch-link-in")
        AppLogger.shared.logContext(
            "开始批量链接应用",
            details: [
                ("batch_id", batchID),
                ("selected_count", String(validApps.count)),
                ("selected_items", joinedAppNames(validApps)),
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
                scanLocalApps()
                scanExternalApps()
                
                if !errors.isEmpty {
                    showError(title: "部分链接失败", message: errors.joined(separator: "\n"))
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
            scanLocalApps(); scanExternalApps()
        } catch {
            AppLogger.shared.logError(
                "删除本地入口失败",
                error: error,
                context: [("app_name", app.displayName)],
                relatedURLs: [("path", app.path)]
            )
            showError(title: "错误", message: error.localizedDescription)
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
                    showError(title: "错误", message: error.localizedDescription)
                }
            }
            
            await MainActor.run {
                showProgress = false
                isMigrating = false
                scanLocalApps()
                scanExternalApps()
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
                scanLocalApps()
                scanExternalApps()
                
                if !errors.isEmpty {
                    showError(title: "部分迁移失败", message: errors.joined(separator: "\n"))
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
    
    // MARK: - Monitoring Helpers
    
    func startMonitoringLocal() {
        // Stop existing if any (though usually one)
        localMonitor?.stopMonitoring()
        AppLogger.shared.logContext("启动本地目录监控", details: [("path", localAppsURL.path)])
        
        let monitor = FolderMonitor(url: localAppsURL)
        monitor.startMonitoring {
            // Debounce or just trigger?
            // Re-scan
            AppLogger.shared.logContext("检测到本地目录变化", details: [("path", self.localAppsURL.path)], level: "TRACE")
            Task { @MainActor in
                self.scanLocalApps()
            }
        }
        self.localMonitor = monitor
    }
    
    func startMonitoringExternal(url: URL) {
        externalMonitor?.stopMonitoring()
        AppLogger.shared.logContext("启动外部目录监控", details: [("path", url.path)])
        
        let monitor = FolderMonitor(url: url)
        monitor.startMonitoring {
            AppLogger.shared.logContext("检测到外部目录变化", details: [("path", url.path)], level: "TRACE")
            Task { @MainActor in
                self.scanExternalApps()
            }
        }
        self.externalMonitor = monitor
    }
    
    func stopMonitoringExternal() {
        AppLogger.shared.log("停止外部目录监控", level: "TRACE")
        externalMonitor?.stopMonitoring()
        externalMonitor = nil
    }
}
