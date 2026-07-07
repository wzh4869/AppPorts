//
//  DataDirsView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/3/4.
//

import SwiftUI

// MARK: - 数据目录分组

/// 按数据类型分组的目录集合
struct DataDirGroup {
    let type: DataDirType
    let items: [DataDirItem]
    /// 分组总大小——只统计根级项，避免父目录大小与子目录大小重复计入。
    /// 子目录项的 sizeBytes 已包含在父目录的 calculateDirectorySize 中。
    var totalSizeBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }
}

// MARK: - 数据目录主视图

/// 数据目录管理视图（主界面 Tab 三）
///
/// 展示两类数据目录：
/// - 已知工具 dotFolder（~/.npm、~/.m2 等）
/// - 本地应用在 ~/Library/ 下的关联数据（需用户选择应用）
struct DataDirsView: View {
    @ObservedObject private var languageManager = LanguageManager.shared

    // MARK: - 外部依赖
    /// 外部存储路径（共用 ContentView 中的选择）
    let externalDriveURL: URL?
    /// 本地已扫描的应用列表（供用户选择查关联目录用）
    let localApps: [AppItem]
    /// 当前数据目录子页面，由 ContentView 顶部工具栏统一控制
    @Binding var selectedTab: DataTab
    /// 当前选中的应用数据来源应用，由 ContentView 顶部工具栏读取重签名状态。
    @Binding var selectedApp: AppItem?
    /// 当前扫描状态，由 ContentView 顶部刷新按钮读取。
    @Binding var isScanning: Bool
    /// 数据迁移完成后自动重签名开关，由 ContentView 顶部工具栏控制。
    @Binding var autoResignEnabled: Bool
    /// 父级工具栏触发刷新时递增。
    let refreshTrigger: Int
    /// 选择外部存储路径的回调
    let onSelectExternalDrive: () -> Void
    /// 数据迁移完成后对关联应用执行重签名的回调（Bool = 是否静默，true 则不弹错误框）
    let onResignApp: ((AppItem, Bool) -> Void)?
    /// 恢复应用原始签名的回调
    let onRestoreSignature: ((AppItem) -> Void)?
    /// 迁移前备份原始签名的回调
    let onBackupSignature: ((AppItem) -> Void)?
    /// 解析应用真实路径（已链接→外部，未链接→本地），不返回假壳路径
    let resolveRealAppURL: ((AppItem) -> URL)?
    /// 对指定 URL 重签名（autoResignEnabled 专用，签真实应用）
    let onResignAppAtURL: ((URL, Bool) -> Void)?
    /// 对指定 URL 备份签名（autoResignEnabled 专用）
    let onBackupSignatureForURL: ((URL) -> Void)?

    // MARK: - 内部状态
    @State private var dotFolderItems: [DataDirItem] = []
    @State private var libraryItems:   [DataDirItem] = []

    @State private var showAppDataFilters = false
    @State private var selectedPriorityFilters: Set<DataDirPriority> = []
    @State private var selectedStatusFilters: Set<String> = []
    @State private var selectedTypeFilters: Set<DataDirType> = []
    @State private var selectedAppDataSortMode: AppDataSortMode = .defaultOrder
    @State private var selectedAppSortMode: AppSortMode = .size

    // 进度弹窗
    @State private var showProgress = false
    @State private var progressBytes: Int64 = 0
    @State private var progressTotalBytes: Int64 = 0
    @State private var progressFileName = ""
    @State private var progressTitle = ""

    // 确认弹窗
    @State private var showConfirm = false
    @State private var confirmTitle = ""
    @State private var confirmMessage = ""
    @State private var confirmActionTitle = "继续".localized
    @State private var confirmAction: (() -> Void)? = nil
    @State private var showAppDataMigrationRiskConfirm = false
    @State private var pendingMigrationItem: DataDirItem? = nil
    @State private var pendingMigrationDestinationPath: URL? = nil
    @State private var pendingMigrationShouldResign: Bool? = nil
    @State private var pendingMigrationApp: AppItem? = nil
    @State private var showContainerDataResignConfirm = false
    @State private var containerDataResignMessage = ""
    @State private var showManagedLinkNormalizationConfirm = false
    @State private var managedLinkNormalizationMessage = ""
    @State private var managedLinkNormalizationItem: DataDirItem? = nil
    @State private var managedLinkNormalizationCurrentTarget: URL? = nil
    @State private var showMigrationRiskAlert = false
    @State private var migrationRiskMessage = ""

    // 错误弹窗
    @State private var showError = false
    @State private var errorMessage = ""

    // 权限弹窗
    @State private var showPermissionAlert = false
    @AppStorage("skipPermissionCheck") private var skipPermissionCheck = false

    // 选中项（用于高亮）
    @State private var selectedItemID: String? = nil
    @State private var dotFolderScanToken = UUID()
    @State private var libraryScanToken = UUID()

    // 搜索
    @State private var appSearchText = ""

    enum DataTab: String, CaseIterable {
        case toolDirs  = "工具目录"
        case appDirs   = "应用数据"
    }

    enum AppDataSortMode: String, CaseIterable {
        case defaultOrder = "默认"
        case size = "按大小"
        case alphabetical = "按首字母"

        var localizedTitle: String {
            switch self {
            case .defaultOrder:
                return "默认".localized
            case .size:
                return "按大小".localized
            case .alphabetical:
                return "按首字母".localized
            }
        }
    }

    enum AppSortMode: String, CaseIterable {
        case size = "按大小"
        case alphabetical = "按首字母"

        var localizedTitle: String {
            switch self {
            case .size:
                return "按大小".localized
            case .alphabetical:
                return "按首字母".localized
            }
        }
    }

