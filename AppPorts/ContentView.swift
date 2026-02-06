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

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Toolbar
            HStack(spacing: 16) {
                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索应用 (本地 / 外部)...", text: $searchText)
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
                    Picker("排序方式", selection: $sortOption) {
                        Text("按名称").tag(SortOption.name)
                        Text("按大小").tag(SortOption.size)
                    }
                } label: {
                    Label("排序", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("排序方式")
                
                // App Store Settings Button
                Button(action: { showAppStoreSettings = true }) {
                    Label("设置", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("App Store 应用迁移设置")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            
            Divider()
            
            HSplitView {
                // --- 左侧：本地应用 ---
                VStack(spacing: 0) {
                    // Header Area (Restored to original simple style)
                    HeaderView(title: "Mac 本地应用", subtitle: "/Applications", icon: "macmini") {
                        scanLocalApps()
                    }
                    
                    ZStack {
                        Color(nsColor: .controlBackgroundColor).ignoresSafeArea()
                        
                        if filteredLocalApps.isEmpty {
                            if searchText.isEmpty {
                                EmptyStateView(icon: "magnifyingglass", text: "正在扫描...")
                            } else {
                                EmptyStateView(icon: "doc.text.magnifyingglass", text: "未找到匹配应用")
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
                        title: "外部应用库",
                        subtitle: externalDriveURL?.path ?? "未选择".localized,
                        icon: "externaldrive.fill",
                        actionButtonText: "选择文件夹",
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
                            Text("请选择外部存储路径")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            Button("选择文件夹") { openPanelForExternalDrive() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                    } else if filteredExternalApps.isEmpty {
                        EmptyStateView(icon: "folder", text: "空文件夹")
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
        }
    }
    .frame(minWidth: 900, minHeight: 600) // Increased window size
        .onAppear {
            // Restore persistence
            if let savedPath = UserDefaults.standard.string(forKey: "ExternalDrivePath") {
                let url = URL(fileURLWithPath: savedPath)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: savedPath, isDirectory: &isDir), isDir.boolValue {
                    self.externalDriveURL = url
                    AppLogger.shared.logExternalDriveInfo(at: url)
                }
            }
            
            scanLocalApps()
            
            // Start local monitoring
            startMonitoringLocal()
            
            // Check for updates
            Task {
                do {
                    if let release = try await UpdateChecker.shared.checkForUpdates() {
                        print("New version found: \(release.tagName)")
                        await MainActor.run {
                            self.alertTitle = "发现新版本"
                            self.alertMessage = "发现新版本 \(release.tagName)。\n\(release.body)" // Simplified body?
                            self.updateURL = URL(string: release.htmlUrl)
                            self.showUpdateAlert = true
                        }
                    }
                } catch {
                    print("Update check failed: \(error)")
                }
            }
        }
        .onChange(of: externalDriveURL) { newValue in
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
        
        .alert(LocalizedStringKey(alertTitle), isPresented: $showAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text(LocalizedStringKey(alertMessage))
        }
        .alert("发现新版本", isPresented: $showUpdateAlert) {
            Button("前往下载", role: .none) {
                if let url = updateURL { NSWorkspace.shared.open(url) }
            }
            Button("以后再说", role: .cancel) {}
        } message: {
            Text(alertMessage)
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
            let count = pendingAppStoreApps.filter { isAppStoreApp(at: $0.path) }.count
            let totalCount = pendingAppStoreApps.count
            if count == totalCount {
                Text("选中的 \(totalCount) 个应用均来自 App Store，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\n\n这是正常的，应用会被安全地移动到外部存储。")
            } else {
                Text("选中的 \(totalCount) 个应用包含 \(count) 个 App Store 应用，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\n\n这是正常的，应用会被安全地移动到外部存储。")
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
        let filtered = searchText.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        
        return sortApps(filtered)
    }
    
    var filteredExternalApps: [AppItem] {
        let apps = externalApps
        let filtered = searchText.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        
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
                     return $0.name < $1.name
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
                        Text(LocalizedStringKey(title))
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

                        Button(LocalizedStringKey(btnText), action: action)
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                    
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
                    .help("刷新列表")
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
                            Text(LocalizedStringKey(title))
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

                Text(LocalizedStringKey(text))
                .foregroundColor(.secondary.opacity(0.7))
            }
            .accessibilityElement(children: .combine)
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
        
        return ("迁移 \(validApps.count) 个应用", false)
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
        
        return "链接 \(validApps.count) 个应用"
    }
    
    func getRunningAppURLs() -> Set<URL> {
        let runningApps = NSWorkspace.shared.runningApplications
        let urls = runningApps.compactMap { $0.bundleURL }
        return Set(urls)
    }
    
    func scanLocalApps() {
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
            
            // Calculate sizes progressively using the same scanner actor
            await self.calculateSizesProgressive(for: newApps, isLocal: true, scanner: scanner)
        }
    }
    
    func scanExternalApps() {
        guard let dir = externalDriveURL else { self.externalApps = []; return }
        
        Task.detached(priority: .userInitiated) {
            let scanDir = dir
            let localDir = URL(fileURLWithPath: "/Applications")
            
            let scanner = AppScanner()
            let newApps = await scanner.scanExternalApps(at: scanDir, localAppsDir: localDir)
            
            await MainActor.run {
                self.externalApps = newApps
            }
             
            // Calculate sizes progressively
            await self.calculateSizesProgressive(for: newApps, isLocal: false, scanner: scanner)
        }
    }
    
    func calculateSizesProgressive(for apps: [AppItem], isLocal: Bool, scanner: AppScanner) async {
        for app in apps {
             let sizeBytes = await scanner.calculateDirectorySize(at: app.path)
             
             await MainActor.run {
                 let formatter = MeasurementFormatter()
                 formatter.unitOptions = .naturalScale
                 formatter.unitStyle = .short
                 formatter.locale = LanguageManager.shared.locale
                 
                 let measurement = Measurement(value: Double(sizeBytes), unit: UnitInformationStorage.bytes)
                 let sizeString = formatter.string(from: measurement)
                 
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
        openPanel.prompt = "选择文件夹"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        if openPanel.runModal() == .OK, let url = openPanel.urls.first {
            self.externalDriveURL = url
            // 记录外接硬盘信息
            AppLogger.shared.logExternalDriveInfo(at: url)
        }
    }
    
    func showError(title: String, message: String) {
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

    func checkApplicationsFolderWritePermission() throws {
        let testFile = localAppsURL.appendingPathComponent(".permission_check_\(UUID().uuidString)")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: testFile)
        } catch {
            throw AppMoverError.permissionDenied(error)
        }
    }
    
    /// 使用 AppleScript 调用 Finder 删除文件 (用于 App Store 应用)
    /// 使用 Process 调用 osascript，更可能触发权限请求
    func removeItemViaFinder(at url: URL) throws {
        let escapedPath = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to delete POSIX file \"\(escapedPath)\""
        
        AppLogger.shared.log("执行 AppleScript: \(script)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            if process.terminationStatus != 0 {
                AppLogger.shared.logError("osascript 退出码: \(process.terminationStatus), 错误: \(errorOutput)")
                throw NSError(domain: "AppleScript", code: Int(process.terminationStatus), 
                             userInfo: [NSLocalizedDescriptionKey: errorOutput.isEmpty ? "Finder 删除失败" : errorOutput])
            }
            
            AppLogger.shared.log("Finder 删除成功")
        } catch {
            AppLogger.shared.logError("Process 执行失败", error: error)
            throw error
        }
    }

    func moveAndLink(appToMove: AppItem, destinationURL: URL, progressHandler: FileCopier.ProgressHandler?) async throws {
        AppLogger.shared.log("===== 开始迁移应用 =====")
        AppLogger.shared.log("应用名称: \(appToMove.name)")
        AppLogger.shared.log("源路径: \(appToMove.path.path)")
        AppLogger.shared.log("目标路径: \(destinationURL.path)")
        
        try checkApplicationsFolderWritePermission()
        AppLogger.shared.log("权限检查通过")
        
        if isAppRunning(url: appToMove.path) {
            AppLogger.shared.logError("应用正在运行，无法迁移")
            throw AppMoverError.appIsRunning
        }
        
        // 1. Check destination
        if fileManager.fileExists(atPath: destinationURL.path) {
            AppLogger.shared.log("目标位置已存在文件，检查是否为符号链接")
            let existingItemResourceValues = try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if existingItemResourceValues?.isSymbolicLink == true {
                try fileManager.removeItem(at: destinationURL)
                AppLogger.shared.log("已删除目标位置的符号链接")
            } else {
                AppLogger.shared.logError("目标位置存在真实文件，无法覆盖")
                throw AppMoverError.generalError(NSError(domain: "AppMover", code: 3, userInfo: [NSLocalizedDescriptionKey: "目标已存在真实文件"]))
            }
        }
        
        // 2. Move original app to external drive (Copy with Progress + Delete with Rollback)
        do {
            // A. Copy to destination with progress tracking
            AppLogger.shared.log("步骤1: 开始复制应用到外部存储...")
            let copier = FileCopier()
            try await copier.copyDirectory(
                from: appToMove.path,
                to: destinationURL,
                progressHandler: progressHandler
            )
            AppLogger.shared.log("步骤1: 复制成功")
            
            // B. Attempt to delete source
            AppLogger.shared.log("步骤2: 尝试删除源文件 (普通方式)...")
            do {
                try fileManager.removeItem(at: appToMove.path)
                AppLogger.shared.log("步骤2: 普通删除成功")
            } catch let normalError {
                // 普通删除失败，尝试使用 Finder 删除 (适用于 App Store 应用)
                AppLogger.shared.logError("步骤2: 普通删除失败，尝试使用 Finder...", error: normalError)
                do {
                    try removeItemViaFinder(at: appToMove.path)
                    AppLogger.shared.log("步骤2: Finder 删除成功")
                } catch let finderError {
                    // !!! CRITICAL ROLLBACK !!!
                    AppLogger.shared.logError("步骤2: Finder 删除也失败，执行回滚", error: finderError)
                    try? fileManager.removeItem(at: destinationURL)
                    AppLogger.shared.log("回滚: 已删除外部存储中的副本")
                    throw AppMoverError.appStoreAppError(finderError)
                }
            }
        } catch {
             // Re-throw any error from Copy or Delete (that wasn't suppressed)
             AppLogger.shared.logError("迁移过程出错", error: error)
             throw error
        }
        
        // 3. Create Symlink Structure based on app type
        // 检测是否为 iOS 应用（使用 WrappedBundle 结构）
        let wrappedBundleURL = destinationURL.appendingPathComponent("WrappedBundle")
        let isIOSApp = fileManager.fileExists(atPath: wrappedBundleURL.path)
        
        if isIOSApp {
            // iOS 应用：使用直接符号链接（整个 .app）
            // 注意：iOS 应用无法使用深度链接策略，Finder 中会显示箭头
            AppLogger.shared.log("迁移策略: iOS 应用 (直接符号链接)", level: "STRATEGY")
            try fileManager.createSymbolicLink(at: appToMove.path, withDestinationURL: destinationURL)
            AppLogger.shared.log("已创建符号链接: \(appToMove.path.path) -> \(destinationURL.path)")
        } else {
            // Mac 原生应用：使用 Contents 深度符号链接（隐藏 Finder 箭头）
            AppLogger.shared.log("迁移策略: Mac 原生应用 (Contents 深度链接)", level: "STRATEGY")
            
            // Step A: Create the local .app directory (fake bundle)
            try fileManager.createDirectory(at: appToMove.path, withIntermediateDirectories: false, attributes: nil)
            
            // Step B: Create symlink for Contents inside the fake bundle
            let localContentsURL = appToMove.path.appendingPathComponent("Contents")
            let destinationContentsURL = destinationURL.appendingPathComponent("Contents")
            
            try fileManager.createSymbolicLink(at: localContentsURL, withDestinationURL: destinationContentsURL)
            AppLogger.shared.log("已创建 Contents 符号链接: \(localContentsURL.path) -> \(destinationContentsURL.path)")
            
            // Step C: (Optional but recommended) touch the directory to update timestamp for Launchpad
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: appToMove.path.path)
        }
    }

    func linkApp(appToLink: AppItem, destinationURL: URL) throws {
        try checkApplicationsFolderWritePermission()

        // 1. Check local destination
        if fileManager.fileExists(atPath: destinationURL.path) {
            // Check if it is a symlink (old style) or a directory (potentially new style or real app)
            let resourceValues = try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            
            if resourceValues?.isSymbolicLink == true {
                // Old style symlink, safe to remove
                try fileManager.removeItem(at: destinationURL)
            } else if resourceValues?.isDirectory == true {
                // Check if it's our deep symlink wrapper
                let contentsURL = destinationURL.appendingPathComponent("Contents")
                let contentsResourceValues = try? contentsURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                
                if contentsResourceValues?.isSymbolicLink == true {
                    // It is a deep symlink wrapper, safe to remove (recursively)
                    try fileManager.removeItem(at: destinationURL)
                } else {
                    // It's a real directory/app, abort!
                    throw AppMoverError.generalError(NSError(domain: "AppMover", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地已存在同名真实应用"]))
                }
            } else {
                throw AppMoverError.generalError(NSError(domain: "AppMover", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地已存在同名文件"]))
            }
        }
        
        // 2. Create Deep Symlink Structure
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: false, attributes: nil)
        
        let localContentsURL = destinationURL.appendingPathComponent("Contents")
        let externalContentsURL = appToLink.path.appendingPathComponent("Contents")
        
        try fileManager.createSymbolicLink(at: localContentsURL, withDestinationURL: externalContentsURL)
        
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destinationURL.path)
    }
    
    func deleteLink(app: AppItem) throws {
        try checkApplicationsFolderWritePermission()

        // Handle both old symlink and new deep symlink
        let resourceValues = try? app.path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        
        if resourceValues?.isSymbolicLink == true {
            // Old style: just remove the file
            try fileManager.removeItem(at: app.path)
        } else if resourceValues?.isDirectory == true {
            // New style: remove the whole directory wrapper
            // Double check it contains a symlinked Contents to be safe?
            // For now, assuming if status is "Link", logic allows removal.
            try fileManager.removeItem(at: app.path)
        } else {
             throw AppMoverError.generalError(NSError(domain: "AppMover", code: 5, userInfo: [NSLocalizedDescriptionKey: "尝试删除非链接文件"]))
        }
    }
    
    func moveBack(app: AppItem, localDestinationURL: URL, progressHandler: FileCopier.ProgressHandler?) async throws {
        AppLogger.shared.log("===== 开始还原应用 =====")
        AppLogger.shared.log("应用名称: \(app.name)")
        AppLogger.shared.log("源路径 (外部): \(app.path.path)")
        AppLogger.shared.log("目标路径 (本地): \(localDestinationURL.path)")
        
        try checkApplicationsFolderWritePermission()
        AppLogger.shared.log("权限检查通过")
        
        // 1. Clean up local spot
        if fileManager.fileExists(atPath: localDestinationURL.path) {
            AppLogger.shared.log("本地存在同名项目，正在清理...")
            let resourceValues = try? localDestinationURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            
            if resourceValues?.isSymbolicLink == true {
                try fileManager.removeItem(at: localDestinationURL)
                AppLogger.shared.log("已清理本地符号链接")
            } else if resourceValues?.isDirectory == true {
                 // Check for our fake bundle structure
                 let contentsURL = localDestinationURL.appendingPathComponent("Contents")
                 let contentsResourceValues = try? contentsURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                 
                 // Also check for Wrapper symlink (iOS apps)
                 let wrapperURL = localDestinationURL.appendingPathComponent("Wrapper")
                 let wrapperResourceValues = try? wrapperURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                 
                 if contentsResourceValues?.isSymbolicLink == true || wrapperResourceValues?.isSymbolicLink == true {
                     try fileManager.removeItem(at: localDestinationURL)
                     AppLogger.shared.log("已清理本地假壳/符号链接结构")
                 } else {
                     let error = NSError(domain: "AppMover", code: 6, userInfo: [NSLocalizedDescriptionKey: "本地已存在同名真实文件，无法覆盖"])
                     AppLogger.shared.logError("还原失败", error: error)
                     throw AppMoverError.generalError(error)
                 }
            } else {
                 let error = NSError(domain: "AppMover", code: 6, userInfo: [NSLocalizedDescriptionKey: "本地已存在同名文件，无法覆盖"])
                 AppLogger.shared.logError("还原失败", error: error)
                 throw AppMoverError.generalError(error)
            }
        }
        
        // 2. Copy app back with progress
        AppLogger.shared.log("步骤1: 开始复制应用回本地...")
        let startTime = Date()
        let copier = FileCopier()
        
        // 获取源文件大小用于日志
        let sourceSize = (try? fileManager.attributesOfItem(atPath: app.path.path)[.size] as? Int64) ?? 0
        
        try await copier.copyDirectory(
            from: app.path,
            to: localDestinationURL,
            progressHandler: progressHandler
        )
        let duration = Date().timeIntervalSince(startTime)
        AppLogger.shared.log("步骤1: 复制成功")
        
        // 记录性能日志
        AppLogger.shared.logMigrationPerformance(
            appName: app.name,
            size: sourceSize > 0 ? sourceSize : 0, // 这里的 size 可能不准确因为是文件夹，但作为参考
            duration: duration,
            sourcePath: app.path.path,
            destPath: localDestinationURL.path
        )
        
        // 3. Delete original from external drive
        AppLogger.shared.log("步骤2: 删除外部存储源文件...")
        do {
            try fileManager.removeItem(at: app.path)
            AppLogger.shared.log("步骤2: 删除成功")
            AppLogger.shared.log("===== 还原完成 =====")
        } catch {
            AppLogger.shared.logError("步骤2: 删除外部文件失败 (但不影响还原)", error: error)
            // 不抛出错误，因为还原已经完成
        }
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
                
                do {
                    try await moveAndLink(appToMove: app, destinationURL: destURL) { progress in
                        await MainActor.run {
                            self.progressBytes = progress.copiedBytes
                            self.progressTotalBytes = progress.totalBytes
                        }
                    }
                } catch {
                    errors.append("\(app.name): \(error.localizedDescription)")
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
        }
    }
    
    func performLinkIn() {
        // 获取所有选中且可链接的应用
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { $0.status == "未链接" || $0.status == "外部" }
        
        guard !validApps.isEmpty else { return }
        
        isMigrating = true
        progressTotal = validApps.count
        progressCurrent = 0
        showProgress = true
        
        var errors: [String] = []
        
        Task {
            for app in validApps {
                await MainActor.run {
                    progressAppName = app.name
                    progressCurrent += 1
                }
                
                let destination = localAppsURL.appendingPathComponent(app.name)
                
                do {
                    try linkApp(appToLink: app, destinationURL: destination)
                } catch {
                    errors.append("\(app.name): \(error.localizedDescription)")
                }
                
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            await MainActor.run {
                showProgress = false
                isMigrating = false
                selectedExternalApps.removeAll()
                scanLocalApps()
                
                if !errors.isEmpty {
                    showError(title: "部分链接失败", message: errors.joined(separator: "\n"))
                }
            }
        }
    }
    
    func performDeleteLink(app: AppItem) {
        do {
            try deleteLink(app: app)
            scanLocalApps(); scanExternalApps()
        } catch { showError(title: "错误", message: error.localizedDescription) }
    }
    
    
    func performMoveBack(app: AppItem) {
        isMigrating = true
        progressTotal = 1
        progressCurrent = 1
        progressAppName = app.name
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
            } catch {
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
        
        isMigrating = true
        progressTotal = validApps.count
        progressCurrent = 0
        showProgress = true
        
        var errors: [String] = []
        
        Task {
            for app in validApps {
                await MainActor.run {
                    progressAppName = app.name
                    progressCurrent += 1
                    progressBytes = 0
                    progressTotalBytes = 0
                }
                
                let destination = localAppsURL.appendingPathComponent(app.name)
                
                do {
                    try await moveBack(app: app, localDestinationURL: destination) { progress in
                        await MainActor.run {
                            self.progressBytes = progress.copiedBytes
                            self.progressTotalBytes = progress.totalBytes
                        }
                    }
                } catch {
                    errors.append("\(app.name): \(error.localizedDescription)")
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
        }
    }
    
    func getMoveBackButtonTitle() -> String {
        if selectedExternalApps.isEmpty {
            return "迁移回本地".localized
        }
        
        if selectedExternalApps.count == 1 {
            return "迁移回本地".localized
        }
        
        return "迁移 \(selectedExternalApps.count) 个应用"
    }
    
    // MARK: - Monitoring Helpers
    
    func startMonitoringLocal() {
        // Stop existing if any (though usually one)
        localMonitor?.stopMonitoring()
        
        let monitor = FolderMonitor(url: localAppsURL)
        monitor.startMonitoring {
            // Debounce or just trigger?
            // Re-scan
            print("Local folder changed, scanning...")
            Task { @MainActor in
                self.scanLocalApps()
            }
        }
        self.localMonitor = monitor
    }
    
    func startMonitoringExternal(url: URL) {
        externalMonitor?.stopMonitoring()
        
        let monitor = FolderMonitor(url: url)
        monitor.startMonitoring {
            print("External folder changed, scanning...")
            Task { @MainActor in
                self.scanExternalApps()
            }
        }
        self.externalMonitor = monitor
    }
    
    func stopMonitoringExternal() {
        externalMonitor?.stopMonitoring()
        externalMonitor = nil
    }
}
