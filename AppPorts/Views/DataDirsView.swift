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
}

// MARK: - 数据目录主视图

/// 数据目录管理视图（主界面 Tab 三）
///
/// 展示两类数据目录：
/// - 已知工具 dotFolder（~/.npm、~/.m2 等）
/// - 本地应用在 ~/Library/ 下的关联数据（需用户选择应用）
struct DataDirsView: View {
    @ObservedObject private var languageManager = LanguageManager.shared
    @ObservedObject private var operationState = AppOperationState.shared

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
    /// 经典数据迁移模式生效：容器目录允许符号链接迁移，沙盒应用允许重签名。
    let classicModeActive: Bool
    /// 父级工具栏触发刷新时递增。
    let refreshTrigger: Int
    /// 选择外部存储路径的回调
    let onSelectExternalDrive: () -> URL?
    /// 打开签名修复面板
    var onRepairSignature: ((AppItem) -> Void)? = nil
    /// 数据迁移完成后对关联应用执行重签名的回调（Bool = 是否静默，true 则不弹错误框）
    let onResignApp: ((AppItem, Bool) -> Void)?
    /// 恢复应用原始签名的回调
    let onRestoreSignature: ((AppItem) -> Void)?
    /// 迁移前备份原始签名的回调
    let onBackupSignature: ((AppItem) -> Void)?
    /// 解析应用真实路径（已链接→外部，未链接→本地），不返回假壳路径
    let resolveRealAppURL: (AppItem) throws -> URL
    /// 对指定 URL 重签名；Bool 仅表示本次已明确批准该沙盒应用，不能由全局开关代替。
    let onResignAppAtURL: (URL, Bool) async throws -> Void
    /// 对指定 URL 备份签名（autoResignEnabled 专用）
    let onBackupSignatureForURL: (URL) async throws -> Void

    // MARK: - 内部状态
    @State private var dotFolderItems: [DataDirItem] = []
    @State private var libraryItems:   [DataDirItem] = []
    @State private var dotFolderReadIssues: [DataDirReadIssue] = []
    @State private var libraryReadIssues: [DataDirReadIssue] = []
    @State private var libraryIdentityIssue: AppIdentityIssue?
    @State private var showReadinessCheck = false
    @AppStorage("showZeroByteDataDirectories") private var showZeroByteDirectories = false
    @AppStorage("showLockedAppDataDirectoryStructure") private var showLockedDirectoryStructure = false

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
    @State private var confirmRequest: WarningSheetRequest?
    @State private var appDataMigrationRiskRequest: WarningSheetRequest?
    @State private var pendingMigrationItem: DataDirItem? = nil
    @State private var pendingMigrationDestinationPath: URL? = nil
    @State private var pendingMigrationShouldResign: Bool? = nil
    @State private var pendingMigrationApp: AppItem? = nil
    @State private var pendingApprovedSandboxedTarget: DataMigrationWorkflow.SigningTarget?
    @State private var containerDataResignRequest: WarningSheetRequest?
    @State private var managedLinkNormalizationRequest: WarningSheetRequest?
    @State private var managedLinkNormalizationItem: DataDirItem? = nil
    @State private var managedLinkNormalizationCurrentTarget: URL? = nil
    @State private var migrationRiskRequest: WarningSheetRequest?

    // 挂载迁移（沙盒应用容器数据）
    @State private var selectedAppIsSandboxed = false
    @State private var mountMigrationRequest: WarningSheetRequest?
    @State private var pendingMountMigrationItem: DataDirItem? = nil
    /// 挂载迁移前正在检查目标盘；检查期间忽略重复点击
    @State private var isCheckingMountDestination = false
    @State private var pendingCleanups: [ContainerCleanupRecord] = []
    @State private var dataTransfers: [DataTransferRecord] = []
    @State private var selectedTransfer: DataTransferRecord?
    @State private var cleanupWarning: ContainerVolumeMigrator.CleanupWarning?
    @State private var showCleanupWarning = false

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
    @State private var directorySearchText = ""

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

