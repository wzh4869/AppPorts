//
//  ContentView.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI
import AppKit

// NOTE: AppItem and AppMoverError are in AppModels.swift

// MARK: - UI 组件

/// 状态胶囊
struct StatusBadge: View {
    let app: AppItem
    
    var config: (text: String, icon: String, color: Color) {
        if app.status == "已链接" {
            return ("已链接", "link", .green)
        } else if app.isRunning {
            return ("运行中", "play.fill", .purple)
        } else if app.isSystemApp {
            return ("系统", "lock.fill", .gray)
        } else if app.status == "外部" { // Legacy fallback
            return ("外部", "externaldrive", .orange)
        } else if app.status == "未链接" {
            return ("未链接", "externaldrive.badge.xmark", .orange) // Or gray secondary? Orange implies attention.
        } else {
            return ("本地", "macmini", .secondary)
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: config.icon)
                .font(.system(size: 9, weight: .bold))
            
            Text(LocalizedStringKey(config.text))
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(config.color)
        .background(config.color.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(config.color.opacity(0.2), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizedStringKey(config.text))
        .accessibilityAddTraits(.isStaticText)
    }
}

/// 应用图标视图 - 异步加载优化
struct AppIconView: View {
    let url: URL
    @State private var icon: NSImage? = nil
    
    var body: some View {
        Group {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Placeholder while loading
                Color.clear
            }
        }
        .frame(width: 40, height: 40)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        .accessibilityHidden(true)
        .task {
            // Async icon loading
            if icon == nil {
                let loadedIcon = await Task.detached(priority: .userInitiated) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }.value
                await MainActor.run { self.icon = loadedIcon }
            }
        }
    }
}

/// 列表行视图
struct AppRowView: View {
    let app: AppItem
    let isSelected: Bool
    let showDeleteLinkButton: Bool
    let showMoveBackButton: Bool
    let onDeleteLink: (AppItem) -> Void
    let onMoveBack: (AppItem) -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 14) {
            AppIconView(url: app.path)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                HStack(spacing: 8) {
                    StatusBadge(app: app)
                    
                    if let size = app.size {
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    } else {
                        Text("计算中...")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                            .transition(.opacity)
                    }
                }
            }
            
            Spacer()
            
            if showDeleteLinkButton && app.status == "已链接" {
                Button(action: { onDeleteLink(app) }) {
                    Image(systemName: "link.badge.plus") // Icon only for cleaner look
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain) // Cleaner button style
                .padding(6)
                .background(Color.red.opacity(0.1))
                .clipShape(Circle())
                .help("断开此链接并删除文件")
            }
            
            if showMoveBackButton {
                Button(action: { onMoveBack(app) }) {
                    Image(systemName: "arrow.uturn.backward")
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color.blue.opacity(0.1))
                .clipShape(Circle())
                .help("将应用迁移回本地")
            }
        }
        .padding(.vertical, 10) // Increased vertical padding
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isHovered = hovering
            }
        }
        // Accessibility: Combine row into single element
        .accessibilityElement(children: .combine)
        // Custom Actions for VoiceOver (Swipe up/down)
        .accessibilityActions {
             if showDeleteLinkButton && app.status == "已链接" {
                 Button(action: { onDeleteLink(app) }) {
                     Text("断开") // "Disconnect"
                 }
             }
             
             if showMoveBackButton {
                 Button(action: { onMoveBack(app) }) {
                     Text("还原") // "Restore"
                 }
             }
             
             Button(action: {
                 NSWorkspace.shared.activateFileViewerSelecting([app.path])
             }) {
                 Text("在 Finder 中显示")
             }
        }
        .contextMenu {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([app.path])
            }
        }
    }
}

// MARK: - 主视图
struct ContentView: View {

    @State private var localApps: [AppItem] = []
    @State private var externalApps: [AppItem] = []
    
    @State private var searchText: String = ""
    
    private let localAppsURL = URL(fileURLWithPath: "/Applications")
    @State private var externalDriveURL: URL?

