//
//  ContentView.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI
import AppKit

// MARK: - 数据模型
struct AppItem: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var path: URL
    var status: String
    var isSystemApp: Bool = false
    var isRunning: Bool = false

    static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.status == rhs.status && lhs.isRunning == rhs.isRunning
    }
}

enum AppMoverError: LocalizedError {
    case permissionDenied(Error)
    case generalError(Error)
    case appIsRunning
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "权限不足。请前往“系统设置 > 隐私与安全性 > 完全磁盘访问权限”，允许 AppPorts 访问磁盘，然后重启应用。"
        case .generalError(let innerError):
            return innerError.localizedDescription
        case .appIsRunning:
            return "该应用正在运行。请先退出应用，然后再试。"
        }
    }
}

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
        } else if app.status == "外部" {
            return ("外部", "externaldrive", .orange)
        } else {
            return ("本地", "macmini", .secondary)
        }
    }
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: config.icon)
                .font(.system(size: 9, weight: .semibold))
            
            // 使用 LocalizedStringKey 确保状态文字能被翻译
            Text(LocalizedStringKey(config.text))
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundColor(config.color)
        .background(config.color.opacity(0.12))
        .clipShape(Capsule())
    }
}

/// 应用图标视图
struct AppIconView: View {
    let url: URL
    
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 36, height: 36)
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
    
    var body: some View {
        HStack(spacing: 12) {
            AppIconView(url: app.path)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                StatusBadge(app: app)
            }
            
            Spacer()
            
            if showDeleteLinkButton && app.status == "已链接" {
                Button(action: { onDeleteLink(app) }) {
                    Text("断开")
                        .padding(.horizontal, 2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help("断开此链接并删除文件")
            }
            
            if showMoveBackButton && app.status == "外部" {
                Button(action: { onMoveBack(app) }) {
                    Text("还原")
                        .padding(.horizontal, 2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
                .help("将应用迁移回本地")
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
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

    private let fileManager = FileManager.default

    var body: some View {
        HSplitView {
            // --- 左侧：本地应用 ---
            VStack(spacing: 0) {
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
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedLocalApp == app.id ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                            )
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 16))
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
                                .font(.system(size: 32))
                                .foregroundColor(.secondary.opacity(0.5))
                            
                            // 【修复点 2】直接使用字面量，SwiftUI 会自动翻译
                            Text("请选择外部存储路径")
                                .foregroundColor(.secondary)
                            
                            Button("选择文件夹") { openPanelForExternalDrive() }
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
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedExternalApp == app.id ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                            )
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 16))
                        }
                        .listStyle(.plain)
                    }
                }
                
                ActionFooter(title: "链接回本地", icon: "arrow.turn.up.left", isEnabled: canLinkIn, action: performLinkIn)
            }
            .frame(minWidth: 320, maxWidth: .infinity)
        }
        .frame(minWidth: 800, minHeight: 500)
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索应用名称") // prompt 也会自动翻译
        .onAppear { scanLocalApps() }
        .onChange(of: externalDriveURL) { scanExternalApps() }
        
        .alert(LocalizedStringKey(alertTitle), isPresented: $showAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text(LocalizedStringKey(alertMessage))
        }
    }
    
    // MARK: - 过滤逻辑
    
    var filteredLocalApps: [AppItem] {
        let apps = localApps
        if searchText.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var filteredExternalApps: [AppItem] {
        let apps = externalApps
        if searchText.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
                HStack {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
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
                    }
                    
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
                }
                .padding(12)
                
                Divider()
            }
            .background(.ultraThinMaterial)
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
                HStack {
                    Spacer()
                    Button(action: action) {
                        HStack {

                            Text(LocalizedStringKey(title))
                            Image(systemName: icon)
                        }
                        .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEnabled)
                    .controlSize(.regular)
                    .padding(12)
                }
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

                Text(LocalizedStringKey(text))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    // MARK: - 逻辑函数 (保持不变)
    
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
        selectedExternalApp != nil &&
        !(localApps.contains(where: { $0.name == externalApps.first(where: { $0.id == selectedExternalApp })?.name && $0.status == "本地" }))
    }
    
    func getRunningAppURLs() -> Set<URL> {
        let runningApps = NSWorkspace.shared.runningApplications
        let urls = runningApps.compactMap { $0.bundleURL }
        return Set(urls)
    }
    
    func scanLocalApps() {
        self.localApps = []
        var newApps: [AppItem] = []
        let items = (try? fileManager.contentsOfDirectory(at: localAppsURL, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles)) ?? []
        
        let runningAppURLs = getRunningAppURLs()
        
        for itemURL in items {
            if itemURL.pathExtension == "app" {
                let appName = itemURL.lastPathComponent
                var status = "本地"
                let isSystem = itemURL.path.hasPrefix("/System")
                let isRunning = runningAppURLs.contains(itemURL)
                if let resourceValues = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]), resourceValues.isSymbolicLink == true {
                    status = "已链接"
                }
                newApps.append(AppItem(name: appName, path: itemURL, status: status, isSystemApp: isSystem, isRunning: isRunning))
            }
        }
        self.localApps = self.sortApps(newApps)
    }
    
    func scanExternalApps() {
        guard let dir = externalDriveURL else { self.externalApps = []; return }
        self.externalApps = []
        var newApps: [AppItem] = []
        let items = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles)) ?? []
        for itemURL in items {
            if itemURL.pathExtension == "app" {
                let appName = itemURL.lastPathComponent
                var status = "外部"
                if let resourceValues = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]), resourceValues.isSymbolicLink == true { status = "已链接(异常)" }
                newApps.append(AppItem(name: appName, path: itemURL, status: status, isSystemApp: false, isRunning: false))
            }
        }
        self.externalApps = self.sortApps(newApps)
    }
    
    private func sortApps(_ apps: [AppItem]) -> [AppItem] {
        return apps.sorted { app1, app2 in
            let isApp1Linked = (app1.status == "已链接")
            let isApp2Linked = (app2.status == "已链接")
            if isApp1Linked && !isApp2Linked { return true }
            else if !isApp1Linked && isApp2Linked { return false }
            return app1.name < app2.name
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

    func moveAndLink(appToMove: AppItem, destinationURL: URL) throws {
        if isAppRunning(url: appToMove.path) {
            throw AppMoverError.appIsRunning
        }
        
        if fileManager.fileExists(atPath: destinationURL.path) {
            let existingItemResourceValues = try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if existingItemResourceValues?.isSymbolicLink == true { try fileManager.removeItem(at: destinationURL) }
            else { throw AppMoverError.generalError(NSError(domain: "AppMover", code: 3, userInfo: [NSLocalizedDescriptionKey: "目标已存在真实文件"])) }
        }
        try fileManager.moveItem(at: appToMove.path, to: destinationURL)
        try fileManager.createSymbolicLink(at: appToMove.path, withDestinationURL: destinationURL)
    }

    func linkApp(appToLink: AppItem, destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            let resourceValues = try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true { try fileManager.removeItem(at: destinationURL) }
            else { throw AppMoverError.generalError(NSError(domain: "AppMover", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地已存在同名真实应用"])) }
        }
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: appToLink.path)
    }
    
    func deleteLink(app: AppItem) throws { try fileManager.removeItem(at: app.path) }
    
    func moveBack(app: AppItem, localDestinationURL: URL) throws {
        if fileManager.fileExists(atPath: localDestinationURL.path) {
             let resourceValues = try? localDestinationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true { try fileManager.removeItem(at: localDestinationURL) }
            else { throw AppMoverError.generalError(NSError(domain: "AppMover", code: 6, userInfo: [NSLocalizedDescriptionKey: "本地已存在同名文件"])) }
        }
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
}