    private let appDataStatusOrder = ["本地", "已链接", "已挂载", "待挂载", "卷丢失", "待规范", "现有软链", "用户目录入口", "待接回", "未找到"]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if !dataTransfers.isEmpty {
                HStack {
                    Label("原件仍保留，清理后才会释放空间。".localized, systemImage: "doc.on.doc")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu("副本管理".localized) {
                        ForEach(dataTransfers) { transfer in
                            Button { selectedTransfer = transfer } label: {
                                Text(verbatim: transfer.appName + " · " + URL(fileURLWithPath: transfer.originalPath).lastPathComponent)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            if !pendingCleanups.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Spacer()
                    Menu("重试清理".localized) {
                        ForEach(pendingCleanups) { cleanup in
                            let location = cleanup.kind == .migrationBackup ? "本地".localized : "外部存储".localized
                            Button {
                                presentPendingCleanup(cleanup)
                            } label: {
                                Text(verbatim: "\(cleanup.mountRecord.appName) · \(cleanup.mountRecord.mountPointURL.lastPathComponent) (\(location))")
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            // ── 主内容区 ────────────────────────────────────────
            if selectedTab == .toolDirs {
                toolDirsContent
            } else {
                appDirsContent
            }
        }
        .disabled(operationState.isBusy)
        .onAppear {
            reloadCurrentTab()
        }
        .onChange(of: selectedTab) { _ in
            reloadCurrentTab()
        }
        .onChange(of: refreshTrigger) { _ in
            clearSizeCache()
            reloadCurrentTab()
        }
        .onChange(of: externalDriveURL) { _ in
            clearSizeCache()
            reloadCurrentTab()
        }
        .onChange(of: languageManager.language) { _ in
            reloadCurrentTab()
        }
        // 确认弹窗
        .warningSheet($confirmRequest)
        .warningSheet($appDataMigrationRiskRequest)
        .warningSheet($managedLinkNormalizationRequest)
        .warningSheet($migrationRiskRequest)
        .warningSheet($containerDataResignRequest)
        .warningSheet($mountMigrationRequest)
        .sheet(isPresented: $showReadinessCheck) {
            ReadinessCheckSheet()
        }
        .sheet(item: $selectedTransfer) { transfer in
            DataTransferReviewView(transfer: transfer, onCleanup: { cleanupTransfer(transfer) })
        }
        // 错误弹窗
        .alert("操作失败".localized, isPresented: $showError) {
            Button("好的".localized, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("已完成，但仍有清理事项".localized, isPresented: $showCleanupWarning) {
            Button("重试清理".localized) {
                if let warning = cleanupWarning { retryCleanup(warning) }
            }
            Button("仅移除清理记录".localized) {
                if let warning = cleanupWarning { confirmDiscardCleanupRecord(warning.cleanup) }
            }
            Button("稍后".localized, role: .cancel) {}
        } message: {
            Text(cleanupWarning?.message ?? "")
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
                statsBar(items: filteredDotFolderItems)
            }

            // 列表
            ZStack {
                Color(nsColor: .controlBackgroundColor).ignoresSafeArea()

                if isScanning && dotFolderItems.isEmpty {
                    loadingView
                } else if dotFolderItems.isEmpty {
                    ContentView.EmptyStateView(icon: "folder.badge.questionmark", text: "未发现已知工具目录".localized)
                } else if filteredDotFolderItems.isEmpty {
                    ContentView.EmptyStateView(icon: "line.3.horizontal.decrease.circle", text: "没有匹配当前筛选条件的数据目录".localized)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredDotFolderItems) { item in
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
                                .padding(.horizontal, 12)
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
                appSelectionHeader

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

                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(sortedApps, id: \.id) { app in
                                Button {
                                    selectedApp = app
                                } label: {
                                    AppListRow(app: app, isSelected: selectedApp?.id == app.id)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(app.displayName)
                                .accessibilityAddTraits(selectedApp?.id == app.id ? .isSelected : [])
                            }
                        }
                        .padding(.bottom, 12)
                        .padding(.horizontal, 12)
                    }
                }
            }
            .frame(minWidth: 200, maxWidth: 280)
            .onChange(of: selectedApp) { newApp in
                if let app = newApp { scanLibraryDirs(for: app) }
                else {
                    libraryScanToken = UUID()
                    libraryItems = []
                    libraryReadIssues = []
                    libraryIdentityIssue = nil
                    selectedAppIsSandboxed = false
                    isScanning = false
                }
            }
            .onChange(of: selectedApp?.path) { _ in
                directorySearchText = ""
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
                            Text(String(format: "%@ 的数据目录".localized, app.displayName))
                        } else {
                            Text("请从左侧选择应用".localized)
                        }
                        Spacer()
                        if selectedApp != nil {
                            appDataSortMenu
                            appDataFilterButton
                        }
                    }
                    .frame(minHeight: 22)

                    if selectedApp != nil {
                        directorySearchField
                        if hasActiveAppDataFilters { appDataFilterSummary }
                        if !libraryItems.isEmpty || !libraryReadIssues.isEmpty || libraryIdentityIssue != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                statsSummary(
                                    items: filteredLibraryItems,
                                    allItems: libraryItems,
                                    readIssues: libraryReadIssues,
                                    hasIdentityIssue: libraryIdentityIssue != nil
                                )
                                appDataVisibilityToggles
                            }
                        }
                        if let issue = libraryIdentityIssue {
                            appIdentityWarning(issue: issue)
                        }
                        if !libraryReadIssues.isEmpty {
                            directoryReadWarning(issues: libraryReadIssues)
                        }
                    }
                }
                .font(.headline)
                .settingsCardBackground(opacity: 0.05)
                .padding(12)

                // 外部存储路径提示
                if externalDriveURL == nil { externalDriveWarning }

                if let app = selectedApp, app.needsSignatureAttention {
                    signatureReplacedBanner(for: app)
                }

                ZStack {
                    Color(nsColor: .controlBackgroundColor).ignoresSafeArea()

                    if selectedApp == nil {
                        ContentView.EmptyStateView(icon: "arrow.left.circle", text: "从左侧选择一个应用".localized)
                    } else if isScanning && libraryItems.isEmpty {
                        loadingView
                    } else if libraryItems.isEmpty {
                        if libraryIdentityIssue != nil {
                            ContentView.EmptyStateView(icon: "exclamationmark.circle", text: "无法完整识别应用数据".localized)
                        } else if !libraryReadIssues.isEmpty {
                            ContentView.EmptyStateView(icon: "exclamationmark.circle", text: "部分目录无法读取，请检查后刷新。".localized)
                        } else {
                            ContentView.EmptyStateView(icon: "folder.badge.questionmark", text: "未找到关联数据目录".localized)
                        }
                    } else if sortedFilteredLibraryItems.isEmpty {
                        ContentView.EmptyStateView(icon: "line.3.horizontal.decrease.circle", text: "没有匹配当前筛选条件的数据目录".localized)
                    } else {
                        AppDataDirectoryBrowser(
                            groups: groupedLibraryItems,
                            matchingItemIDs: Set(filteredLibraryItems.map(\.id)),
                            isFiltering: hasActiveAppDataFilters || !directorySearchText.isEmpty,
                            showLockedStructure: showLockedDirectoryStructure,
                            actions: directoryOperationButtons
                        )
                    }
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 辅助子视图

    private var appSelectionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("应用".localized)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(localApps.filter { !$0.isFolder }.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .fixedSize()
                }

                Spacer(minLength: 4)

                if !localApps.isEmpty {
                    appSelectionSortMenu
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.6))
                    .frame(width: 32)
                TextField(
                    "搜索应用...".localized,
                    text: $appSearchText,
                    prompt: Text("搜索应用...".localized).foregroundColor(.primary.opacity(0.6))
                )
                    .textFieldStyle(.plain)
                    .foregroundColor(.primary)
                    .onExitCommand { appSearchText = "" }
                if !appSearchText.isEmpty {
                    Button { appSearchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索".localized)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var appSelectionSortMenu: some View {
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
            Label(selectedAppSortMode.localizedTitle, systemImage: "arrow.up.arrow.down")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("排序方式".localized)
    }

    private var externalDriveWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundColor(.orange)
            Text("请先选择外部存储路径".localized)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button("选择外部存储".localized) { _ = onSelectExternalDrive() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundColor(.orange.opacity(0.2)), alignment: .bottom)
    }

    private func signatureReplacedBanner(for app: AppItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(app.signatureCheckUnavailable ? .orange : .red)
            Text(app.signatureCheckUnavailable
                 ? "暂时无法检查签名。请连接外置盘后重新检查；恢复备份已保留。".localized
                 : "此应用的签名曾被 AppPorts 替换，在 macOS 27 上可能无法正常启动。如果它现在能正常启动，可以暂不处理；无法打开请根据右侧修复步骤恢复。".localized)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onRepairSignature {
                Button(app.signatureCheckUnavailable ? "检查签名".localized : "查看修复步骤".localized) { onRepairSignature(app) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background((app.signatureCheckUnavailable ? Color.orange : .red).opacity(0.06))
        .overlay(Rectangle().frame(height: 1).foregroundColor((app.signatureCheckUnavailable ? Color.orange : .red).opacity(0.2)), alignment: .bottom)
    }

    private var directorySearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.primary.opacity(0.6))
            TextField(
                "搜索目录或路径…".localized,
                text: $directorySearchText,
                prompt: Text("搜索目录或路径…".localized).foregroundColor(.primary.opacity(0.6))
            )
                .textFieldStyle(.plain)
                .foregroundColor(.primary)
                .onExitCommand { directorySearchText = "" }
            if !directorySearchText.isEmpty {
                Button { directorySearchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索".localized)
            }
            Text(String(format: "显示 %lld / %lld".localized, Int64(filteredLibraryItems.count), Int64(libraryItems.count)))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                statsSummary(items: items, allItems: dotFolderItems, readIssues: dotFolderReadIssues)
                zeroByteDirectoriesToggle
            }
            if !dotFolderReadIssues.isEmpty {
                directoryReadWarning(issues: dotFolderReadIssues)
            }
        }
        .settingsCardBackground(opacity: 0.05)
        .padding(12)
    }

    private var appDataVisibilityToggles: some View {
        AppDataVisibilityControls(showZeroByteDirectories: $showZeroByteDirectories,
                                  showLockedStructure: $showLockedDirectoryStructure)
    }

    private var zeroByteDirectoriesToggle: some View {
        Toggle("显示零字节目录".localized, isOn: $showZeroByteDirectories)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .fixedSize()
    }

    private func directoryReadWarning(issues: [DataDirReadIssue]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("部分目录无法读取，请检查后刷新。".localized)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(issues.map { $0.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: "\n"))
            Spacer(minLength: 0)
            if issues.contains(where: \.isPermissionDenied) {
                Button("检查访问权限".localized) {
                    showReadinessCheck = true
                }
                .buttonStyle(.link)
                .help("AppPorts 读取邮件、信息等受保护的应用数据目录需要它。请在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」里勾选 AppPorts。".localized)
            }
        }
        .font(.system(size: 12))
    }

    private func appIdentityWarning(issue: AppIdentityIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("应用信息读取失败，以下结果可能不完整。".localized)
                if issue.reason == .realAppUnavailable {
                    Text("请检查应用路径；若应用位于外置磁盘，请连接磁盘后刷新。".localized)
                }
            }
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .help(issue.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .accessibilityElement(children: .combine)
    }

    private func statsSummary(
        items: [DataDirItem], allItems: [DataDirItem], readIssues: [DataDirReadIssue], hasIdentityIssue: Bool = false
    ) -> some View {
        let summary = DataDirSpaceSummary(
            items: items, allItems: allItems, hasReadIssues: !readIssues.isEmpty, hasIdentityIssue: hasIdentityIssue
        )
        let linked = items.filter { $0.status == "已链接" }.count
        let mounted = items.filter { DataDirStatus.mountStatuses.contains($0.status) }.count
        let needsNormalization = items.filter { $0.status == "待规范" }.count
        let existingSymlinks = items.filter { $0.status == "现有软链" && !$0.isUserDirectoryLink }.count
        let relinkable = items.filter { $0.status == "待接回" }.count
        return HStack(spacing: 14) {
            Label(String(format: "%lld 个目录".localized, Int64(items.count)), systemImage: "folder.fill")
                .foregroundColor(.secondary)
            if summary.isIncomplete {
                Label("空间统计不完整".localized, systemImage: "exclamationmark.circle")
                    .foregroundColor(.orange)
            } else if summary.isCalculating {
                Label("计算中...".localized, systemImage: "hourglass")
                    .foregroundColor(.secondary)
            } else if summary.reclaimableBytes > 0 {
                Label(
                    LocalizedByteCountFormatter.string(fromByteCount: summary.reclaimableBytes, allowedUnits: [.mb, .gb]) + " 可释放".localized,
                    systemImage: "sparkles"
                )
                    .foregroundColor(.accentColor)
                    .help("原件仍保留，清理后才会释放空间。".localized)
            }
            if linked > 0 {
                Label(String(format: "%lld 个已链接".localized, Int64(linked)), systemImage: "link.circle.fill")
                    .foregroundColor(.green)
            }
            if mounted > 0 {
                Label(String(format: "%lld 个挂载迁移".localized, Int64(mounted)), systemImage: "externaldrive.fill.badge.checkmark")
                    .foregroundColor(.purple)
            }
            if needsNormalization > 0 {
                Label(String(format: "%lld 个待整理".localized, Int64(needsNormalization)), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.mint)
            }
            if existingSymlinks > 0 {
                Label(String(format: "%lld 个现有软链".localized, Int64(existingSymlinks)), systemImage: "questionmark.circle")
                    .foregroundColor(.teal)
            }
            if relinkable > 0 {
                Label(String(format: "%lld 个待接回".localized, Int64(relinkable)), systemImage: "arrow.triangle.branch")
                    .foregroundColor(.indigo)
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

    private func directoryOperationButtons(for item: DataDirItem) -> DataDirOperationButtons {
        DataDirOperationButtons(
            item: item,
            onMigrate: askMigrate,
            onRestore: askRestore,
            onManageExistingLink: askManageExistingLink,
            onNormalizeManagedLink: askNormalizeManagedLink,
            onRelinkExternalData: askRelinkExternalData,
            onMountMigrate: askMountMigrate,
            onMount: performMount,
            onUnmount: performUnmount,
            onMountRestore: askMountRestore,
            classicModeActive: classicModeActive,
            inline: true
        )
    }

    private var filteredLibraryItems: [DataDirItem] {
        libraryItems.filter(matchesAppDataFilters)
    }

    private var filteredDotFolderItems: [DataDirItem] {
        dotFolderItems.filter { showZeroByteDirectories || !$0.isEmptyLocalDirectory }
    }

    /// 链接状态优先级：已链接、挂载迁移、待规范、现有软链优先展示
    private let statusPriority: [String] = ["已链接", "已挂载", "待挂载", "卷丢失", "待规范", "现有软链", "用户目录入口", "待接回", "本地", "未找到"]

    private func statusSortKey(_ status: String) -> Int {
        statusPriority.firstIndex(of: status) ?? statusPriority.count
    }

    private var sortedFilteredLibraryItems: [DataDirItem] {
        sortedLibraryItems.filter(matchesAppDataFilters)
    }

    private var sortedLibraryItems: [DataDirItem] {
        switch selectedAppDataSortMode {
        case .defaultOrder:
            // 已迁移路径在前，然后按大小降序
            return libraryItems.sorted { lhs, rhs in
                let lhsKey = statusSortKey(lhs.displayedStatus)
                let rhsKey = statusSortKey(rhs.displayedStatus)
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.path.lastPathComponent.localizedStandardCompare(rhs.path.lastPathComponent) == .orderedAscending
            }
        case .size:
            return libraryItems.sorted { lhs, rhs in
                if lhs.sizeBytes != rhs.sizeBytes {
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                return lhs.path.lastPathComponent.localizedStandardCompare(rhs.path.lastPathComponent) == .orderedAscending
            }
        case .alphabetical:
            return libraryItems.sorted { lhs, rhs in
                lhs.path.lastPathComponent.localizedStandardCompare(rhs.path.lastPathComponent) == .orderedAscending
            }
        }
    }

    private var groupedLibraryItems: [DataDirGroup] {
        let matchingIDs = Set(filteredLibraryItems.map(\.id))
        let groups = Dictionary(grouping: sortedLibraryItems, by: \.type)
        return DataDirType.allCases.compactMap { type in
            guard let items = groups[type] else { return nil }
            let tree = DataDirTree.visibleTree(from: items,
                                              showZeroByteDirectories: showZeroByteDirectories,
                                              showLockedStructure: showLockedDirectoryStructure,
                                              matchingIDs: matchingIDs)
            return tree.isEmpty ? nil : DataDirGroup(type: type, items: tree)
        }
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
        labels.append(contentsOf: appDataStatusOrder.filter(selectedStatusFilters.contains).map(DataDirStatus.localized))
        labels.append(contentsOf: appDataFilterTypes.filter(selectedTypeFilters.contains).map(\.localizedTitle))
        return labels
    }

    private var appDataFilterTypes: [DataDirType] {
        DataDirType.allCases.filter { $0 != .dotFolder }
    }

    private func matchesAppDataFilters(_ item: DataDirItem) -> Bool {
        let query = directorySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesSearch = query.isEmpty || item.path.path.localizedStandardContains(query)
            || item.name.localizedStandardContains(query) || item.description.localizedStandardContains(query)
        return matchesSearch && (selectedPriorityFilters.isEmpty || selectedPriorityFilters.contains(item.priority))
            && (selectedStatusFilters.isEmpty || selectedStatusFilters.contains(item.displayedStatus))
            && (selectedTypeFilters.isEmpty || selectedTypeFilters.contains(item.type))
            && item.matchesVisibility(showZeroByteDirectories: showZeroByteDirectories,
                                      showLockedStructure: showLockedDirectoryStructure)
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
        do { dataTransfers = try ContainerMountStore.shared.transfers() }
        catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        do { pendingCleanups = try ContainerMountStore.shared.pendingCleanups() }
        catch {
            AppLogger.shared.logError("无法读取待清理记录，保留原文件", error: error, errorCode: "CONTAINER-CLEANUP-RECORD-READ-FAILED")
        }
        AppLogger.shared.logContext(
            "刷新数据目录当前标签",
            details: [
                ("selected_tab", selectedTab == .toolDirs ? "toolDirs" : "appData"),
                ("selected_app", selectedApp?.displayName)
            ],
            level: "TRACE"
        )
        if selectedTab == .toolDirs {
            libraryScanToken = UUID()
            scanDotFolders()
        } else {
            dotFolderScanToken = UUID()
            if let app = selectedApp {
                scanLibraryDirs(for: app)
            } else {
                isScanning = false
            }
        }
    }

    private func scanDotFolders() {
        let scanToken = UUID()
        dotFolderScanToken = scanToken
        isScanning = true
        dotFolderReadIssues = []
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
            }
            AppLogger.shared.logContext(
                "工具目录扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("count", String(items.count)),
                    ("statuses", Dictionary(grouping: items, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
                ]
            )

            // 每次扫描重新测量，应用运行期间的写入不能沿用上次大小。
            let sizedItems = await withTaskGroup(of: (Int, DirectorySizeResult).self) { group in
                var results: [(Int, DirectorySizeResult)] = []
                var iterator = items.indices.makeIterator()
                var active = 0
                let maxConcurrency = 4

                // 启动初始批次
                for _ in 0..<min(maxConcurrency, items.count) {
                    guard let i = iterator.next() else { break }
                    let scanURL = items[i].sizeMeasurementURL
                    group.addTask { (i, scanURL.map { measureDirectorySize(at: $0, useCache: false) } ?? DirectorySizeResult()) }
                    active += 1
                }

                // 每完成一个再启动一个
                for await result in group {
                    results.append(result)
                    active -= 1
                    if let i = iterator.next() {
                        let scanURL = items[i].sizeMeasurementURL
                        group.addTask { (i, scanURL.map { measureDirectorySize(at: $0, useCache: false) } ?? DirectorySizeResult()) }
                        active += 1
                    }
                }
                return results
            }

            await MainActor.run {
                guard self.dotFolderScanToken == scanToken else { return }
                withAnimation {
                    for (i, result) in sizedItems {
                        guard i < self.dotFolderItems.count else { continue }
                        self.dotFolderItems[i].applySize(result)
                        self.dotFolderReadIssues.append(contentsOf: result.readIssues)
                    }
                    self.isScanning = false
                }
            }
        }
    }

    private func scanLibraryDirs(for app: AppItem) {
        let scanToken = UUID()
        libraryScanToken = scanToken
        isScanning = true
        libraryItems = []
        libraryReadIssues = []
        libraryIdentityIssue = nil
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
            // 沙盒应用迁移数据后不能重签名；先算一次供整页使用。
            let isSandboxed = await scanner.isSandboxed(app)
            let scanResult = await scanner.scanLibraryDirsWithDiagnostics(for: app, externalRootURL: selectedExternalRoot)
            let items = scanResult.items

            await MainActor.run {
                guard self.libraryScanToken == scanToken,
                      self.selectedApp?.id == appID else { return }
                self.libraryItems = items
                self.libraryReadIssues = scanResult.readIssues
                self.libraryIdentityIssue = scanResult.identityIssue
                self.selectedAppIsSandboxed = isSandboxed
            }
            AppLogger.shared.logContext(
                "应用数据目录扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("app_name", appDisplayName),
                    ("sandboxed", isSandboxed ? "true" : "false"),
                    ("count", String(items.count)),
                    ("statuses", Dictionary(grouping: items, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
                ]
            )

            // 并行计算所有目录大小
            let sizedItems = await withTaskGroup(of: (Int, DirectorySizeResult).self) { group in
                var results: [(Int, DirectorySizeResult)] = []
                var iterator = items.indices.makeIterator()
                var active = 0
                let maxConcurrency = 4

                // 启动初始批次
                for _ in 0..<min(maxConcurrency, items.count) {
                    guard let i = iterator.next() else { break }
                    let scanURL = items[i].sizeMeasurementURL
                    group.addTask { (i, scanURL.map { measureDirectorySize(at: $0, useCache: false) } ?? DirectorySizeResult()) }
                    active += 1
                }

                // 每完成一个再启动一个
                for await result in group {
                    results.append(result)
                    active -= 1
                    if let i = iterator.next() {
                        let scanURL = items[i].sizeMeasurementURL
                        group.addTask { (i, scanURL.map { measureDirectorySize(at: $0, useCache: false) } ?? DirectorySizeResult()) }
                        active += 1
                    }
                }
                return results
            }

            await MainActor.run {
                guard self.libraryScanToken == scanToken,
                      self.selectedApp?.id == appID else { return }
                withAnimation {
                    for (i, result) in sizedItems {
                        guard i < self.libraryItems.count else { continue }
                        self.libraryItems[i].applySize(result)
                        self.libraryReadIssues.append(contentsOf: result.readIssues)
                    }
                    self.isScanning = false
                }
            }
        }
    }

    // MARK: - 迁移 / 还原 确认

    private func askMigrate(_ item: DataDirItem) {
        // 容器数据只能挂载迁移；符号链接会被内核按真实路径拒绝。经典模式下由用户自担风险。
        if item.requiresMountMigration && !classicModeActive {
            askMountMigrate(item)
            return
        }

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

        // 沙盒容器子目录迁移风险警告；经典模式下容器目录一律提示
        let classicContainerWarning: String? = (item.requiresMountMigration && classicModeActive)
            ? "经典模式：此目录位于沙盒应用容器内。符号链接迁移后，沙盒应用只有在重签名后才能读到数据，而重签名过的应用在 macOS 27 上可能无法打开。推荐改用「挂载迁移」。".localized
            : nil
        if let warning = item.migrationWarning ?? classicContainerWarning {
            pendingMigrationItem = item
            pendingMigrationDestinationPath = destPath
            pendingMigrationApp = selectedTab == .appDirs ? selectedApp : nil
            migrationRiskRequest = WarningSheetRequest(
                title: "迁移风险提示".localized,
                tint: .orange,
                intro: warning,
                onCancel: { clearPendingMigrationConfirmation() },
                actions: [
                    WarningAction("继续".localized, style: .preferred) {
                        continuePendingMigrationFlow()
                    }
                ]
            )
            return
        }

        if selectedTab == .appDirs {
            pendingMigrationItem = item
            pendingMigrationDestinationPath = destPath
            pendingMigrationApp = selectedApp
            appDataMigrationRiskRequest = makeAppDataMigrationRiskRequest()
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

        confirmRequest = makeConfirmRequest(
            title: "还原数据目录".localized,
            actionTitle: "继续".localized,
            message: String(format: "将「%@」还原到本地。\n\n外部来源：%@\n还原到：%@\n\n还原后保留外部原件；验证应用与数据正常后，可在副本管理中校验并清理。".localized,
                item.name, linkedDest, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")),
            action: { performRestore(item) }
        )
    }

    private func isContainerSymlinkOperationBlocked(_ item: DataDirItem) -> Bool {
        guard item.type == .containers || item.type == .groupContainers, !classicModeActive else { return false }
        errorMessage = "容器目录不再使用符号链接迁移。请先「还原」到本地，再使用「挂载迁移」。".localized
        showError = true
        return true
    }

    private func askManageExistingLink(_ item: DataDirItem) {
        if isContainerSymlinkOperationBlocked(item) { return }
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

        confirmRequest = makeConfirmRequest(
            title: "现有软链".localized,
            actionTitle: "规范化管理".localized,
            message: String(format: "检测到「%@」已经是一个现有软链。\n\n软链路径：%@\n目标路径：%@\n\n选择「规范化管理」后，AppPorts 会将这条软链接纳入受管状态，后续可直接还原。".localized,
                item.name, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), linkedDest.path),
            action: { queueManagedLinkNormalization(item, currentTarget: linkedDest) }
        )
    }

    private func askNormalizeManagedLink(_ item: DataDirItem) {
        if isContainerSymlinkOperationBlocked(item) { return }
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

        confirmRequest = makeConfirmRequest(
            title: "整理已链接目录".localized,
            actionTitle: "继续".localized,
            message: String(format: "检测到「%@」已经由 AppPorts 接管，但外部目标仍位于旧路径。\n\n当前外部路径：%@\n规范后路径：%@\n\n继续后将进入二次确认，并执行真实迁移。".localized,
                item.name, linkedDest.path, normalizedTarget.path),
            action: { queueManagedLinkNormalization(item, currentTarget: linkedDest) }
        )
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
        let request = WarningSheetRequest(
            title: "确认规范化管理".localized,
            icon: "questionmark.circle.fill",
            tint: .blue,
            intro: String(format: "请确认是否继续规范化管理「%@」。\n\n现在的路径：%@\n规范后路径：%@\n\n%@".localized,
                item.name, currentPath, normalizedPath, note),
            onCancel: { clearManagedLinkNormalizationState() },
            actions: [
                WarningAction("确认".localized, style: .preferred) {
                    if let item = managedLinkNormalizationItem,
                       let target = managedLinkNormalizationCurrentTarget {
                        performManageExistingLink(item, target: target)
                    }
                    clearManagedLinkNormalizationState()
                }
            ]
        )
        confirmRequest = nil
        // 先关掉上一个弹窗，下一拍再开这一个，避免同一帧内切换 sheet。
        DispatchQueue.main.async {
            self.managedLinkNormalizationRequest = request
        }
    }

    private func askRelinkExternalData(_ item: DataDirItem) {
        if isContainerSymlinkOperationBlocked(item) { return }
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

        confirmRequest = makeConfirmRequest(
            title: "接回外部数据".localized,
            actionTitle: "接回".localized,
            message: String(format: "检测到「%@」的数据目录已存在于外部存储，但本地原路径尚未建立链接。\n\n本地原路径：%@\n外部目录：%@\n\n选择「接回」后，AppPorts 会在原路径补建符号链接，并将其纳入受管状态。".localized,
                item.name, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), linkedDest.path),
            action: { performRelinkExternalData(item, target: linkedDest) }
        )
    }

    // MARK: - 执行操作

    private func performMigrate(
        _ item: DataDirItem,
        to dest: URL,
        shouldResignAssociatedApp: Bool? = nil,
        associatedApp: AppItem? = nil,
        approvedSandboxedTarget: DataMigrationWorkflow.SigningTarget? = nil
    ) {
        if let runningAppName = runningAssociatedAppName(for: item, associatedApp: associatedApp) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再迁移其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在迁移「%@」".localized, item.name)
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-data-migrate")
        let capturedApp = associatedApp
        let requestedSigning = shouldResignAssociatedApp ?? autoResignEnabled

        Task { @MainActor in
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
            }
            let mover = DataDirMover()
            do {
                let signingAppURL: URL?
                let signingTarget: DataMigrationWorkflow.SigningTarget?
                if requestedSigning, let app = capturedApp {
                    let target = try DataMigrationWorkflow.signingTarget(at: app.displayURL)
                    signingTarget = target
                    // 默认模式仍然只迁移数据；经典模式须由工作流核验这个真实应用的批准。
                    signingAppURL = target.isSandboxed && !classicModeActive ? nil : app.displayURL
                } else {
                    signingTarget = nil
                    signingAppURL = nil
                }
                AppLogger.shared.logContext(
                    "用户确认迁移数据目录",
                    details: [
                        ("operation_id", operationID),
                        ("item_name", item.name),
                        ("type", item.type.rawValue),
                        ("source", item.path.path),
                        ("destination_root", dest.path),
                        ("associated_app_sandboxed", signingTarget.map { $0.isSandboxed ? "true" : "false" } ?? "not_checked"),
                        ("should_resign_associated_app", signingAppURL != nil ? "true" : "false")
                    ] + appContextFields(for: capturedApp)
                )

                try await DataMigrationWorkflow.run(
                    signingAppURL: signingAppURL,
                    classicModeActive: classicModeActive,
                    approvedSandboxedTarget: approvedSandboxedTarget,
                    validateBeforeMigration: {
                        // 备份原应用可能耗时较长；实际搬数据前重新读取运行状态。
                        if self.runningAssociatedAppName(for: item, associatedApp: capturedApp) != nil {
                            throw AppMoverError.appIsRunning
                        }
                    },
                    backupSignature: onBackupSignatureForURL,
                    migrate: {
                        try await mover.migrate(item: item, to: dest) { progress in
                            await MainActor.run {
                                self.progressBytes = progress.copiedBytes
                                self.progressTotalBytes = progress.totalBytes
                                self.progressFileName = progress.currentFile
                            }
                        }
                    },
                    resignApp: { url, sandboxedAppApproved in
                        await MainActor.run {
                            self.progressTitle = "重签名此应用".localized
                            self.progressFileName = url.lastPathComponent
                            self.progressBytes = 0
                            self.progressTotalBytes = 0
                        }
                        try await self.onResignAppAtURL(url, sandboxedAppApproved)
                    }
                )
                AppLogger.shared.logContext(
                    "数据目录迁移成功",
                    details: [("operation_id", operationID), ("item_name", item.name)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                }
            } catch {
                AppLogger.shared.logError(
                    error is DataMigrationWorkflow.Failure ? "数据迁移后重签名失败（应用可能无法通过 macOS 签名校验）" : "数据目录迁移失败",
                    error: error,
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("source", item.path)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
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
        associatedApp: AppItem? = nil,
        approvedSandboxedTarget: DataMigrationWorkflow.SigningTarget? = nil
    ) {
        let sizeInfo = item.size.map { String(format: "，大小约 %@".localized, $0) } ?? ""

        confirmRequest = makeConfirmRequest(
            title: "迁移数据目录".localized,
            actionTitle: "继续".localized,
            message: String(format: "将「%@」迁移到外部存储%@。\n\n源路径：%@\n目标路径：%@\n\n迁移完成后，原路径将自动变成符号链接，相关工具无需任何修改即可继续使用。".localized,
                item.name, sizeInfo, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), destinationPath.path),
            action: {
                performMigrate(
                    item,
                    to: destinationPath.deletingLastPathComponent(),
                    shouldResignAssociatedApp: shouldResignAssociatedApp,
                    associatedApp: associatedApp,
                    approvedSandboxedTarget: approvedSandboxedTarget
                )
            }
        )
    }

    /// 组装「迁移数据目录前请先备份」风险确认弹窗的内容快照。
    private func makeAppDataMigrationRiskRequest() -> WarningSheetRequest {
        WarningSheetRequest(
            title: "迁移前请先备份".localized,
            icon: "externaldrive.badge.exclamationmark",
            tint: .orange,
            intro: "迁移应用数据可能导致目标软件出现不可预料的兼容性问题。建议你先自行备份当前数据，再在副本或可接受风险的环境中迁移并测试，确认软件工作正常后再继续长期使用。".localized,
            onCancel: { clearPendingMigrationConfirmation() },
            actions: [
                WarningAction("继续".localized, style: .preferred) {
                    continuePendingMigrationFlow()
                }
            ]
        )
    }

    /// 组装一个「标题 + 正文 + 单个继续按钮」的确认弹窗。
    private func makeConfirmRequest(
        title: String,
        actionTitle: String,
        message: String,
        action: @escaping () -> Void
    ) -> WarningSheetRequest {
        WarningSheetRequest(
            title: title,
            icon: "questionmark.circle.fill",
            tint: .blue,
            intro: message,
            actions: [WarningAction(actionTitle, style: .preferred, handler: action)]
        )
    }

    private func continuePendingMigrationFlow() {
        guard let item = pendingMigrationItem,
              pendingMigrationDestinationPath != nil else {
            clearPendingMigrationConfirmation()
            return
        }

        migrationRiskRequest = nil

        let offersContainerSigningChoice = shouldAskForContainerDataResign(item)
            && pendingMigrationShouldResign == nil
        let wantsSigning = pendingMigrationShouldResign ?? autoResignEnabled
        if (offersContainerSigningChoice || wantsSigning), let app = pendingMigrationApp {
            do {
                let target = try DataMigrationWorkflow.signingTarget(at: app.displayURL)
                if target.isSandboxed && !classicModeActive {
                    pendingMigrationShouldResign = false
                    pendingApprovedSandboxedTarget = nil
                } else if offersContainerSigningChoice
                    || (target.isSandboxed && pendingApprovedSandboxedTarget != target) {
                    presentContainerDataResignConfirmation(for: target)
                    return
                }
            } catch {
                clearPendingMigrationConfirmation()
                errorMessage = error.localizedDescription
                showError = true
                return
            }
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
        let approvedSandboxedTarget = pendingApprovedSandboxedTarget

        containerDataResignRequest = nil
        clearPendingMigrationConfirmation()
        DispatchQueue.main.async {
            self.presentMigrationConfirmation(
                for: item,
                destinationPath: destinationPath,
                shouldResignAssociatedApp: shouldResign,
                associatedApp: associatedApp,
                approvedSandboxedTarget: approvedSandboxedTarget
            )
        }
    }

    private func presentContainerDataResignConfirmation(for target: DataMigrationWorkflow.SigningTarget) {
        let appName = target.url.lastPathComponent
        let message = target.isSandboxed
            ? String(format: "「%@」是沙盒应用。经典模式会先完整备份原应用，再重签并移除沙盒、应用组和钥匙串授权。在 macOS 27 上此应用可能无法打开；需要恢复时，先还原容器数据，再恢复原始签名。".localized, appName)
            : String(format: "data_dir_resign_alert_message".localized, appName, appName)
        let request = WarningSheetRequest(
            title: target.isSandboxed ? "对沙盒应用重签名".localized : "data_dir_resign_alert_title".localized,
            intro: message,
            acknowledgementTitle: "我已了解以上风险".localized,
            onCancel: { clearPendingMigrationConfirmation() },
            actions: [
                // 仅迁移不授予签名许可；重签名必须勾选确认并绑定当前真实应用。
                WarningAction("data_dir_resign_alert_decline".localized) {
                    pendingMigrationShouldResign = false
                    pendingApprovedSandboxedTarget = nil
                    continuePendingMigrationFlow()
                },
                WarningAction(target.isSandboxed ? "仍然重签名".localized : "data_dir_resign_alert_accept".localized, style: .destructive, requiresAcknowledgement: true) {
                    pendingMigrationShouldResign = true
                    pendingApprovedSandboxedTarget = target.isSandboxed ? target : nil
                    continuePendingMigrationFlow()
                }
            ]
        )
        // 这个弹窗总是紧跟在另一个弹窗之后出现，下一拍再开，避免同一帧内切换 sheet。
        DispatchQueue.main.async {
            self.containerDataResignRequest = request
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
        pendingApprovedSandboxedTarget = nil
    }

    private func performRestore(_ item: DataDirItem) {
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再还原其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在还原「%@」".localized, item.name)
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
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

        Task { @MainActor in
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
            }
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
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performManageExistingLink(_ item: DataDirItem, target: URL) {
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再整理其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = "整理已链接目录".localized
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = item.name
        showProgress = true
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
        Task { @MainActor in
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
            }
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
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再接回其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = "接回外部数据".localized
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = item.name
        showProgress = true
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
        Task { @MainActor in
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
            }
            let mover = DataDirMover()
            do {
                try await mover.createLink(localPath: item.path, externalPath: target,
                    bundleIdentifier: item.associatedBundleIdentifier, appName: item.associatedAppName)
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

    // MARK: - 挂载迁移（沙盒应用容器数据）

    private func askMountMigrate(_ item: DataDirItem) {
        checkMountMigrationDestination(for: item, destination: externalDriveURL)
    }

    private func checkMountMigrationDestination(for item: DataDirItem, destination: URL?) {
        // 直接从下载文件夹或安装包里打开时，macOS 把 AppPorts 放在退出即消失的临时路径上；
        // 登录代理必须指向一个固定的程序，开机后才有人把卷挂回来。
        if ContainerMountAgentInstaller.isRunningFromTemporaryLocation {
            errorMessage = "AppPorts 当前从临时位置运行（直接从下载文件夹或安装包里打开时，macOS 会这样处理）。挂载迁移需要在每次登录后自动重新挂载，请先把 AppPorts 拖到「应用程序」文件夹，再从那里打开。".localized
            showError = true
            return
        }
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再迁移其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        if !skipPermissionCheck && !hasAppManagementPermission() {
            showPermissionAlert = true
            return
        }
        guard !isCheckingMountDestination else { return }
        isCheckingMountDestination = true
        let sourceAppID = selectedApp?.id
        Task { @MainActor in
            // 先只读检查目标盘（格式、加密、空间），再决定给确认框还是给引导。
            let outcome = await MountMigrationPreflight().evaluate(destination: destination, dataBytes: item.sizeBytes)
            isCheckingMountDestination = false
            guard selectedApp?.id == sourceAppID, !operationState.isBusy else { return }
            AppLogger.shared.logContext(
                "挂载迁移前检查目标盘",
                details: [
                    ("item_name", item.name),
                    ("external_root", destination?.path),
                    ("outcome", String(describing: outcome))
                ]
            )
            presentMountMigrationGuidance(for: item, destination: destination, outcome: outcome)
        }
    }

    /// 按检查结果展示确认框或引导。只有「可以迁移」时才有「迁移数据」按钮。
    private func presentMountMigrationGuidance(
        for item: DataDirItem,
        destination: URL?,
        outcome: MountMigrationPreflight.Outcome
    ) {
        let guidance = MountMigrationGuidance.make(
            outcome: outcome,
            appName: selectedApp?.displayName ?? item.name,
            dataSize: item.size,
            sourcePath: item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
            destinationPath: destination?.path
        )
        pendingMountMigrationItem = item
        mountMigrationRequest = WarningSheetRequest(
            title: guidance.title,
            icon: guidance.icon,
            tint: guidance.isReady ? .blue : .orange,
            intro: guidance.intro,
            bullets: guidance.bullets.map { WarningBullet($0.icon, $0.text) },
            detail: guidance.detail,
            cancelTitle: guidance.cancelTitle,
            onCancel: { pendingMountMigrationItem = nil },
            actions: guidance.actions.map { action in
                WarningAction(action.title, style: action.isPrimary ? .preferred : .normal) {
                    pendingMountMigrationItem = nil
                    switch action.kind {
                    case .migrate:
                        performMountMigrate(item)
                    case .chooseDestination:
                        if let chosenDestination = onSelectExternalDrive() {
                            checkMountMigrationDestination(for: item, destination: chosenDestination)
                        }
                    case .openGuide(let page, let anchor):
                        NSWorkspace.shared.open(DocumentationLink.url(page: page, anchor: anchor))
                    case .recheck:
                        askMountMigrate(item)
                    }
                }
            }
        )
    }

    private func performMountMigrate(_ item: DataDirItem) {
        guard let dest = externalDriveURL else { return }
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再迁移其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在挂载迁移「%@」".localized, item.name)
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-container-mount-migrate")
        let capturedApp = selectedApp
        let appName = capturedApp?.displayName ?? item.name
        let bundleID = capturedApp.flatMap { app in
            (try? resolveRealAppURL(app)).flatMap { CodeSigner.bundleIdentifier(at: $0) }
        }
        AppLogger.shared.logContext(
            "用户确认挂载迁移容器数据目录",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("type", item.type.rawValue),
                ("source", item.path.path),
                ("external_root", dest.path)
            ] + appContextFields(for: capturedApp)
        )

        Task { @MainActor in
            // 挂载代理也监听 /Volumes：等它跑完再动手，避免两边抢同一个挂载点。
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                AppLogger.shared.logContext(
                    "容器操作未取得跨进程锁",
                    details: [("item_name", item.name), ("reason", "挂载代理正在运行")]
                )
                errorMessage = "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            if let runningAppName = runningAssociatedAppName(for: item, associatedApp: capturedApp) {
                errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再迁移其数据目录。".localized, runningAppName)
                showError = true
                return
            }
            let migrator = ContainerVolumeMigrator()
            do {
                let result = try await migrator.migrate(
                    item: item,
                    externalRootURL: dest,
                    appName: appName,
                    bundleIdentifier: bundleID
                ) { progress in
                    await MainActor.run {
                        self.progressBytes = progress.copiedBytes
                        self.progressTotalBytes = progress.totalBytes
                        self.progressFileName = progress.currentFile
                    }
                }
                AppLogger.shared.logContext(
                    "挂载迁移成功",
                    details: [("operation_id", operationID), ("item_name", item.name), ("volume", result.record.volumeName)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                    self.presentCleanupWarning(result.cleanupWarning)
                }
            } catch {
                AppLogger.shared.logError(
                    "挂载迁移失败",
                    error: error,
                    errorCode: "CONTAINER-MOUNT-MIGRATE-FAILED",
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("source", item.path)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performMount(_ item: DataDirItem) {
        guard let record = ContainerMountStore.shared.record(forMountPoint: item.path) else {
            errorMessage = "找不到该目录的挂载记录".localized
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在挂载「%@」".localized, item.name)
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = record.volumeName
        showProgress = true
        Task { @MainActor in
            // 挂载代理也监听 /Volumes：等它跑完再动手，避免两边抢同一个挂载点。
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                AppLogger.shared.logContext(
                    "容器操作未取得跨进程锁",
                    details: [("item_name", item.name), ("reason", "挂载代理正在运行")]
                )
                errorMessage = "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            do {
                try await ContainerVolumeMigrator().mount(record: record)
                await MainActor.run { self.reloadCurrentTab() }
            } catch {
                AppLogger.shared.logError(
                    "挂载容器卷失败",
                    error: error,
                    errorCode: "CONTAINER-MOUNT-FAILED",
                    context: [("item_name", item.name), ("volume", record.volumeName)],
                    relatedURLs: [("mount_point", item.path)]
                )
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performUnmount(_ item: DataDirItem) {
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再卸载其数据卷。".localized, runningAppName)
            showError = true
            return
        }
        guard let record = ContainerMountStore.shared.record(forMountPoint: item.path) else {
            errorMessage = "找不到该目录的挂载记录".localized
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在卸载「%@」".localized, item.name)
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = record.volumeName
        showProgress = true
        let capturedApp = selectedApp
        Task { @MainActor in
            // 挂载代理也监听 /Volumes：等它跑完再动手，避免两边抢同一个挂载点。
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                AppLogger.shared.logContext(
                    "容器操作未取得跨进程锁",
                    details: [("item_name", item.name), ("reason", "挂载代理正在运行")]
                )
                errorMessage = "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            if let runningAppName = runningAssociatedAppName(for: item, associatedApp: capturedApp) {
                errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再卸载其数据卷。".localized, runningAppName)
                showError = true
                return
            }
            do {
                try await ContainerVolumeMigrator().unmount(record: record)
                await MainActor.run { self.reloadCurrentTab() }
            } catch {
                AppLogger.shared.logError(
                    "卸载容器卷失败",
                    error: error,
                    errorCode: "CONTAINER-UNMOUNT-FAILED",
                    context: [("item_name", item.name), ("volume", record.volumeName)],
                    relatedURLs: [("mount_point", item.path)]
                )
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func askMountRestore(_ item: DataDirItem) {
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再还原其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let record = ContainerMountStore.shared.record(forMountPoint: item.path) else {
            errorMessage = "找不到该目录的挂载记录".localized
            showError = true
            return
        }

        confirmRequest = makeConfirmRequest(
            title: "还原挂载迁移目录".localized,
            actionTitle: "继续".localized,
            message: String(
                format: "将「%@」还原到本地。\n\n外部来源：%@\n还原到：%@\n\n还原后保留外部原件；验证应用与数据正常后，可在副本管理中校验并清理。".localized,
                item.name,
                record.volumeName,
                item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            ),
            action: { performMountRestore(item, record: record) }
        )
    }

    private func performMountRestore(_ item: DataDirItem, record: ContainerMountRecord) {
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再还原其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在还原「%@」".localized, item.name)
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-container-mount-restore")
        let capturedApp = selectedApp
        AppLogger.shared.logContext(
            "用户确认还原挂载迁移目录",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("mount_point", item.path.path),
                ("volume", record.volumeName)
            ] + appContextFields()
        )

        Task { @MainActor in
            // 挂载代理也监听 /Volumes：等它跑完再动手，避免两边抢同一个挂载点。
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                AppLogger.shared.logContext(
                    "容器操作未取得跨进程锁",
                    details: [("item_name", item.name), ("reason", "挂载代理正在运行")]
                )
                errorMessage = "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            if let runningAppName = runningAssociatedAppName(for: item, associatedApp: capturedApp) {
                errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再还原其数据目录。".localized, runningAppName)
                showError = true
                return
            }
            do {
                let warning = try await ContainerVolumeMigrator().restore(record: record, estimatedTotalBytes: item.sizeBytes) { progress in
                    await MainActor.run {
                        self.progressBytes = progress.copiedBytes
                        self.progressTotalBytes = progress.totalBytes
                        self.progressFileName = progress.currentFile
                    }
                }
                AppLogger.shared.logContext(
                    "挂载迁移目录还原成功",
                    details: [("operation_id", operationID), ("item_name", item.name)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                    self.presentCleanupWarning(warning)
                }
            } catch {
                AppLogger.shared.logError(
                    "挂载迁移目录还原失败",
                    error: error,
                    errorCode: "CONTAINER-MOUNT-RESTORE-FAILED",
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("mount_point", item.path)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func presentCleanupWarning(_ warning: ContainerVolumeMigrator.CleanupWarning?) {
        guard let warning else { return }
        cleanupWarning = warning
        showCleanupWarning = true
    }

    private func cleanupTransfer(_ transfer: DataTransferRecord) {
        guard let token = AppOperationState.shared.begin() else { return }
        showProgress = true
        progressTitle = "校验并清理原件".localized
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        Task { @MainActor in
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(token)
                if lockAcquired { operationLock.release() }
                reloadCurrentTab()
            }
            if !lockAcquired {
                errorMessage = "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            do {
                if transfer.mode == .mount {
                    try await ContainerVolumeMigrator().cleanupRetainedTransfer(operationID: transfer.operationID)
                } else {
                    try await DataDirMover().cleanupRetainedTransfer(operationID: transfer.operationID)
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func presentPendingCleanup(_ cleanup: ContainerCleanupRecord) {
        // 中断的还原仍有暂存副本，不能把它当成已完成后仅需删卷的记录。
        if let staging = cleanup.restoreStagingPath,
           FileManager.default.fileExists(atPath: staging) {
            errorMessage = String(
                format: "还原未完成，已复制的本地数据保留在「%@」，外置卷也已保留。请检查迁移记录和挂载状态后重试。%@".localized,
                staging, ""
            )
            showError = true
            return
        }
        let warning = cleanupWarning?.cleanup.id == cleanup.id
            ? cleanupWarning
            : ContainerVolumeMigrator.CleanupWarning(cleanup: cleanup, details: "")
        presentCleanupWarning(warning)
    }

    private func retryCleanup(_ warning: ContainerVolumeMigrator.CleanupWarning) {
        guard let token = AppOperationState.shared.begin() else { return }
        showProgress = true
        progressTitle = "重试清理".localized
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        Task { @MainActor in
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(token)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                errorMessage = "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            let nextWarning = await ContainerVolumeMigrator().retryCleanup(warning)
            reloadCurrentTab()
            cleanupWarning = nextWarning
            presentCleanupWarning(nextWarning)
        }
    }

    private func confirmDiscardCleanupRecord(_ cleanup: ContainerCleanupRecord) {
        DispatchQueue.main.async {
            confirmRequest = makeConfirmRequest(
                title: "仅移除清理记录".localized,
                actionTitle: "确认".localized,
                message: "仅移除这条清理记录，不会删除本地备份或外置卷，也不会重新挂载。若副本仍存在，需要你自行清理。确定继续吗？".localized,
                action: { discardCleanupRecord(cleanup) }
            )
        }
    }

    private func discardCleanupRecord(_ cleanup: ContainerCleanupRecord) {
        guard let token = AppOperationState.shared.begin() else { return }
        Task { @MainActor in
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                AppOperationState.shared.finish(token)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                errorMessage = "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            do {
                try await ContainerVolumeMigrator().discardCleanupRecord(cleanup)
                cleanupWarning = nil
                reloadCurrentTab()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
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
        managedLinkNormalizationRequest = nil
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
    private func runningAssociatedAppName(for item: DataDirItem, associatedApp: AppItem? = nil) -> String? {
        let runningApps = NSWorkspace.shared.runningApplications.map {
            AppRunningState.RunningApplication(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
        }

        // 已迁移应用的本地路径可能是 Stub，运行进程使用真实外部路径和原始 Bundle ID。
        if let app = associatedApp ?? (selectedTab == .appDirs ? selectedApp : nil) {
            if AppRunningState.isRunning(appURL: app.displayURL, applications: runningApps) {
                AppLogger.shared.logContext(
                    "拒绝操作：关联应用正在运行",
                    details: [("app_name", app.displayName), ("app_path", app.displayURL.path), ("item_name", item.name)],
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

    // MARK: - 日志辅助

    /// 构建关联应用的背景信息字段，供各操作日志复用
    private func appContextFields(for explicitApp: AppItem? = nil) -> [(String, String?)] {
        guard let app = explicitApp ?? selectedApp else { return [] }
        let realURL = (try? resolveRealAppURL(app)) ?? app.displayURL
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(url: app.displayURL, size: 32)

            Text(app.displayName)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundColor(.primary)
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
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : (isHovered ? Color.primary.opacity(0.04) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
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
        totalBytes > 0 ? min(Double(copiedBytes) / Double(totalBytes), 1) : 0
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            ProgressView(value: totalBytes > 0 ? progress : nil)
                .progressViewStyle(.linear)
                .frame(width: 280)

            HStack {
                Text(formatBytes(copiedBytes))
                if totalBytes > 0 {
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                    Spacer()
                    Text(formatBytes(totalBytes))
                }
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