    @State private var selectedLocalApp: UUID?
    @State private var selectedExternalApp: UUID?
    
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    @State private var showUpdateAlert = false
    @State private var updateURL: URL?

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
                            List(filteredLocalApps, selection: $selectedLocalApp) { app in
                                AppRowView(
                                    app: app,
                                    isSelected: app.id == selectedLocalApp,
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
                        List(filteredExternalApps, selection: $selectedExternalApp) { app in
                            AppRowView(
                                app: app,
                                isSelected: app.id == selectedExternalApp,
                                showDeleteLinkButton: false,
                                showMoveBackButton: true,
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
                
                ActionFooter(title: "链接回本地", icon: "arrow.turn.up.left", isEnabled: canLinkIn, action: performLinkIn)
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
        guard let selectedId = selectedLocalApp,
              let app = localApps.first(where: { $0.id == selectedId }) else {
            return ("迁移到外部", false)
        }
        
        if app.isSystemApp { return ("系统应用", true) }
        if app.isRunning { return ("应用运行中", true) }
        if app.status == "已链接" { return ("已链接", false) }
        
        return ("迁移到外部", false)
    }
    
    var canMoveOut: Bool {
        guard let selectedId = selectedLocalApp,
              let app = localApps.first(where: { $0.id == selectedId }) else { return false }
        if app.isSystemApp || app.isRunning { return false }
        return externalDriveURL != nil && app.status != "已链接"
    }
    
    var canLinkIn: Bool {
        guard let selectedId = selectedExternalApp,
              let app = externalApps.first(where: { $0.id == selectedId }) else { return false }
        
        // Only allow linking if it is NOT already linked
        return app.status == "未链接" || app.status == "外部"
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
        if openPanel.runModal() == .OK { self.externalDriveURL = openPanel.urls.first }
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

    func checkApplicationsFolderWritePermission() throws {
        let testFile = localAppsURL.appendingPathComponent(".permission_check_\(UUID().uuidString)")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: testFile)
        } catch {
            throw AppMoverError.permissionDenied(error)
        }
    }

    func moveAndLink(appToMove: AppItem, destinationURL: URL) throws {
        try checkApplicationsFolderWritePermission()
        
        if isAppRunning(url: appToMove.path) {
            throw AppMoverError.appIsRunning
        }
        
        // 1. Check destination
        if fileManager.fileExists(atPath: destinationURL.path) {
            let existingItemResourceValues = try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if existingItemResourceValues?.isSymbolicLink == true { try fileManager.removeItem(at: destinationURL) }
            else { throw AppMoverError.generalError(NSError(domain: "AppMover", code: 3, userInfo: [NSLocalizedDescriptionKey: "目标已存在真实文件"])) }
        }
        
        // 2. Move original app to external drive (Atomic Copy + Delete with Rollback)
        do {
            // A. Copy to destination
            try fileManager.copyItem(at: appToMove.path, to: destinationURL)
            
            // B. Attempt to delete source
            do {
                try fileManager.removeItem(at: appToMove.path)
            } catch {
                // !!! CRITICAL ROLLBACK !!!
                // If deleting source fails (e.g. Permission Denied mid-operation),
                // we MUST delete the copied file on external drive to restore state.
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
        } catch {
             // Re-throw any error from Copy or Delete (that wasn't suppressed)
             throw error
        }
        
        // 3. Create Deep Symlink Structure
        // Step A: Create the local .app directory (fake bundle)
        try fileManager.createDirectory(at: appToMove.path, withIntermediateDirectories: false, attributes: nil)
        
        // Step B: Create symlink for Contents inside the fake bundle
        let localContentsURL = appToMove.path.appendingPathComponent("Contents")
        let destinationContentsURL = destinationURL.appendingPathComponent("Contents")
        
        try fileManager.createSymbolicLink(at: localContentsURL, withDestinationURL: destinationContentsURL)
        
        // Step C: (Optional but recommended) touch the directory to update timestamp for Launchpad
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: appToMove.path.path)
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
    
    func moveBack(app: AppItem, localDestinationURL: URL) throws {
        try checkApplicationsFolderWritePermission()
        
        // 1. Clean up local spot
        if fileManager.fileExists(atPath: localDestinationURL.path) {
             let resourceValues = try? localDestinationURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            
            if resourceValues?.isSymbolicLink == true {
                try fileManager.removeItem(at: localDestinationURL)
            } else if resourceValues?.isDirectory == true {
                 let contentsURL = localDestinationURL.appendingPathComponent("Contents")
                 let contentsResourceValues = try? contentsURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                 if contentsResourceValues?.isSymbolicLink == true {
                     try fileManager.removeItem(at: localDestinationURL)
                 } else {
                     throw AppMoverError.generalError(NSError(domain: "AppMover", code: 6, userInfo: [NSLocalizedDescriptionKey: "本地已存在同名真实文件"]))
                 }
            } else {
                 throw AppMoverError.generalError(NSError(domain: "AppMover", code: 6, userInfo: [NSLocalizedDescriptionKey: "本地已存在同名文件"]))
            }
        }
        
        // 2. Move app back
        try fileManager.moveItem(at: app.path, to: localDestinationURL)
    }
    
    func performMoveOut() {
        guard let selectedId = selectedLocalApp, let app = localApps.first(where: { $0.id == selectedId }), let dest = externalDriveURL else { return }
        let destination = dest.appendingPathComponent(app.name)
        do {
            try moveAndLink(appToMove: app, destinationURL: destination)
            scanLocalApps(); scanExternalApps()
        } catch { showError(title: "错误", message: error.localizedDescription) }
    }
    
    func performLinkIn() {
        guard let selectedId = selectedExternalApp, let app = externalApps.first(where: { $0.id == selectedId }) else { return }
        let destination = localAppsURL.appendingPathComponent(app.name)
        do {
            try linkApp(appToLink: app, destinationURL: destination)
            scanLocalApps()
        } catch { showError(title: "错误", message: error.localizedDescription) }
    }
    
    func performDeleteLink(app: AppItem) {
        do {
            try deleteLink(app: app)
            scanLocalApps(); scanExternalApps()
        } catch { showError(title: "错误", message: error.localizedDescription) }
    }
    
    
    func performMoveBack(app: AppItem) {
        let destination = localAppsURL.appendingPathComponent(app.name)
        do {
            try moveBack(app: app, localDestinationURL: destination)
            scanLocalApps(); scanExternalApps()
        } catch { showError(title: "错误", message: error.localizedDescription) }
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