    private let appDataStatusOrder = ["本地", "已链接", "待规范", "现有软链", "待接回", "未找到"]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── 主内容区 ────────────────────────────────────────
            if selectedTab == .toolDirs {
                toolDirsContent
            } else {
                appDirsContent
            }
        }
        .onAppear {
            reloadCurrentTab()
        }
        .onChange(of: selectedTab) { _ in
            reloadCurrentTab()
        }
        .onChange(of: refreshTrigger) { _ in
            reloadCurrentTab()
        }
        .onChange(of: externalDriveURL) { _ in
            reloadCurrentTab()
        }
        .onChange(of: languageManager.language) { _ in
            reloadCurrentTab()
        }
        // 确认弹窗
        .alert(LocalizedStringKey(confirmTitle), isPresented: $showConfirm) {
            Button(confirmActionTitle, role: .none) { confirmAction?() }
            Button("取消".localized, role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert("迁移前请先备份".localized, isPresented: $showAppDataMigrationRiskConfirm) {
            Button("继续".localized, role: .none) {
                continuePendingMigrationFlow()
            }
            Button("取消".localized, role: .cancel) {
                clearPendingMigrationConfirmation()
            }
        } message: {
            Text(
                "迁移应用数据可能导致目标软件出现不可预料的兼容性问题。建议你先自行备份当前数据，再在副本或可接受风险的环境中迁移并测试，确认软件工作正常后再继续长期使用。".localized
            )
        }
        .alert("确认规范化管理".localized, isPresented: $showManagedLinkNormalizationConfirm) {
            Button("确认".localized, role: .none) {
                if let item = managedLinkNormalizationItem,
                   let target = managedLinkNormalizationCurrentTarget {
                    performManageExistingLink(item, target: target)
                }
                clearManagedLinkNormalizationState()
            }
            Button("取消".localized, role: .cancel) {
                clearManagedLinkNormalizationState()
            }
        } message: {
            Text(managedLinkNormalizationMessage)
        }
        .alert("迁移风险提示".localized, isPresented: $showMigrationRiskAlert) {
            Button("继续".localized, role: .none) {
                continuePendingMigrationFlow()
            }
            Button("取消".localized, role: .cancel) {
                clearPendingMigrationConfirmation()
            }
        } message: {
            Text(migrationRiskMessage)
        }
        .alert("data_dir_resign_alert_title".localized, isPresented: $showContainerDataResignConfirm) {
            Button("data_dir_resign_alert_accept".localized, role: .none) {
                pendingMigrationShouldResign = true
                presentPendingMigrationConfirmation()
            }
            Button("data_dir_resign_alert_decline".localized, role: .none) {
                pendingMigrationShouldResign = false
                presentPendingMigrationConfirmation()
            }
            Button("取消".localized, role: .cancel) {
                clearPendingMigrationConfirmation()
            }
        } message: {
            Text(containerDataResignMessage)
        }
        // 错误弹窗
        .alert("操作失败".localized, isPresented: $showError) {
            Button("好的".localized, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("需要 App 管理权限".localized, isPresented: $showPermissionAlert) {
            Button("打开系统设置".localized) {
                openAppManagementSettings()
            }
            Button("稍后".localized, role: .cancel) {
                skipPermissionCheck = true
            }
        } message: {
            Text("AppPorts 需要「App 管理」权限才能迁移应用数据。请在系统设置中勾选 AppPorts，然后重启应用。".localized)
        }
        // 进度覆盖层
        .overlay {
            if showProgress {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    DataDirProgressOverlay(
                        title: progressTitle,
                        copiedBytes: progressBytes,
                        totalBytes: progressTotalBytes,
                        currentFile: progressFileName
                    )
                }
            }
        }
    }

    // MARK: - 工具目录 Tab

    private var toolDirsContent: some View {
        VStack(spacing: 0) {
            // 外部存储路径提示区
            if externalDriveURL == nil {
                externalDriveWarning
            }

            // 统计栏
            if !dotFolderItems.isEmpty {
                statsBar(items: dotFolderItems)
            }

            // 列表
            ZStack {
                Color(nsColor: .controlBackgroundColor).ignoresSafeArea()

                if isScanning && dotFolderItems.isEmpty {
                    loadingView
                } else if dotFolderItems.isEmpty {
                    ContentView.EmptyStateView(icon: "folder.badge.questionmark", text: "未发现已知工具目录".localized)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(dotFolderItems) { item in
                                DataDirRowView(
                                    item: item,
                                    isSelected: selectedItemID == item.id,
                                    onMigrate: { askMigrate($0) },
                                    onRestore: { askRestore($0) },
                                    onManageExistingLink: { askManageExistingLink($0) },
                                    onNormalizeManagedLink: { askNormalizeManagedLink($0) },
                                    onRelinkExternalData: { askRelinkExternalData($0) }
                                )
                                .onTapGesture { selectedItemID = item.id }
                                .padding(.horizontal, 10)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    // MARK: - 应用数据 Tab

    private var appDirsContent: some View {
        HSplitView {
            // 左侧：应用选择列表
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    TextField("搜索应用...".localized, text: $appSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !appSearchText.isEmpty {
                        Button(action: { appSearchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if !localApps.isEmpty {
                        let count = localApps.filter { !$0.isFolder }.count
                        Text("\(count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                Divider()

                if localApps.isEmpty {
                    ContentView.EmptyStateView(icon: "app.dashed", text: "无本地应用".localized)
                } else {
                    let filteredApps = localApps.filter { app in
                        !app.isFolder && (appSearchText.isEmpty || app.displayName.localizedCaseInsensitiveContains(appSearchText) || app.name.localizedCaseInsensitiveContains(appSearchText))
                    }
                    let sortedApps: [AppItem] = {
                        switch selectedAppSortMode {
                        case .size:
                            return filteredApps.sorted { lhs, rhs in
                                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                            }
                        case .alphabetical:
                            return filteredApps.sorted {
                                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                            }
                        }
                    }()

                    // 排序切换按钮
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(AppSortMode.allCases, id: \.self) { mode in
                                Button(action: { selectedAppSortMode = mode }) {
                                    HStack {
                                        Text(mode.localizedTitle)
                                        Spacer()
                                        if selectedAppSortMode == mode {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 10))
                                Text(selectedAppSortMode.localizedTitle)
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(sortedApps, id: \.id) { app in
                                AppListRow(app: app, isSelected: selectedApp?.id == app.id)
                                    .onTapGesture { selectedApp = app }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                }
            }
            .frame(minWidth: 200, maxWidth: 280)
            .onChange(of: selectedApp) { newApp in
                if let app = newApp { scanLibraryDirs(for: app) }
                else {
                    libraryScanToken = UUID()
                    libraryItems = []
                    isScanning = false
                }
            }
            .onChange(of: localApps) { newApps in
                // 重签名/迁移后刷新 selectedApp，避免持有旧的 isResigned 等字段
                // 用 path 匹配而非 id（id 每次扫描都是新 UUID）
                if let selected = selectedApp,
                   let refreshed = newApps.first(where: { $0.path == selected.path }) {
                    selectedApp = refreshed
                }
            }

            // 右侧：关联数据目录
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        if let app = selectedApp {
                            Text(String(format: "%@ 的数据目录".localized, app.name.replacingOccurrences(of: ".app", with: "")))
                        } else {
                            Text("请从左侧选择应用".localized)
                        }
                        Spacer()
                        if selectedApp != nil {
                            appDataSortMenu
                            appDataFilterButton
                        }
                    }

                    if selectedApp != nil && (!libraryItems.isEmpty || hasActiveAppDataFilters) {
                        appDataFilterSummary
                    }
                }
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                Divider()

                // 外部存储路径提示
                if externalDriveURL == nil { externalDriveWarning }

                // 统计栏
                if !libraryItems.isEmpty {
                    statsBar(items: filteredLibraryItems)
                }

                ZStack {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

                    if selectedApp == nil {
                        ContentView.EmptyStateView(icon: "arrow.left.circle", text: "从左侧选择一个应用".localized)
                    } else if isScanning && libraryItems.isEmpty {
                        loadingView
                    } else if libraryItems.isEmpty {
                        ContentView.EmptyStateView(icon: "folder.badge.questionmark", text: "未找到关联数据目录".localized)
                    } else if sortedFilteredLibraryItems.isEmpty {
                        ContentView.EmptyStateView(icon: "line.3.horizontal.decrease.circle", text: "没有匹配当前筛选条件的数据目录".localized)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(groupedLibraryItems, id: \.type) { group in
                                    DataDirGroupCard(
                                        group: group,
                                        selectedItemID: selectedItemID,
                                        onSelect: { selectedItemID = $0 },
                                        onMigrate: askMigrate,
                                        onRestore: askRestore,
                                        onManageExistingLink: askManageExistingLink,
                                        onNormalizeManagedLink: askNormalizeManagedLink,
                                        onRelinkExternalData: askRelinkExternalData
                                    )
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity)
        }
    }

    // MARK: - 辅助子视图

    private var externalDriveWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundColor(.orange)
            Text("请先在「应用」页面选择外部存储路径".localized)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button("去选择".localized, action: onSelectExternalDrive)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundColor(.orange.opacity(0.2)), alignment: .bottom)
    }

    private var appDataFilterButton: some View {
        Button(action: { showAppDataFilters.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: hasActiveAppDataFilters
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                Text("筛选".localized)
                if hasActiveAppDataFilters {
                    Text("\(activeAppDataFilterCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $showAppDataFilters, arrowEdge: .top) {
            appDataFilterPopover
        }
    }

    private var appDataSortMenu: some View {
        Menu {
            ForEach(AppDataSortMode.allCases, id: \.self) { mode in
                Button(action: { selectedAppDataSortMode = mode }) {
                    HStack {
                        Text(mode.localizedTitle)
                        Spacer()
                        if selectedAppDataSortMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down.circle")
                Text(selectedAppDataSortMode.localizedTitle)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var appDataFilterSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(String(format: "显示 %lld / %lld".localized, Int64(sortedFilteredLibraryItems.count), Int64(libraryItems.count)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                Text(String(format: "排序：%@".localized, selectedAppDataSortMode.localizedTitle))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if hasActiveAppDataFilters {
                    Button("清除筛选".localized, action: clearAppDataFilters)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }

                Spacer()
            }

            if hasActiveAppDataFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activeAppDataFilterLabels, id: \.self) { label in
                            Text(label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    private var appDataFilterPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("筛选应用数据".localized)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if hasActiveAppDataFilters {
                    Button("清除筛选".localized, action: clearAppDataFilters)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("迁移建议".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(DataDirPriority.allCases, id: \.self) { priority in
                    Toggle(priority.localizedTitle, isOn: priorityFilterBinding(priority))
                        .toggleStyle(.checkbox)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("链接状态".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(appDataStatusOrder, id: \.self) { status in
                    Toggle(DataDirStatus.localized(status), isOn: statusFilterBinding(status))
                        .toggleStyle(.checkbox)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("数据类型".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(appDataFilterTypes, id: \.self) { type in
                    Toggle(type.localizedTitle, isOn: typeFilterBinding(type))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func statsBar(items: [DataDirItem]) -> some View {
        // 只统计根级项大小，避免父目录大小与子目录大小重复计入
        let standardizedPaths = items.map { $0.path.standardizedFileURL.path }
        let rootItems = items.filter { item in
            let path = item.path.standardizedFileURL.path
            return !standardizedPaths.contains { $0 != path && path.hasPrefix($0 + "/") }
        }
        let total = rootItems.filter { $0.status == "本地" }.reduce(0) { $0 + $1.sizeBytes }
        let linked = items.filter { $0.status == "已链接" }.count
        let needsNormalization = items.filter { $0.status == "待规范" }.count
        let existingSymlinks = items.filter { $0.status == "现有软链" }.count
        let relinkable = items.filter { $0.status == "待接回" }.count
        return HStack(spacing: 20) {
            Label(String(format: "%lld 个目录".localized, Int64(items.count)), systemImage: "folder.fill")
                .foregroundColor(.secondary)
            if total > 0 {
                Label(
                    LocalizedByteCountFormatter.string(fromByteCount: total, allowedUnits: [.mb, .gb]) + " 可释放".localized,
                    systemImage: "sparkles"
                )
                    .foregroundColor(.accentColor)
            }
            if linked > 0 {
                Label(String(format: "%lld 个已链接".localized, Int64(linked)), systemImage: "link.circle.fill")
                    .foregroundColor(.green)
            }
            if needsNormalization > 0 {
                Label(String(format: "%lld 个待整理".localized, Int64(needsNormalization)), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.mint)
            }
            if existingSymlinks > 0 {
                Label(String(format: "%lld 个现有软链".localized, Int64(existingSymlinks)), systemImage: "link.badge.questionmark")
                    .foregroundColor(.teal)
            }
            if relinkable > 0 {
                Label(String(format: "%lld 个待接回".localized, Int64(relinkable)), systemImage: "arrow.triangle.branch")
                    .foregroundColor(.indigo)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.primary.opacity(0.05)), alignment: .bottom)
    }

    /// 递归渲染树形数据目录项
    private func treeItemView(item: DataDirItem, level: Int) -> TreeItemView {
        TreeItemView(
            item: item,
            level: level,
            isSelected: selectedItemID == item.id,
            onSelect: { selectedItemID = $0 },
            onMigrate: askMigrate,
            onRestore: askRestore,
            onManageExistingLink: askManageExistingLink,
            onNormalizeManagedLink: askNormalizeManagedLink,
            onRelinkExternalData: askRelinkExternalData
        )
    }

    private var filteredLibraryItems: [DataDirItem] {
        libraryItems.filter(matchesAppDataFilters)
    }

    /// 链接状态优先级：已链接、待规范、现有软链优先展示
    private let statusPriority: [String] = ["已链接", "待规范", "现有软链", "待接回", "本地", "未找到"]

    private func statusSortKey(_ status: String) -> Int {
        statusPriority.firstIndex(of: status) ?? statusPriority.count
    }

    private var sortedFilteredLibraryItems: [DataDirItem] {
        switch selectedAppDataSortMode {
        case .defaultOrder:
            // 已迁移路径在前，然后按大小降序
            return filteredLibraryItems.sorted { lhs, rhs in
                let lhsKey = statusSortKey(lhs.status)
                let rhsKey = statusSortKey(rhs.status)
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .size:
            return filteredLibraryItems.sorted { lhs, rhs in
                if lhs.sizeBytes != rhs.sizeBytes {
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .alphabetical:
            return filteredLibraryItems.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private var groupedLibraryItems: [DataDirGroup] {
        let sorted = sortedFilteredLibraryItems
        var groups: [DataDirType: [DataDirItem]] = [:]
        for item in sorted {
            groups[item.type, default: []].append(item)
        }
        let typeOrder = DataDirType.allCases
        return typeOrder.compactMap { type in
            guard let items = groups[type], !items.isEmpty else { return nil }
            return DataDirGroup(type: type, items: buildTree(from: items))
        }
    }

    /// 将扁平列表构建成树形结构。
    ///
    /// 路径被另一个项路径包含的条目会被嵌套为子节点。
    private func buildTree(from items: [DataDirItem]) -> [DataDirItem] {
        // 按路径深度排序：确保父节点（短路径）在子节点（长路径）之前处理，
        // 否则子节点会同时作为顶层节点和父节点的子节点出现，造成重复条目。
        let sorted = items.sorted { lhs, rhs in
            lhs.path.standardizedFileURL.pathComponents.count < rhs.path.standardizedFileURL.pathComponents.count
        }
        var result: [DataDirItem] = []
        var nestedIDs: Set<String> = []

        for var parent in sorted {
            guard !nestedIDs.contains(parent.id) else { continue }

            let parentPath = parent.path.standardizedFileURL.path
            var directChildren: [DataDirItem] = []

            for child in items where child.id != parent.id && !nestedIDs.contains(child.id) {
                let childPath = child.path.standardizedFileURL.path
                if childPath.hasPrefix(parentPath + "/") {
                    directChildren.append(child)
                    nestedIDs.insert(child.id)
                }
            }

            if !directChildren.isEmpty {
                parent.children = buildTree(from: directChildren)
            }

            result.append(parent)
        }

        return result
    }

    private var hasActiveAppDataFilters: Bool {
        !selectedPriorityFilters.isEmpty || !selectedStatusFilters.isEmpty || !selectedTypeFilters.isEmpty
    }

    private var activeAppDataFilterCount: Int {
        selectedPriorityFilters.count + selectedStatusFilters.count + selectedTypeFilters.count
    }

    private var activeAppDataFilterLabels: [String] {
        var labels: [String] = []
        labels.append(contentsOf: DataDirPriority.allCases.filter(selectedPriorityFilters.contains).map(\.localizedTitle))
        labels.append(contentsOf: appDataStatusOrder.filter(selectedStatusFilters.contains).map { $0.localized })
        labels.append(contentsOf: appDataFilterTypes.filter(selectedTypeFilters.contains).map(\.localizedTitle))
        return labels
    }

    private var appDataFilterTypes: [DataDirType] {
        DataDirType.allCases.filter { $0 != .dotFolder }
    }

    private func matchesAppDataFilters(_ item: DataDirItem) -> Bool {
        (selectedPriorityFilters.isEmpty || selectedPriorityFilters.contains(item.priority))
            && (selectedStatusFilters.isEmpty || selectedStatusFilters.contains(item.status))
            && (selectedTypeFilters.isEmpty || selectedTypeFilters.contains(item.type))
    }

    private func clearAppDataFilters() {
        selectedPriorityFilters.removeAll()
        selectedStatusFilters.removeAll()
        selectedTypeFilters.removeAll()
    }

    private func priorityFilterBinding(_ priority: DataDirPriority) -> Binding<Bool> {
        Binding(
            get: { selectedPriorityFilters.contains(priority) },
            set: { isSelected in
                if isSelected {
                    selectedPriorityFilters.insert(priority)
                } else {
                    selectedPriorityFilters.remove(priority)
                }
            }
        )
    }

    private func statusFilterBinding(_ status: String) -> Binding<Bool> {
        Binding(
            get: { selectedStatusFilters.contains(status) },
            set: { isSelected in
                if isSelected {
                    selectedStatusFilters.insert(status)
                } else {
                    selectedStatusFilters.remove(status)
                }
            }
        )
    }

    private func typeFilterBinding(_ type: DataDirType) -> Binding<Bool> {
        Binding(
            get: { selectedTypeFilters.contains(type) },
            set: { isSelected in
                if isSelected {
                    selectedTypeFilters.insert(type)
                } else {
                    selectedTypeFilters.remove(type)
                }
            }
        )
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("扫描中...".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 扫描逻辑

    private func reloadCurrentTab() {
        AppLogger.shared.logContext(
            "刷新数据目录当前标签",
            details: [
                ("selected_tab", selectedTab == .toolDirs ? "toolDirs" : "appData"),
                ("selected_app", selectedApp?.displayName)
            ],
            level: "TRACE"
        )
        if selectedTab == .toolDirs {
            scanDotFolders()
        } else {
            dotFolderScanToken = UUID()
            if let app = selectedApp {
                scanLibraryDirs(for: app)
            }
        }
    }

    private func scanDotFolders() {
        let scanToken = UUID()
        dotFolderScanToken = scanToken
        isScanning = true
        let selectedExternalRoot = externalDriveURL
        let scanID = AppLogger.shared.makeOperationID(prefix: "scan-dot-folders")
        AppLogger.shared.logContext(
            "开始扫描工具目录",
            details: [
                ("scan_id", scanID),
                ("external_root", selectedExternalRoot?.path)
            ]
        )
        Task.detached(priority: .userInitiated) {
            let scanner = DataDirScanner()
            let items = await scanner.scanKnownDotFolders(externalRootURL: selectedExternalRoot)
            let initialItems = items

            await MainActor.run {
                guard self.dotFolderScanToken == scanToken else { return }
                self.dotFolderItems = initialItems
                self.isScanning = false
            }
            AppLogger.shared.logContext(
                "工具目录扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("count", String(items.count)),
                    ("statuses", Dictionary(grouping: items, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
                ]
            )

            // 并行计算所有目录大小（TaskGroup，非 actor 隔离的 fastDirectorySize）
            let sizedItems = await withTaskGroup(of: (Int, Int64).self) { group in
                var results: [(Int, Int64)] = []
                var iterator = items.indices.makeIterator()
                var active = 0
                let maxConcurrency = 4

                // 启动初始批次
                for _ in 0..<min(maxConcurrency, items.count) {
                    guard let i = iterator.next() else { break }
                    let scanURL = items[i].linkedDestination ?? items[i].path
                    group.addTask { (i, fastDirectorySize(at: scanURL)) }
                    active += 1
                }

                // 每完成一个再启动一个
                for await result in group {
                    results.append(result)
                    active -= 1
                    if let i = iterator.next() {
                        let scanURL = items[i].linkedDestination ?? items[i].path
                        group.addTask { (i, fastDirectorySize(at: scanURL)) }
                        active += 1
                    }
                }
                return results
            }

            await MainActor.run {
                guard self.dotFolderScanToken == scanToken else { return }
                for (i, sizeBytes) in sizedItems {
                    guard i < self.dotFolderItems.count else { continue }
                    let sizeStr = LocalizedByteCountFormatter.string(fromByteCount: sizeBytes)
                    withAnimation {
                        self.dotFolderItems[i].size = sizeStr
                        self.dotFolderItems[i].sizeBytes = sizeBytes
                    }
                }
            }
        }
    }

    private func scanLibraryDirs(for app: AppItem) {
        let scanToken = UUID()
        libraryScanToken = scanToken
        isScanning = true
        libraryItems = []
        let appDisplayName = app.displayName
        let appID = app.id
        let selectedExternalRoot = externalDriveURL
        let scanID = AppLogger.shared.makeOperationID(prefix: "scan-library-dirs")
        AppLogger.shared.logContext(
            "开始扫描应用数据目录",
            details: [
                ("scan_id", scanID),
                ("app_name", appDisplayName),
                ("app_path", app.path.path),
                ("external_root", selectedExternalRoot?.path)
            ]
        )
        Task.detached(priority: .userInitiated) {
            let scanner = DataDirScanner()
            let items = await scanner.scanLibraryDirs(for: app, externalRootURL: selectedExternalRoot)

            await MainActor.run {
                guard self.libraryScanToken == scanToken,
                      self.selectedApp?.id == appID else { return }
                self.libraryItems = items
                self.isScanning = false
            }
            AppLogger.shared.logContext(
                "应用数据目录扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("app_name", appDisplayName),
                    ("count", String(items.count)),
                    ("statuses", Dictionary(grouping: items, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
                ]
            )

            // 并行计算所有目录大小
            let sizedItems = await withTaskGroup(of: (Int, Int64).self) { group in
                var results: [(Int, Int64)] = []
                var iterator = items.indices.makeIterator()
                var active = 0
                let maxConcurrency = 4

                // 启动初始批次
                for _ in 0..<min(maxConcurrency, items.count) {
                    guard let i = iterator.next() else { break }
                    let scanURL = items[i].linkedDestination ?? items[i].path
                    group.addTask { (i, fastDirectorySize(at: scanURL)) }
                    active += 1
                }

                // 每完成一个再启动一个
                for await result in group {
                    results.append(result)
                    active -= 1
                    if let i = iterator.next() {
                        let scanURL = items[i].linkedDestination ?? items[i].path
                        group.addTask { (i, fastDirectorySize(at: scanURL)) }
                        active += 1
                    }
                }
                return results
            }

            await MainActor.run {
                guard self.libraryScanToken == scanToken,
                      self.selectedApp?.id == appID else { return }
                for (i, sizeBytes) in sizedItems {
                    guard i < self.libraryItems.count else { continue }
                    let sizeStr = LocalizedByteCountFormatter.string(fromByteCount: sizeBytes)
                    withAnimation {
                        self.libraryItems[i].size = sizeStr
                        self.libraryItems[i].sizeBytes = sizeBytes
                    }
                }
            }
        }
    }

    // MARK: - 迁移 / 还原 确认

    private func askMigrate(_ item: DataDirItem) {
        guard let dest = externalDriveURL else {
            AppLogger.shared.logError(
                "请求迁移数据目录被拒绝：未选择外部路径",
                context: [("item_name", item.name), ("path", item.path.path)],
                relatedURLs: [("item", item.path)]
            )
            errorMessage = "请先选择外部存储路径".localized
            showError = true
            return
        }

        // 检查关联应用是否正在运行
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再迁移其数据目录。".localized, runningAppName)
            showError = true
            return
        }

        // 检查 App 管理权限
        if !skipPermissionCheck && !hasAppManagementPermission() {
            AppLogger.shared.logContext(
                "缺少 App 管理权限，提示用户授权",
                details: [("item_name", item.name)],
                level: "WARN"
            )
            showPermissionAlert = true
            return
        }

        let destPath = suggestedDestinationPath(for: item, under: dest)

        // 沙盒容器子目录迁移风险警告
        if let warning = item.migrationWarning {
            pendingMigrationItem = item
            pendingMigrationDestinationPath = destPath
            pendingMigrationApp = selectedTab == .appDirs ? selectedApp : nil
            migrationRiskMessage = warning
            showMigrationRiskAlert = true
            return
        }

        if selectedTab == .appDirs {
            pendingMigrationItem = item
            pendingMigrationDestinationPath = destPath
            pendingMigrationApp = selectedApp
            showAppDataMigrationRiskConfirm = true
            return
        }

        presentMigrationConfirmation(for: item, destinationPath: destPath, associatedApp: nil)
    }

    private func askRestore(_ item: DataDirItem) {
        // 检查关联应用是否正在运行
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再还原其数据目录。".localized, runningAppName)
            showError = true
            return
        }

        let linkedDest = item.linkedDestination?.path ?? "（未知）".localized

        confirmTitle = "还原数据目录".localized
        confirmActionTitle = "继续".localized
        confirmMessage = String(format: "将「%@」从外部存储还原到本地。\n\n外部路径：%@\n还原到：%@\n\n还原完成后，外部存储中的副本将被删除。".localized,
            item.name, linkedDest, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        confirmAction = { performRestore(item) }
        showConfirm = true
    }

    private func askManageExistingLink(_ item: DataDirItem) {
        guard let linkedDest = item.linkedDestination else {
            AppLogger.shared.logError(
                "请求接管现有软链失败：无法读取目标路径",
                context: [("item_name", item.name), ("path", item.path.path)],
                relatedURLs: [("item", item.path)]
            )
            errorMessage = "无法读取现有软链的目标路径".localized
            showError = true
            return
        }

        confirmTitle = "现有软链".localized
        confirmActionTitle = "规范化管理".localized
        confirmMessage = String(format: "检测到「%@」已经是一个现有软链。\n\n软链路径：%@\n目标路径：%@\n\n选择「规范化管理」后，AppPorts 会将这条软链接纳入受管状态，后续可直接还原。".localized,
            item.name, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), linkedDest.path)
        confirmAction = { queueManagedLinkNormalization(item, currentTarget: linkedDest) }
        showConfirm = true
    }

    private func askNormalizeManagedLink(_ item: DataDirItem) {
        // 检查关联应用是否正在运行
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再整理其数据目录。".localized, runningAppName)
            showError = true
            return
        }

        guard let linkedDest = item.linkedDestination else {
            AppLogger.shared.logError(
                "请求规范化受管软链失败：无法读取目标路径",
                context: [("item_name", item.name), ("path", item.path.path)],
                relatedURLs: [("item", item.path)]
            )
            errorMessage = "无法读取已链接目录的目标路径".localized
            showError = true
            return
        }

        let normalizedTarget = normalizedManagementDestination(for: item, currentTarget: linkedDest)

        confirmTitle = "整理已链接目录".localized
        confirmActionTitle = "继续".localized
        confirmMessage = String(format: "检测到「%@」已经由 AppPorts 接管，但外部目标仍位于旧路径。\n\n当前外部路径：%@\n规范后路径：%@\n\n继续后将进入二次确认，并执行真实迁移。".localized,
            item.name, linkedDest.path, normalizedTarget.path)
        confirmAction = { queueManagedLinkNormalization(item, currentTarget: linkedDest) }
        showConfirm = true
    }

    private func queueManagedLinkNormalization(_ item: DataDirItem, currentTarget: URL) {
        let normalizedTarget = normalizedManagementDestination(for: item, currentTarget: currentTarget)
        let currentPath = currentTarget.path
        let normalizedPath = normalizedTarget.path
        let note = currentPath == normalizedPath
            ? "当前路径已经符合 AppPorts 的规范路径。".localized
            : "当前路径与规范路径不同。本次操作会将外部数据移动到规范路径，并重建本地软链接。".localized

        managedLinkNormalizationItem = item
        managedLinkNormalizationCurrentTarget = currentTarget
        managedLinkNormalizationMessage = String(format: "请确认是否继续规范化管理「%@」。\n\n现在的路径：%@\n规范后路径：%@\n\n%@".localized,
            item.name, currentPath, normalizedPath, note)
        showConfirm = false
        DispatchQueue.main.async {
            self.showManagedLinkNormalizationConfirm = true
        }
    }

    private func askRelinkExternalData(_ item: DataDirItem) {
        // 检查关联应用是否正在运行
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再接回其数据目录。".localized, runningAppName)
            showError = true
            return
        }

        guard let linkedDest = item.linkedDestination else {
            AppLogger.shared.logError(
                "请求接回外部数据失败：无法读取目标路径",
                context: [("item_name", item.name), ("path", item.path.path)],
                relatedURLs: [("item", item.path)]
            )
            errorMessage = "无法读取外部目录路径".localized
            showError = true
            return
        }

        confirmTitle = "接回外部数据".localized
        confirmActionTitle = "接回".localized
        confirmMessage = String(format: "检测到「%@」的数据目录已存在于外部存储，但本地原路径尚未建立链接。\n\n本地原路径：%@\n外部目录：%@\n\n选择「接回」后，AppPorts 会在原路径补建符号链接，并将其纳入受管状态。".localized,
            item.name, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), linkedDest.path)
        confirmAction = { performRelinkExternalData(item, target: linkedDest) }
        showConfirm = true
    }

    // MARK: - 执行操作

    private func performMigrate(
        _ item: DataDirItem,
        to dest: URL,
        shouldResignAssociatedApp: Bool? = nil,
        associatedApp: AppItem? = nil
    ) {
        progressTitle = String(format: "正在迁移「%@」".localized, item.name)
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-data-migrate")
        let shouldResign = shouldResignAssociatedApp ?? autoResignEnabled
        let capturedApp = associatedApp
        AppLogger.shared.logContext(
            "用户确认迁移数据目录",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("type", item.type.rawValue),
                ("source", item.path.path),
                ("destination_root", dest.path),
                ("should_resign_associated_app", shouldResign ? "true" : "false")
            ] + appContextFields(for: capturedApp)
        )

        Task {
            // 解析真实应用路径（外部真实应用或本地真实应用，而非假壳）
            let realAppURL: URL? = {
                guard shouldResign, let app = capturedApp else { return nil }
                return self.resolveRealAppURL?(app) ?? app.displayURL
            }()

            // 迁移前备份真实应用原始签名
            if let url = realAppURL {
                self.onBackupSignatureForURL?(url)
            }

            let mover = DataDirMover()
            do {
                try await mover.migrate(item: item, to: dest) { progress in
                    await MainActor.run {
                        self.progressBytes = progress.copiedBytes
                        self.progressTotalBytes = progress.totalBytes
                        self.progressFileName = progress.currentFile
                    }
                }
                AppLogger.shared.logContext(
                    "数据目录迁移成功",
                    details: [("operation_id", operationID), ("item_name", item.name)]
                )
                await MainActor.run {
                    self.showProgress = false
                    self.reloadCurrentTab()

                    // 数据迁移完成后自动重签名真实应用
                    if let url = realAppURL {
                        self.onResignAppAtURL?(url, true)  // 静默重签名，失败不弹窗
                    }
                }
            } catch {
                AppLogger.shared.logError(
                    "数据目录迁移失败",
                    error: error,
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("source", item.path)]
                )
                await MainActor.run {
                    self.showProgress = false
                    self.refreshSelectedApp()
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func presentMigrationConfirmation(
        for item: DataDirItem,
        destinationPath: URL,
        shouldResignAssociatedApp: Bool? = nil,
        associatedApp: AppItem? = nil
    ) {
        let sizeInfo = item.size.map { String(format: "，大小约 %@".localized, $0) } ?? ""

        confirmTitle = "迁移数据目录".localized
        confirmActionTitle = "继续".localized
        confirmMessage = String(format: "将「%@」迁移到外部存储%@。\n\n源路径：%@\n目标路径：%@\n\n迁移完成后，原路径将自动变成符号链接，相关工具无需任何修改即可继续使用。".localized,
            item.name, sizeInfo, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), destinationPath.path)
        confirmAction = {
            performMigrate(
                item,
                to: destinationPath.deletingLastPathComponent(),
                shouldResignAssociatedApp: shouldResignAssociatedApp,
                associatedApp: associatedApp
            )
        }
        showConfirm = true
    }

    private func continuePendingMigrationFlow() {
        guard let item = pendingMigrationItem,
              pendingMigrationDestinationPath != nil else {
            clearPendingMigrationConfirmation()
            return
        }

        showMigrationRiskAlert = false
        showAppDataMigrationRiskConfirm = false

        if shouldAskForContainerDataResign(item), pendingMigrationShouldResign == nil {
            presentContainerDataResignConfirmation(for: item, associatedApp: pendingMigrationApp)
            return
        }

        presentPendingMigrationConfirmation()
    }

    private func presentPendingMigrationConfirmation() {
        guard let item = pendingMigrationItem,
              let destinationPath = pendingMigrationDestinationPath else {
            clearPendingMigrationConfirmation()
            return
        }
        let shouldResign = pendingMigrationShouldResign
        let associatedApp = pendingMigrationApp

        showContainerDataResignConfirm = false
        clearPendingMigrationConfirmation()
        DispatchQueue.main.async {
            self.presentMigrationConfirmation(
                for: item,
                destinationPath: destinationPath,
                shouldResignAssociatedApp: shouldResign,
                associatedApp: associatedApp
            )
        }
    }

    private func presentContainerDataResignConfirmation(for item: DataDirItem, associatedApp: AppItem?) {
        let appName = associatedApp?.displayName ?? item.name
        containerDataResignMessage = String(
            format: "data_dir_resign_alert_message".localized,
            appName,
            appName
        )
        DispatchQueue.main.async {
            self.showContainerDataResignConfirm = true
        }
    }

    private func shouldAskForContainerDataResign(_ item: DataDirItem) -> Bool {
        selectedTab == .appDirs
            && pendingMigrationApp != nil
            && (item.type == .containers || item.type == .groupContainers)
    }

    private func clearPendingMigrationConfirmation() {
        pendingMigrationItem = nil
        pendingMigrationDestinationPath = nil
        pendingMigrationShouldResign = nil
        pendingMigrationApp = nil
        containerDataResignMessage = ""
    }

    private func performRestore(_ item: DataDirItem) {
        progressTitle = String(format: "正在还原「%@」".localized, item.name)
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-data-restore")
        AppLogger.shared.logContext(
            "用户确认还原数据目录",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("type", item.type.rawValue),
                ("local_path", item.path.path),
                ("linked_destination", item.linkedDestination?.path)
            ] + appContextFields()
        )

        Task {
            let mover = DataDirMover()
            do {
                try await mover.restore(item: item) { progress in
                    await MainActor.run {
                        self.progressBytes = progress.copiedBytes
                        self.progressTotalBytes = progress.totalBytes
                        self.progressFileName = progress.currentFile
                    }
                }
                AppLogger.shared.logContext(
                    "数据目录还原成功",
                    details: [("operation_id", operationID), ("item_name", item.name)]
                )
                await MainActor.run {
                    self.showProgress = false
                    self.reloadCurrentTab()
                }
            } catch {
                AppLogger.shared.logError(
                    "数据目录还原失败",
                    error: error,
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("local", item.path)]
                )
                await MainActor.run {
                    self.showProgress = false
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performManageExistingLink(_ item: DataDirItem, target: URL) {
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-data-manage-link")
        AppLogger.shared.logContext(
            "用户确认接管现有软链",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("local_path", item.path.path),
                ("target", target.path)
            ] + appContextFields()
        )
        Task {
            let mover = DataDirMover()
            let normalizedTarget = normalizedManagementDestination(for: item, currentTarget: target)
            do {
                try await mover.normalizeManagedLink(
                    localPath: item.path,
                    currentExternalPath: target,
                    normalizedExternalPath: normalizedTarget
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                }
            } catch {
                AppLogger.shared.logError(
                    "接管现有软链失败",
                    error: error,
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("local", item.path), ("target", target)]
                )
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performRelinkExternalData(_ item: DataDirItem, target: URL) {
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-data-relink")
        AppLogger.shared.logContext(
            "用户确认接回外部数据",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("local_path", item.path.path),
                ("target", target.path)
            ] + appContextFields()
        )
        Task {
            let mover = DataDirMover()
            do {
                try await mover.createLink(localPath: item.path, externalPath: target)
                AppLogger.shared.logContext(
                    "接回外部数据成功",
                    details: [("operation_id", operationID), ("item_name", item.name)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                }
            } catch {
                AppLogger.shared.logError(
                    "接回外部数据失败",
                    error: error,
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("local", item.path), ("target", target)]
                )
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func suggestedDestinationPath(for item: DataDirItem, under externalRoot: URL) -> URL {
        guard item.type != .dotFolder else {
            return externalRoot.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
        }

        let standardizedPath = item.path.standardizedFileURL.path
        let libraryRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library").standardizedFileURL.path

        if standardizedPath.hasPrefix(libraryRoot + "/") {
            let relativePath = String(standardizedPath.dropFirst(libraryRoot.count + 1))
            return externalRoot.appendingPathComponent(relativePath)
        }

        return externalRoot.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
    }

    private func normalizedManagementDestination(for item: DataDirItem, currentTarget: URL) -> URL {
        if let externalDriveURL {
            return suggestedDestinationPath(for: item, under: externalDriveURL)
        }

        if item.type != .dotFolder {
            let libraryRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library").standardizedFileURL.path
            let localPath = item.path.standardizedFileURL.path

            if localPath.hasPrefix(libraryRoot + "/") {
                let relativePath = String(localPath.dropFirst(libraryRoot.count + 1))
                if let range = currentTarget.standardizedFileURL.path.range(of: "/Library/\(relativePath)") {
                    let basePath = String(currentTarget.standardizedFileURL.path[..<range.lowerBound])
                    return URL(fileURLWithPath: basePath).appendingPathComponent(relativePath)
                }
            }
        }

        return currentTarget
    }

    private func clearManagedLinkNormalizationState() {
        managedLinkNormalizationItem = nil
        managedLinkNormalizationCurrentTarget = nil
        managedLinkNormalizationMessage = ""
    }

    // MARK: - 权限与运行检查

    /// 从 localApps 中刷新 selectedApp，确保 isResigned 等字段为最新
    private func refreshSelectedApp() {
        if let selected = selectedApp,
           let refreshed = localApps.first(where: { $0.path == selected.path }) {
            selectedApp = refreshed
        }
    }

    /// 检查数据目录关联的应用是否正在运行
    ///
    /// - 应用数据 Tab：检查 `selectedApp` 是否正在运行
    /// - 工具目录 Tab：尝试从目录路径中匹配正在运行的进程（基于 bundle ID 或路径名）
    ///
    /// - Returns: 正在运行的应用显示名称，未运行则返回 nil
    private func runningAssociatedAppName(for item: DataDirItem) -> String? {
        let runningApps = NSWorkspace.shared.runningApplications

        // 应用数据 Tab：精确匹配当前选中的应用
        if selectedTab == .appDirs, let app = selectedApp {
            let appPath = app.path
            let isRunning = runningApps.contains { runningApp in
                return runningApp.bundleURL?.standardizedFileURL == appPath.standardizedFileURL
                    || runningApp.bundleIdentifier == bundleIdentifier(for: app)
            }
            if isRunning {
                AppLogger.shared.logContext(
                    "拒绝操作：关联应用正在运行",
                    details: [("app_name", app.displayName), ("app_path", appPath.path), ("item_name", item.name)],
                    level: "WARN"
                )
                return app.displayName
            }
            return nil
        }

        // 工具目录 Tab：尝试从目录路径或名称推断关联进程
        // 例如 ~/.npm → 检查 node/npm 进程（但通常工具目录不需要强制检查）
        // 当前不做强制阻断，因为工具目录通常不与单个 .app 绑定
        return nil
    }

    /// 读取应用的 Bundle Identifier
    private func bundleIdentifier(for app: AppItem) -> String? {
        let plistURL = app.path.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    // MARK: - 日志辅助

    /// 构建关联应用的背景信息字段，供各操作日志复用
    private func appContextFields(for explicitApp: AppItem? = nil) -> [(String, String?)] {
        guard let app = explicitApp ?? selectedApp else { return [] }
        let realURL = resolveRealAppURL?(app) ?? app.displayURL
        let bundleID: String? = {
            let plistURL = realURL.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
            return plist["CFBundleIdentifier"] as? String
        }()
        return [
            ("app_name", app.displayName),
            ("app_status", app.status),
            ("app_is_resigned", app.isResigned ? "true" : "false"),
            ("app_bundle_id", bundleID),
            ("app_real_path", realURL.path),
        ]
    }

    /// 检测当前进程是否有 App 管理权限
    ///
    /// 通过尝试在 /Applications/ 创建测试文件来判断。
    /// App 管理权限（kTCCServiceSystemPolicyAppBundles）控制对 /Applications 的写入。
    private func hasAppManagementPermission() -> Bool {
        let testFile = URL(fileURLWithPath: "/Applications/.appports-permission-test")
        do {
            try Data().write(to: testFile, options: .atomic)
            try FileManager.default.removeItem(at: testFile)
            return true
        } catch {
            return false
        }
    }

    /// 打开系统设置的 App 管理面板
    private func openAppManagementSettings() {
        let venturaURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement")
        let legacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")

        if let url = venturaURL, NSWorkspace.shared.open(url) { return }
        if let url = legacyURL { NSWorkspace.shared.open(url) }
    }
}

// MARK: - 应用选择列表行

/// 左侧应用列表行视图（带 Hover 和选中态）
private struct AppListRow: View {
    let app: AppItem
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // 选中指示条
            RoundedRectangle(cornerRadius: 2)
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(width: 3, height: 24)

            AppIconView(url: app.path)
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

            Text(app.name.replacingOccurrences(of: ".app", with: ""))
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .primary : .primary.opacity(0.85))
                .lineLimit(1)

            // 已重签名标记
            if app.isResigned {
                Image(systemName: "seal.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.teal)
                    .help("此应用已被 Ad-hoc 重签名".localized)
            }

            // Sparkle/Electron 标记
            if app.isSparkleApp {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundColor(.teal.opacity(0.7))
                    .help("Sparkle 自更新应用".localized)
            } else if app.isElectronApp {
                Image(systemName: "atom")
                    .font(.system(size: 9))
                    .foregroundColor(.indigo.opacity(0.7))
                    .help("Electron 应用".localized)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : (isHovered ? Color.primary.opacity(0.04) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - 进度弹窗组件

/// 数据目录迁移/还原进度弹窗
struct DataDirProgressOverlay: View {
    let title: String
    let copiedBytes: Int64
    let totalBytes: Int64
    let currentFile: String

    private var progress: Double {
        totalBytes > 0 ? Double(copiedBytes) / Double(totalBytes) : 0
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 280)

            HStack {
                Text(formatBytes(copiedBytes))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
                Spacer()
                Text(formatBytes(totalBytes))
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(width: 280)

            if !currentFile.isEmpty {
                Text(currentFile)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 280)
            }
        }
        .padding(24)
        .background(.regularMaterial)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        LocalizedByteCountFormatter.string(fromByteCount: bytes)
    }
}

// MARK: - 树形目录项递归视图

/// 递归渲染带子节点的数据目录项。
/// 独立 struct 避免 `@ViewBuilder func -> some View` 的递归类型推断限制。
struct TreeItemView: View {
    let item: DataDirItem
    let level: Int
    let isSelected: Bool
    let onSelect: (String) -> Void
    let onMigrate: (DataDirItem) -> Void
    let onRestore: (DataDirItem) -> Void
    let onManageExistingLink: (DataDirItem) -> Void
    let onNormalizeManagedLink: (DataDirItem) -> Void
    let onRelinkExternalData: (DataDirItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            DataDirRowView(
                item: item,
                isSelected: isSelected,
                level: level,
                onMigrate: onMigrate,
                onRestore: onRestore,
                onManageExistingLink: onManageExistingLink,
                onNormalizeManagedLink: onNormalizeManagedLink,
                onRelinkExternalData: onRelinkExternalData
            )
            .onTapGesture { onSelect(item.id) }

            ForEach(item.children) { child in
                TreeItemView(
                    item: child,
                    level: level + 1,
                    isSelected: isSelected,
                    onSelect: onSelect,
                    onMigrate: onMigrate,
                    onRestore: onRestore,
                    onManageExistingLink: onManageExistingLink,
                    onNormalizeManagedLink: onNormalizeManagedLink,
                    onRelinkExternalData: onRelinkExternalData
                )
            }
        }
    }
}

// MARK: - 分组卡片视图

/// 按数据类型分组的卡片视图，内部使用扁平列表展示
struct DataDirGroupCard: View {
    let group: DataDirGroup
    let selectedItemID: String?
    let onSelect: (String) -> Void
    let onMigrate: (DataDirItem) -> Void
    let onRestore: (DataDirItem) -> Void
    let onManageExistingLink: (DataDirItem) -> Void
    let onNormalizeManagedLink: (DataDirItem) -> Void
    let onRelinkExternalData: (DataDirItem) -> Void

    @State private var isCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            // 卡片头部
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() } }) {
                HStack(spacing: 10) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Image(systemName: group.type.icon)
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                        .frame(width: 18)

                    Text(group.type.localizedTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("\(group.items.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())

                    if group.totalSizeBytes > 0 {
                        Text(LocalizedByteCountFormatter.string(fromByteCount: group.totalSizeBytes))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 卡片内容
            if !isCollapsed {
                Divider()
                    .padding(.horizontal, 14)

                VStack(spacing: 1) {
                    ForEach(group.items) { item in
                        TreeItemView(
                            item: item,
                            level: 0,
                            isSelected: selectedItemID == item.id,
                            onSelect: onSelect,
                            onMigrate: onMigrate,
                            onRestore: onRestore,
                            onManageExistingLink: onManageExistingLink,
                            onNormalizeManagedLink: onNormalizeManagedLink,
                            onRelinkExternalData: onRelinkExternalData
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

}
