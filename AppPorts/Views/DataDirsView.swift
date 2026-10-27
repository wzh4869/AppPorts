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
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var languageManager = LanguageManager.shared
    @ObservedObject private var operationState = AppOperationState.shared

    // MARK: - 外部依赖
    var isActive: Bool = true
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
    /// 本地应用列表是否仍在扫描；用于区分“还没扫完”和“扫完了确实没有”。
    var isScanningApps: Bool = false
    /// 经典数据迁移模式生效：容器目录允许符号链接迁移，沙盒应用允许重签名。
    let classicModeActive: Bool
    /// 父级工具栏触发刷新时递增。
    let refreshTrigger: Int
    /// 选择外部存储路径的回调
    let onSelectExternalDrive: () -> URL?
    /// 打开签名修复面板
    var onRepairSignature: ((AppItem) -> Void)? = nil
    /// 独立手动重签，不与迁移组成一个操作。
    let onResignApp: ((AppItem) -> Void)?
    /// 解析应用真实路径（已链接→外部，未链接→本地），不返回假壳路径
    let resolveRealAppURL: (AppItem) throws -> URL

    private struct EncryptedMigrationRequest: Identifiable {
        let id = UUID()
        let item: DataDirItem
        var volumeUUID: String? = nil
        var retryToken: MigrationJob.RetryToken? = nil
        var retry: (() -> Void)? = nil
    }
    @State private var encryptedMigrationRequest: EncryptedMigrationRequest?

    // MARK: - 内部状态
    @State private var weChatPreferenceRevision = 0
    @State private var weChatContainerIdentifier = PartialWeChatMigrationPolicy.bundleIdentifier
    @State private var weChatMigrationItem: DataDirItem?
    @State private var weChatMigrationMode: WeChatAccountMigrationService.Mode = .whole
    @State private var dotFolderItems: [DataDirItem] = []
    @State private var toolSizeCacheUpdatedAt: Date?
    @State private var libraryItems:   [DataDirItem] = []
    @State private var appDataScanCache = AppDataScanCache()
    @State private var appDataPermissionIncomplete = false
    @State private var migratedAppDataIDs: Set<String> = []
    @State private var directoryRevealRequest: DataDirTree.RevealRequest?
    @State private var summaryFilter: DataDirTree.SummaryFilter?
    @State private var dotFolderReadIssues: [DataDirReadIssue] = []
    @State private var libraryReadIssues: [DataDirReadIssue] = []
    @State private var libraryIdentityIssue: AppIdentityIssue?
    @State private var selectedAppIsWeChat = false
    @State private var showReadinessCheck = false
    @AppStorage("showZeroByteDataDirectories") private var showZeroByteDirectories = false
    @AppStorage("showLockedAppDataDirectoryStructure") private var showLockedDirectoryStructure = false
    @AppStorage("showNonMigratableAppDataDirectories") private var showNonMigratableDirectories = false
    @AppStorage("showNonMigratableToolDirectories") private var showNonMigratableToolDirectories = false

    @State private var showAppDataFilters = false
    @State private var selectedPriorityFilters: Set<DataDirPriority> = []
    @State private var selectedStatusFilters: Set<String> = []
    @State private var selectedTypeFilters: Set<DataDirType> = []
    @State private var selectedAppDataSortMode: AppDataSortMode = .defaultOrder

    // 确认弹窗
    @State private var confirmRequest: WarningSheetRequest?
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
    @State private var preservedMaterials: [DataTransferMaterial] = []
    @State private var cleanupWarning: ContainerVolumeMigrator.CleanupWarning?
    @State private var showCleanupWarning = false
    @State private var showCleanupResolution = false
    @State private var dataCompletionWarning = ""
    @State private var showDataCompletionWarning = false

    // 错误弹窗
    @State private var showError = false
    @State private var errorMessage = ""

    // 选中项（用于高亮）
    @State private var selectedItemID: String? = nil
    @State private var dotFolderScanToken = UUID()
    @State private var libraryScanToken = UUID()
    @State private var directoryScanTask: Task<Void, Never>?
    @State private var hasLoadedDirectories = false
    @State private var recordRefreshTask: Task<Void, Never>?
    @State private var recordRefreshToken = UUID()

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

    private let appDataStatusOrder = ["本地", "已链接", "已挂载", "待挂载", "等待解锁", "卷丢失", "待规范", "现有软链", "用户目录入口", "待接回", "待完成", "未找到"]

    private var partialWeChatMigrationEnabled: Bool {
        _ = weChatPreferenceRevision
        return selectedApp.map { MigrationPreferences.isPartialWeChatMigrationEnabled(for: $0.path) } ?? false
    }

    private var selectedWeChatPolicy: PartialWeChatMigrationPolicy {
        PartialWeChatMigrationPolicy(containerIdentifier: weChatContainerIdentifier)
    }

    private var partialWeChatMigrationBinding: Binding<Bool> {
        Binding(get: { partialWeChatMigrationEnabled }, set: { enabled in
            guard let app = selectedApp else { return }
            MigrationPreferences.setPartialWeChatMigrationEnabled(enabled, for: app.path)
            weChatPreferenceRevision += 1
            clearAppDataFilters()
            directorySearchText = ""
            clearSizeCache()
            scanLibraryDirs(for: app)
        })
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if selectedTab == .appDirs && (dataTransfers.contains(where: { $0.needsAttention }) || !pendingCleanups.isEmpty || !preservedMaterials.isEmpty) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("部分数据操作尚未完成，已保留副本。".localized)
                        if let reason = dataTransfers.filter({ $0.needsAttention }).compactMap(\.recoverableReason).first ?? preservedMaterials.first?.reason {
                            Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).help(reason)
                        }
                    }
                    Spacer()
                    Button("处理异常".localized) { showCleanupResolution = true }
                }
                .padding(12)
            }
            if selectedTab == .appDirs && dataTransfers.contains(where: { $0.cleanupDisposition == .keep }) {
                HStack {
                    Text("已保留旧副本".localized).foregroundStyle(.secondary)
                    Spacer()
                    Button("查看旧副本".localized) { showCleanupResolution = true }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            // ── 主内容区 ────────────────────────────────────────
            ZStack(alignment: .topLeading) {
                if selectedTab == .toolDirs {
                    toolDirsContent
                        .transaction { $0.animation = nil }
                        .transition(reduceMotion ? .identity : AppMotion.pageTransition)
                } else {
                    appDirsContent
                        .transaction { $0.animation = nil }
                        .transition(reduceMotion ? .identity : AppMotion.pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : AppMotion.page, value: selectedTab)
        }
        .disabled(operationState.blocksInteraction)
        .onAppear {
            guard !hasLoadedDirectories else { return }
            hasLoadedDirectories = true
            reloadCurrentTab(useCachedAppData: true)
        }
        .onChange(of: selectedTab) { _ in
            directoryRevealRequest = nil
            summaryFilter = nil
            reloadCurrentTab(useCachedAppData: true)
        }
        .onDisappear {
            suspendDirectoryScans()
        }
        .onChange(of: isActive) { active in
            if active {
                hasLoadedDirectories = true
                reloadCurrentTab(useCachedAppData: true)
            } else {
                suspendDirectoryScans()
            }
        }
        .onChange(of: operationState.recordsRevision) { _ in
            appDataScanCache.removeAll()
            if isActive, selectedTab == .appDirs { reloadCurrentTab() }
        }
        .onChange(of: externalDriveURL) { _ in
            appDataScanCache.removeAll()
            reloadCurrentTab()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            appDataScanCache.removeAll()
            if isActive, selectedTab == .appDirs { reloadCurrentTab() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            appDataScanCache.removeAll()
            if isActive, selectedTab == .appDirs { reloadCurrentTab() }
        }
        .onChange(of: refreshTrigger) { _ in
            appDataScanCache.removeAll()
            clearSizeCache()
            reloadCurrentTab(forceToolSizeRefresh: true)
        }
        .sheet(item: $weChatMigrationItem) { item in
            WeChatAccountMigrationSheet(item: item, containerIdentifier: weChatContainerIdentifier) { mode in
                weChatMigrationItem = nil
                weChatMigrationMode = mode
                checkMountMigrationDestination(for: item, destination: externalDriveURL)
            }
        }
        .sheet(item: $encryptedMigrationRequest) { request in
            APFSVolumePasswordSheet(isCreating: request.volumeUUID == nil) { credentials in
                let isCurrent = { request.retryToken.map { MigrationTaskCenter.shared.canRetry($0) } ?? true }
                guard isCurrent() else { encryptedMigrationRequest = nil; return }
                if let uuid = request.volumeUUID {
                    let inspection = try ContainerMountStore.shared.recordsForInspection()
                    if let error = inspection.validationError { throw error }
                    let records = inspection.mounts + inspection.transfers.compactMap(\.recoveryMountRecord)
                    guard records.contains(where: { $0.volumeUUID.caseInsensitiveCompare(uuid) == .orderedSame }) else {
                        throw DataOperationSafety.Failure.conflict(request.item.path.path)
                    }
                    // Recovery records can also refer to already removed sibling volumes.
                    // Unlock only the UUID that blocked this operation; retry checks any remaining member.
                    let disk = DiskUtility()
                    let info = try await disk.volumeInfo(for: uuid)
                    guard isCurrent() else { encryptedMigrationRequest = nil; return }
                    if info.isLocked { try await disk.unlockVolume(uuid, passphrase: credentials.passphrase) }
                    else { try await disk.verifyPassphrase(uuid, passphrase: credentials.passphrase) }
                    guard isCurrent() else { encryptedMigrationRequest = nil; return }
                    try APFSVolumeEncryption.save(credentials, for: uuid)
                    // Split members normally share a password. Verify each online sibling before caching it.
                    let memberPaths = Set(request.item.weChatSplitMembers.map { $0.path.standardizedFileURL.path })
                    let siblings = Set(records.filter { memberPaths.contains($0.mountPointPath) }.map(\.volumeUUID))
                    for sibling in siblings where sibling.caseInsensitiveCompare(uuid) != .orderedSame {
                        guard let siblingInfo = try? await disk.volumeInfo(for: sibling), siblingInfo.isEncrypted else { continue }
                        guard isCurrent() else { encryptedMigrationRequest = nil; return }
                        do {
                            if siblingInfo.isLocked { try await disk.unlockVolume(sibling, passphrase: credentials.passphrase) }
                            else { try await disk.verifyPassphrase(sibling, passphrase: credentials.passphrase) }
                        } catch APFSVolumeEncryption.Failure.commandFailed {
                            // Older members may use a different password; ask only if the retry needs that volume.
                            continue
                        }
                        guard isCurrent() else { encryptedMigrationRequest = nil; return }
                        try APFSVolumeEncryption.save(credentials, for: sibling)
                    }
                    encryptedMigrationRequest = nil
                    DispatchQueue.main.async { request.retry?() }
                } else {
                    encryptedMigrationRequest = nil
                    DispatchQueue.main.async { performMountMigrate(request.item, encryption: credentials) }
                }
            }
        }
        // 确认弹窗
        .warningSheet($confirmRequest)
        .warningSheet($managedLinkNormalizationRequest)
        .warningSheet($migrationRiskRequest)
        .warningSheet($mountMigrationRequest)
        .sheet(isPresented: $showReadinessCheck, onDismiss: {
            if appDataPermissionIncomplete, let app = selectedApp { scanLibraryDirs(for: app) }
        }) {
            ReadinessCheckSheet()
        }
        .sheet(isPresented: $showCleanupResolution) {
            DataCleanupResolutionSheet(transfers: dataTransfers,
                otherIssues: pendingCleanups.map { $0.mountRecord.appName + ": " + $0.localPath }
                    + preservedMaterials.map { $0.appName + ": " + $0.reason },
                onRetry: { id in
                    DispatchQueue.main.async { retryPendingOperations(operationID: id) }
                }, onChanged: { refreshOperationRecords() }, onPermissions: {
                    DispatchQueue.main.async { showReadinessCheck = true }
                })
        }
        // 错误弹窗
        .alert("操作失败".localized, isPresented: $showError) {
            Button("好的".localized, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("操作尚未完成".localized, isPresented: $showDataCompletionWarning) {
            Button("处理异常".localized) { refreshOperationRecords(); showCleanupResolution = true }
            Button("稍后".localized, role: .cancel) {}
        } message: {
            Text(dataCompletionWarning)
        }
        .alert("操作尚未完成".localized, isPresented: $showCleanupWarning) {
            Button("处理异常".localized) { refreshOperationRecords(); showCleanupResolution = true }
            Button("稍后".localized, role: .cancel) {}
        } message: {
            Text(cleanupWarning?.message ?? "")
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
                        .padding(.vertical, 4)
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
                    if isScanningApps {
                        ContentView.EmptyStateView(icon: "magnifyingglass", text: "正在扫描...".localized)
                    } else {
                        ContentView.EmptyStateView(icon: "app.dashed", text: "无本地应用".localized)
                    }
                } else {
                    let filteredApps = localApps.filter { app in
                        !app.isFolder && (appSearchText.isEmpty || app.displayName.localizedCaseInsensitiveContains(appSearchText) || app.name.localizedCaseInsensitiveContains(appSearchText))
                    }
                    let orderedApps = filteredApps.filter { migratedAppDataIDs.contains($0.id) }
                        + filteredApps.filter { !migratedAppDataIDs.contains($0.id) }
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(orderedApps, id: \.id) { app in
                                Button {
                                    selectedApp = app
                                } label: {
                                    AppListRow(app: app, isSelected: selectedApp?.id == app.id, hasMigratedData: migratedAppDataIDs.contains(app.id))
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
            .frame(maxHeight: .infinity, alignment: .top)
            .onChange(of: selectedApp?.path) { _ in
                selectedAppIsWeChat = false
                directorySearchText = ""
                directoryRevealRequest = nil
                summaryFilter = nil
                if let app = selectedApp { scanLibraryDirs(for: app) }
                else {
                    directoryScanTask?.cancel()
                    libraryScanToken = UUID()
                    libraryItems = []
                    libraryReadIssues = []
                    libraryIdentityIssue = nil
                    selectedAppIsSandboxed = false
                    isScanning = false
                }
            }
            .onChange(of: localApps) { newApps in
                // 重签名/迁移后刷新 selectedApp，避免持有旧的 isResigned 等字段
                // 更新应用展示信息和迁移标记，不因后台列表更新重新扫描数据目录。
                refreshOperationRecords()
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
                        } else if isScanningApps {
                            Text("正在扫描...".localized)
                        } else {
                            Text("请从左侧选择应用".localized)
                        }
                        if selectedAppIsWeChat {
                            Toggle("微信账号拆分迁移".localized, isOn: partialWeChatMigrationBinding)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(.system(size: 12))
                                .fixedSize()
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
                                    items: summaryBaseLibraryItems,
                                    allItems: libraryItems,
                                    readIssues: libraryReadIssues,
                                    hasIdentityIssue: libraryIdentityIssue != nil,
                                    displayedItems: filteredLibraryItems,
                                    onSelectSummary: selectSummaryFilter
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
                        if isScanningApps {
                            ContentView.EmptyStateView(icon: "magnifyingglass", text: "正在扫描...".localized)
                        } else {
                            ContentView.EmptyStateView(icon: "arrow.left.circle", text: "从左侧选择一个应用".localized)
                        }
                    } else if appDataPermissionIncomplete {
                        VStack(spacing: 12) {
                            Text("权限不完整".localized)
                                .foregroundColor(.secondary)
                            Button("检查访问权限".localized) { showReadinessCheck = true }
                                .buttonStyle(.bordered)
                        }
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
                            revealRequest: directoryRevealRequest,
                            actions: directoryOperationButtons
                        )
                    }
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .padding(.top, 0)
        .padding(.bottom, 12)
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
            Text(String(format: "显示 %lld / %lld".localized, Int64(visibleLibraryItemCount), Int64(libraryItems.count)))
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
                Text(String(format: "显示 %lld / %lld".localized, Int64(visibleLibraryItemCount), Int64(libraryItems.count)))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                statsSummary(items: items, allItems: dotFolderItems, readIssues: dotFolderReadIssues)
                zeroByteDirectoriesToggle
                Toggle("显示不可迁移目录".localized, isOn: $showNonMigratableToolDirectories)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .fixedSize()
            }
            if !dotFolderReadIssues.isEmpty {
                directoryReadWarning(issues: dotFolderReadIssues)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var appDataVisibilityToggles: some View {
        AppDataVisibilityControls(showZeroByteDirectories: $showZeroByteDirectories,
                                  showLockedStructure: $showLockedDirectoryStructure,
                                  showNonMigratableDirectories: $showNonMigratableDirectories)
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
                .help(issues.map {
                    $0.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + "\n" + $0.errorDescription
                }.joined(separator: "\n\n"))
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
        items: [DataDirItem], allItems: [DataDirItem], readIssues: [DataDirReadIssue], hasIdentityIssue: Bool = false,
        displayedItems: [DataDirItem]? = nil,
        onSelectSummary: ((DataDirTree.SummaryFilter) -> Void)? = nil
    ) -> some View {
        let visibleItems = displayedItems ?? items
        let summary = DataDirSpaceSummary(
            items: visibleItems, allItems: allItems, hasReadIssues: !readIssues.isEmpty, hasIdentityIssue: hasIdentityIssue
        )
        let totalSize = DataDirDisplaySizeSummary(items: allItems,
            hasReadIssues: !readIssues.isEmpty || hasIdentityIssue)
        let visibleSize = DataDirDisplaySizeSummary(items: visibleItems)
        let linked = items.filter { $0.status == "已链接" }.count
        let mounted = items.filter { DataDirStatus.mountStatuses.contains($0.status) }.count
        let needsNormalization = items.filter { $0.status == "待规范" }.count
        let existingSymlinks = items.filter { $0.status == "现有软链" && !$0.isUserDirectoryLink }.count
        let relinkable = items.filter { $0.status == "待接回" }.count
        return HStack(spacing: 14) {
            if displayedItems != nil {
                Text("应用数据：".localized + totalSize.sizeText)
                    .foregroundColor(totalSize.isIncomplete ? .orange : .secondary)
                Label(String(format: "%lld 个目录".localized, Int64(visibleItems.count)), systemImage: "folder.fill")
                    .foregroundColor(.secondary)
                Text("目录大小：".localized + visibleSize.sizeText)
                    .foregroundColor(visibleSize.isIncomplete ? .orange : .accentColor)
            } else {
                Label(String(format: "%lld 个目录".localized, Int64(visibleItems.count)), systemImage: "folder.fill")
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
            }
            if linked > 0 {
                summaryNavigationLabel(String(format: "%lld 个已链接".localized, Int64(linked)),
                    systemImage: "link.circle.fill", color: .green,
                    filter: .linked, onSelect: onSelectSummary)
            }
            if mounted > 0 {
                summaryNavigationLabel(String(format: "%lld 个挂载迁移".localized, Int64(mounted)),
                    systemImage: "externaldrive.fill.badge.checkmark", color: .purple,
                    filter: .mounted, onSelect: onSelectSummary)
            }
            if needsNormalization > 0 {
                Label(String(format: "%lld 个待整理".localized, Int64(needsNormalization)), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.mint)
            }
            if existingSymlinks > 0 {
                summaryNavigationLabel(String(format: "%lld 个现有软链".localized, Int64(existingSymlinks)),
                    systemImage: "questionmark.circle", color: .teal,
                    filter: .existingSymlink, onSelect: onSelectSummary)
            }
            if relinkable > 0 {
                Label(String(format: "%lld 个待接回".localized, Int64(relinkable)), systemImage: "arrow.triangle.branch")
                    .foregroundColor(.indigo)
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func summaryNavigationLabel(_ title: String, systemImage: String, color: Color,
                                        filter: DataDirTree.SummaryFilter, onSelect: ((DataDirTree.SummaryFilter) -> Void)?) -> some View {
        if let onSelect {
            Button { onSelect(filter) } label: {
                Label(title, systemImage: systemImage)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(summaryFilter == filter ? 0.16 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(color)
        } else {
            Label(title, systemImage: systemImage).foregroundColor(color)
        }
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
            onMount: { performMount($0) },
            onUnmount: performUnmount,
            onMountRestore: askMountRestore,
            classicModeActive: classicModeActive,
            inline: true
        )
    }

    private func selectSummaryFilter(_ filter: DataDirTree.SummaryFilter) {
        summaryFilter = summaryFilter == filter ? nil : filter
        directoryRevealRequest = summaryFilter.map { selected in
            .init(itemIDs: Set(summaryBaseLibraryItems.filter { selected.matches($0) }.map(\.id)))
        }
    }

    private var summaryBaseLibraryItems: [DataDirItem] {
        libraryItems.filter(matchesAppDataFilters)
    }

    private var filteredLibraryItems: [DataDirItem] {
        summaryBaseLibraryItems.filter { summaryFilter?.matches($0) ?? true }
    }

    private var filteredDotFolderItems: [DataDirItem] {
        dotFolderItems.filter {
            (showNonMigratableToolDirectories || !$0.isMigrationUnsupported)
                && (showZeroByteDirectories || !$0.isEmptyLocalDirectory)
        }
    }

    /// 链接状态优先级：已链接、挂载迁移、待规范、现有软链优先展示
    private let statusPriority: [String] = ["已链接", "已挂载", "待挂载", "等待解锁", "卷丢失", "待规范", "现有软链", "用户目录入口", "待接回", "本地", "未找到"]

    private func statusSortKey(_ status: String) -> Int {
        statusPriority.firstIndex(of: status) ?? statusPriority.count
    }

    private var sortedFilteredLibraryItems: [DataDirItem] {
        sortedLibraryItems.filter { matchesAppDataFilters($0) && (summaryFilter?.matches($0) ?? true) }
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
            let tree = summaryFilter.map { filter in
                DataDirTree.summaryTree(from: items.filter { matchingIDs.contains($0.id) }, filter: filter)
            } ?? DataDirTree.visibleTree(from: items,
                                              showZeroByteDirectories: showZeroByteDirectories,
                                              showLockedStructure: showLockedDirectoryStructure,
                                              matchingIDs: matchingIDs,
                                              showNonMigratableDirectories: showNonMigratableDirectories)
            return tree.isEmpty ? nil : DataDirGroup(type: type, items: tree)
        }
    }

    private var visibleLibraryItemCount: Int {
        groupedLibraryItems.reduce(0) { count, group in
            count + DataDirTree.rows(in: group.items).count
        }
    }

    private var hasActiveAppDataFilters: Bool {
        summaryFilter != nil || !selectedPriorityFilters.isEmpty || !selectedStatusFilters.isEmpty || !selectedTypeFilters.isEmpty
    }

    private var activeAppDataFilterCount: Int {
        selectedPriorityFilters.count + selectedStatusFilters.count + selectedTypeFilters.count + (summaryFilter == nil ? 0 : 1)
    }

    private var activeAppDataFilterLabels: [String] {
        var labels: [String] = []
        if let summaryFilter {
            switch summaryFilter {
            case .linked: labels.append("已链接".localized)
            case .mounted: labels.append("挂载迁移".localized)
            case .existingSymlink: labels.append("现有软链".localized)
            }
        }
        labels.append(contentsOf: DataDirPriority.allCases.filter(selectedPriorityFilters.contains).map(\.localizedTitle))
        labels.append(contentsOf: appDataStatusOrder.filter(selectedStatusFilters.contains).map(DataDirStatus.localized))
        labels.append(contentsOf: appDataFilterTypes.filter(selectedTypeFilters.contains).map(\.localizedTitle))
        return labels
    }

    private var appDataFilterTypes: [DataDirType] {
        DataDirType.allCases.filter { $0 != .dotFolder }
    }

    private func matchesAppDataFilters(_ item: DataDirItem) -> Bool {
        if selectedAppIsWeChat, partialWeChatMigrationEnabled,
           !selectedWeChatPolicy.isAccount(item.path) { return false }
        let query = directorySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesSearch = query.isEmpty || item.path.path.localizedStandardContains(query)
            || item.name.localizedStandardContains(query) || item.description.localizedStandardContains(query)
        return matchesSearch && (selectedPriorityFilters.isEmpty || selectedPriorityFilters.contains(item.priority))
            && (selectedStatusFilters.isEmpty || selectedStatusFilters.contains(item.displayedStatus))
            && (selectedTypeFilters.isEmpty || selectedTypeFilters.contains(item.type))
            && item.matchesVisibility(showZeroByteDirectories: showZeroByteDirectories,
                                      showNonMigratableDirectories: showNonMigratableDirectories)
    }

    private func clearAppDataFilters() {
        summaryFilter = nil
        directoryRevealRequest = nil
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

    private func refreshOperationRecords() {
        guard isActive else { return }
        recordRefreshTask?.cancel()
        let token = UUID()
        recordRefreshToken = token
        let apps = localApps
        recordRefreshTask = Task.detached(priority: .utility) {
            do {
                // 迁移记录含大目录的校验清单，解析和等待记录锁不能占用主线程。
                let inspection = try ContainerMountStore.shared.recordsForInspection()
                // 使用持久化的数据迁移记录，不扫描各应用目录，也不把应用本体迁移当作数据迁移。
                let identifiers = Set(inspection.mounts.compactMap(\.bundleIdentifier)
                    + inspection.managedLinks.compactMap(\.bundleIdentifier))
                var migratedIDs: Set<String> = []
                if !identifiers.isEmpty {
                    for app in apps where !app.isFolder {
                        guard !Task.isCancelled else { return }
                        if let identifier = CodeSigner.bundleIdentifier(at: app.displayURL), identifiers.contains(identifier) {
                            migratedIDs.insert(app.id)
                        }
                    }
                }
                let migratedSnapshot = migratedIDs
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.recordRefreshToken == token else { return }
                    self.migratedAppDataIDs = migratedSnapshot
                    self.dataTransfers = inspection.transfers
                    self.preservedMaterials = inspection.preservedMaterials
                    self.pendingCleanups = inspection.cleanups
                    if let error = inspection.validationError {
                        self.errorMessage = error.localizedDescription
                        self.showError = true
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.recordRefreshToken == token else { return }
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func suspendDirectoryScans() {
        recordRefreshTask?.cancel()
        recordRefreshToken = UUID()
        if isScanning { hasLoadedDirectories = false }
        directoryScanTask?.cancel()
        dotFolderScanToken = UUID()
        libraryScanToken = UUID()
        isScanning = false
    }

    private func reloadCurrentTab(forceToolSizeRefresh: Bool = false, useCachedAppData: Bool = false) {
        guard isActive else { return }
        if selectedTab == .appDirs {
            refreshOperationRecords()
        } else {
            recordRefreshTask?.cancel()
            recordRefreshToken = UUID()
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
            scanDotFolders(forceSizeRefresh: forceToolSizeRefresh)
        } else {
            dotFolderScanToken = UUID()
            if let app = selectedApp {
                scanLibraryDirs(for: app, useCachedResult: useCachedAppData, forceSizeRefresh: forceToolSizeRefresh)
            } else {
                isScanning = false
            }
        }
    }

    private func scanDotFolders(forceSizeRefresh: Bool = false) {
        guard isActive else { return }
        directoryScanTask?.cancel()
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
        directoryScanTask = Task.detached(priority: .userInitiated) {
            let scanner = DataDirScanner()
            let items = await scanner.scanKnownDotFolders(externalRootURL: selectedExternalRoot)
            guard !Task.isCancelled else { return }
            var snapshot = ToolDirectorySizeCacheStore.shared.load()
            let identities = items.map { ToolDirectorySizeCacheStore.identity(for: $0) }
            var initialItems = items
            var missingIndices: [Int] = []
            for i in items.indices {
                let key = items[i].path.standardizedFileURL.path
                if !forceSizeRefresh, let identity = identities[i],
                   let cached = snapshot.entries[key], cached.identity == identity {
                    initialItems[i].applySize(DirectorySizeResult(bytes: cached.bytes))
                } else {
                    snapshot.entries.removeValue(forKey: key)
                    missingIndices.append(i)
                }
            }
            let displayedItems = initialItems
            let pendingIndices = missingIndices
            let previousCacheTime = snapshot.updatedAt
            await MainActor.run {
                guard self.dotFolderScanToken == scanToken else { return }
                self.dotFolderItems = displayedItems
                self.toolSizeCacheUpdatedAt = previousCacheTime
            }
            AppLogger.shared.logContext(
                "工具目录扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("count", String(items.count)),
                    ("statuses", Dictionary(grouping: items, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
                ]
            )

            guard !Task.isCancelled else { return }
            // 只测量缓存缺失或用户要求刷新的目录；目录状态仍每次重新检查。
            let sizedItems = await withTaskGroup(of: (Int, DirectorySizeResult).self) { group in
                var results: [(Int, DirectorySizeResult)] = []
                var iterator = pendingIndices.makeIterator()
                var active = 0
                let maxConcurrency = 4

                // 启动初始批次
                for _ in 0..<min(maxConcurrency, pendingIndices.count) {
                    guard let i = iterator.next() else { break }
                    let measuredItem = items[i]
                    group.addTask { (i, measureDataDirectorySize(for: measuredItem)) }
                    active += 1
                }

                // 每完成一个再启动一个
                for await result in group {
                    results.append(result)
                    active -= 1
                    if !Task.isCancelled, let i = iterator.next() {
                        let measuredItem = items[i]
                        group.addTask { (i, measureDataDirectorySize(for: measuredItem)) }
                        active += 1
                    }
                }
                return results
            }

            guard !Task.isCancelled else { return }
            for (i, result) in sizedItems {
                guard result.isComplete, let identity = identities[i],
                      identity == ToolDirectorySizeCacheStore.identity(for: items[i]),
                      let target = items[i].sizeMeasurementURL else { continue }
                let path = items[i].path.standardizedFileURL.path
                snapshot.entries[path] = .init(identity: identity, sourcePath: path,
                    targetPath: target.resolvingSymlinksInPath().standardizedFileURL.path,
                    bytes: result.bytes, measuredAt: Date())
            }
            let completedSnapshot = snapshot
            await MainActor.run {
                guard self.dotFolderScanToken == scanToken else { return }
                if !pendingIndices.isEmpty { ToolDirectorySizeCacheStore.shared.save(completedSnapshot) }
                self.toolSizeCacheUpdatedAt = completedSnapshot.updatedAt
                for (i, result) in sizedItems {
                    guard i < self.dotFolderItems.count else { continue }
                    self.dotFolderItems[i].applySize(result)
                    self.dotFolderReadIssues.append(contentsOf: result.readIssues)
                }
                self.isScanning = false
            }
        }
    }

    private func applyAppDataSnapshot(_ snapshot: AppDataScanCache.Snapshot) {
        libraryItems = snapshot.items
        libraryReadIssues = snapshot.readIssues
        libraryIdentityIssue = snapshot.identityIssue
        selectedAppIsSandboxed = snapshot.isSandboxed
        selectedAppIsWeChat = snapshot.isWeChat
        weChatContainerIdentifier = snapshot.containerIdentifier
        appDataPermissionIncomplete = false
    }

    private func scanLibraryDirs(for app: AppItem, useCachedResult: Bool = true,
                                 forceSizeRefresh: Bool = false,
                                 completion: (([DataDirItem]) -> Void)? = nil) {
        guard isActive else { return }
        directoryScanTask?.cancel()
        let scanToken = UUID()
        libraryScanToken = scanToken
        isScanning = true
        appDataPermissionIncomplete = false
        libraryItems = []
        libraryReadIssues = []
        libraryIdentityIssue = nil
        let context = AppDataScanCache.Context(app: app, externalRoot: externalDriveURL,
            splitMode: MigrationPreferences.isPartialWeChatMigrationEnabled(for: app.path),
            recordsRevision: operationState.recordsRevision)
        directoryScanTask = Task.detached(priority: .userInitiated) {
            // Probe the current process before reading any protected app data, even on cache hits.
            let permission = LaunchReadinessChecker.fullDiskAccessState()
            guard !Task.isCancelled else { return }
            guard permission == .granted else {
                await MainActor.run {
                    guard self.libraryScanToken == scanToken else { return }
                    self.appDataScanCache.removeAll()
                    self.appDataPermissionIncomplete = true
                    self.isScanning = false
                    AppLogger.shared.log("应用数据扫描已停止：读取权限未就绪", level: "WARN")
                }
                return
            }
            let cached = await MainActor.run {
                useCachedResult && !forceSizeRefresh
                    ? self.appDataScanCache.snapshot(for: context, permission: permission) : nil
            }
            if let cached {
                await MainActor.run {
                    guard self.libraryScanToken == scanToken else { return }
                    self.applyAppDataSnapshot(cached)
                    self.isScanning = false
                    AppLogger.shared.logContext("应用数据扫描使用缓存", details: [("app_name", app.displayName)])
                    completion?(cached.items)
                }
                return
            }
            AppLogger.shared.logContext("开始扫描应用数据目录", details: [("app_name", app.displayName)])
            let matchesWeChatName = app.displayName.localizedCaseInsensitiveContains("wechat")
            let isWeChat: Bool
            let containerIdentifier: String
            if case .success(let identity) = AppIdentityResolver.resolve(at: app.displayURL) {
                isWeChat = matchesWeChatName || identity.bundleIdentifier == PartialWeChatMigrationPolicy.bundleIdentifier
                containerIdentifier = isWeChat ? identity.bundleIdentifier : PartialWeChatMigrationPolicy.bundleIdentifier
            } else {
                isWeChat = matchesWeChatName
                containerIdentifier = PartialWeChatMigrationPolicy.bundleIdentifier
            }
            let scanner = DataDirScanner(partialWeChatMigrationEnabled: context.splitMode && isWeChat,
                                         weChatContainerIdentifier: containerIdentifier)
            let isSandboxed = await scanner.isSandboxed(app)
            guard !Task.isCancelled else { return }
            let result = await scanner.scanLibraryDirsWithDiagnostics(for: app, externalRootURL: context.externalRoot)
            guard !Task.isCancelled else { return }
            let items = WeChatAccountMigrationService.groupedItems(result.items, splitMode: context.splitMode && isWeChat,
                                                                   containerIdentifier: containerIdentifier)
            var snapshot = AppDataScanCache.Snapshot(context: context, items: items,
                readIssues: result.readIssues, identityIssue: result.identityIssue,
                isSandboxed: isSandboxed, isWeChat: isWeChat, containerIdentifier: containerIdentifier)
            let discoveredSnapshot = snapshot
            await MainActor.run {
                guard self.libraryScanToken == scanToken else { return }
                self.applyAppDataSnapshot(discoveredSnapshot)
            }
            // Ordinary visits can reuse measured sizes; explicit refresh/migration cannot.
            let sizedItems = await withTaskGroup(of: (Int, DirectorySizeResult).self) { group in
                var results: [(Int, DirectorySizeResult)] = []
                var iterator = items.indices.makeIterator()
                for _ in 0..<min(4, items.count) {
                    guard !Task.isCancelled, let i = iterator.next() else { break }
                    group.addTask { (i, measureDataDirectorySize(for: items[i], useCache: !forceSizeRefresh)) }
                }
                for await result in group {
                    results.append(result)
                    if !Task.isCancelled, let i = iterator.next() {
                        group.addTask { (i, measureDataDirectorySize(for: items[i], useCache: !forceSizeRefresh)) }
                    }
                }
                return results
            }
            guard !Task.isCancelled else { return }
            for (i, measured) in sizedItems {
                snapshot.items[i].applySize(measured)
                snapshot.readIssues.append(contentsOf: measured.readIssues)
            }
            let completedSnapshot = snapshot
            await MainActor.run {
                guard self.libraryScanToken == scanToken,
                      self.operationState.recordsRevision == context.recordsRevision else { return }
                self.applyAppDataSnapshot(completedSnapshot)
                self.appDataScanCache.store(completedSnapshot)
                self.isScanning = false
                AppLogger.shared.logContext("应用数据目录扫描及大小统计完成",
                    details: [("app_name", app.displayName), ("count", String(completedSnapshot.items.count))])
                completion?(completedSnapshot.items)
            }
        }
    }

    /// Refresh display data before opening migration confirmation; never execute from a cached item.
    private func refreshAppDataBeforeMigration(_ item: DataDirItem, continuing: @escaping (DataDirItem) -> Void) {
        guard selectedTab == .appDirs, let app = selectedApp else { continuing(item); return }
        guard !isScanning, !operationState.blocksInteraction else { return }
        appDataScanCache.removeAll()
        scanLibraryDirs(for: app, useCachedResult: false, forceSizeRefresh: true) { items in
            guard let fresh = items.first(where: { $0.path.standardizedFileURL == item.path.standardizedFileURL }),
                  fresh.isMigratable, !fresh.sizeIsIncomplete, fresh.status == DataDirStatus.local else {
                errorMessage = "目录状态已变化，请重新选择后再迁移。".localized
                showError = true
                return
            }
            continuing(fresh)
        }
    }

    // MARK: - 迁移 / 还原 确认

    private func askMigrate(_ item: DataDirItem) {
        refreshAppDataBeforeMigration(item, continuing: askMigrateWithFreshData)
    }

    private func askMigrateWithFreshData(_ item: DataDirItem) {
        if !item.weChatSplitMembers.isEmpty {
            weChatMigrationMode = .split
            checkMountMigrationDestination(for: item, destination: externalDriveURL)
            return
        }
        if partialWeChatMigrationEnabled, selectedWeChatPolicy.isAccount(item.path) {
            askMountMigrateWithFreshData(item)
            return
        }
        // 容器数据只能挂载迁移；符号链接会被内核按真实路径拒绝。经典模式下由用户自担风险。
        if item.requiresMountMigration && !classicModeActive {
            askMountMigrateWithFreshData(item)
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

        let destPath = suggestedDestinationPath(for: item, under: dest)

        presentMigrationConfirmation(for: item, destinationPath: destPath,
                                     associatedApp: selectedTab == .appDirs ? selectedApp : nil)
    }

    private func askRestore(_ item: DataDirItem) {
        if !item.weChatSplitMembers.isEmpty { askMountRestore(item); return }
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
            message: String(format: "将「%@」还原到本地。\n\n外部来源：%@\n还原到：%@\n\n校验和切换成功后自动清理外部旧副本，还原直接完成。".localized,
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

    private func submitDataTask(_ item: DataDirItem, title: String, destinations: [URL] = [],
                                associatedApp: AppItem? = nil, mount: Bool = false,
                                requireAppStopped: Bool = true,
                                retrying: MigrationJob.RetryToken? = nil,
                                recovery: (@MainActor (Error, MigrationJob.RetryToken) -> Void)? = nil,
                                operation: @escaping @Sendable (DataTransferProgress) async throws -> String?) {
        let app = associatedApp ?? (selectedTab == .appDirs ? selectedApp : nil)
        if requireAppStopped, let name = runningAssociatedAppName(for: item, associatedApp: app) {
            errorMessage = String(format: "「%@」正在运行中，请先退出应用。".localized, name)
            showError = true
            return
        }
        var paths = [item.path] + destinations + item.weChatSplitMembers.map(\.path)
        if let target = item.linkedDestination { paths.append(target) }
        if let app { paths += [app.path, app.displayURL] }
        var keys: Set<String> = mount ? ["apfs-layout"] : []
        let identifier = app.flatMap { try? resolveRealAppURL($0) }.flatMap { CodeSigner.bundleIdentifier(at: $0) }
            ?? item.associatedBundleIdentifier
        if let identifier {
            keys.insert("application:" + identifier)
        }
        let category: MigrationCategory = item.type == .dotFolder ? .tools : .appData
        let taskTitle = title.contains(item.name) ? title : title + " · " + item.name
        MigrationTaskCenter.shared.submit(title: taskTitle, category: category,
            resources: MigrationResources(paths: paths, keys: keys),
            retrying: retrying, recovery: recovery, operation: { progress in
                try await MigrationExecution.control?.checkpointAsync()
                let directory = ContainerMountStore.shared.fileURLForDeletionAuthorization.deletingLastPathComponent()
                    .appendingPathComponent("launch-locks", isDirectory: true)
                return try await ApplicationLaunchProtection.run(identifier: requireAppStopped ? identifier : nil, directory: directory) {
                    if requireAppStopped,
                       await MigrationApplicationState.isRunning(appURL: app?.displayURL, bundleIdentifier: identifier) {
                        throw AppMoverError.appIsRunning
                    }
                    progress.setDirectory(item.path)
                    return try await operation(progress)
                }
            }, completion: { reloadCurrentTab() })
    }


    private func performMigrate(_ item: DataDirItem, to dest: URL, associatedApp: AppItem? = nil) {
        submitDataTask(item, title: String(format: "正在迁移「%@」".localized, item.name),
                       destinations: [dest.appendingPathComponent(item.path.lastPathComponent)], associatedApp: associatedApp) { progress in
            let result = try await DataDirMover().migrateAndComplete(item: item, to: dest,
                progressHandler: { progress.update($0) })
            return result.cleanupWarning
        }
    }

    private func presentMigrationConfirmation(for item: DataDirItem, destinationPath: URL, associatedApp: AppItem? = nil) {
        let sizeInfo = item.size.map { String(format: "，大小约 %@".localized, $0) } ?? ""
        let detail = String(format: "将「%@」迁移到外部存储%@。\n\n源路径：%@\n目标路径：%@\n\n校验和切换成功后自动清理旧副本。应用签名保持不变。".localized,
                            item.name, sizeInfo, item.path.path, destinationPath.path)
        let ownershipNote = ownershipStorageNote(for: destinationPath)
        let execute = { performMigrate(item, to: destinationPath.deletingLastPathComponent(), associatedApp: associatedApp) }
        if classicModeActive, item.requiresMountMigration {
            var actions: [WarningAction] = [
                WarningAction("改用挂载迁移".localized) { askMountMigrate(item) }
            ]
            if let associatedApp, let onResignApp {
                actions.append(WarningAction("先手动重签".localized) { onResignApp(associatedApp) })
            }
            actions.append(WarningAction("仅迁移数据".localized, style: .preferred, handler: execute))
            migrationRiskRequest = WarningSheetRequest(
                title: "经典模式迁移".localized, tint: .orange,
                intro: detail + "\n\n" + "仍受沙盒限制的应用可能无法读取链接位置。迁移不会自动重签；仅搬完数据不代表应用兼容性已验证。".localized
                    + ownershipNote,
                actions: actions)
        } else {
            let warning = item.migrationWarning.map { "\n\n" + $0 } ?? ""
            confirmRequest = makeConfirmRequest(title: "迁移数据目录".localized, actionTitle: "继续".localized,
                                               message: detail + warning + ownershipNote, action: execute)
        }
    }

    /// 目标盘存不住文件所有者时，在确认框里补一句说明。只提示、不阻断。
    private func ownershipStorageNote(for destinationPath: URL) -> String {
        let advisory = OwnershipStorageAdvisory()
        guard let limitation = advisory.limitation(for: destinationPath) else { return "" }
        let driveName = MountMigrationGuidance.driveName(for: destinationPath.path)
        AppLogger.shared.logContext(
            "迁移目标盘不保存文件所有者",
            details: [
                ("destination", destinationPath.path),
                ("drive_name", driveName),
                ("limitation", String(describing: limitation))
            ],
            level: "WARN"
        )
        return "\n\n" + limitation.advisoryMessage(driveName: driveName)
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

    private func performRestore(_ item: DataDirItem) {
        submitDataTask(item, title: String(format: "正在还原「%@」".localized, item.name)) { progress in
            let result = try await DataDirMover().restoreAndComplete(item: item,
                progressHandler: { progress.update($0) })
            return result.cleanupWarning
        }
    }

    private func performManageExistingLink(_ item: DataDirItem, target: URL) {
        let normalizedTarget = normalizedManagementDestination(for: item, currentTarget: target)
        submitDataTask(item, title: "整理已链接目录".localized,
                       destinations: [target, normalizedTarget]) { progress in
            let result = try await DataDirMover().normalizeManagedLinkAndComplete(
                localPath: item.path, currentExternalPath: target, normalizedExternalPath: normalizedTarget,
                progressHandler: { progress.update($0) })
            return result.cleanupWarning
        }
    }

    private func performRelinkExternalData(_ item: DataDirItem, target: URL) {
        submitDataTask(item, title: "接回外部数据".localized, destinations: [target]) { _ in
            try await DataDirMover().createLink(localPath: item.path, externalPath: target,
                bundleIdentifier: item.associatedBundleIdentifier, appName: item.associatedAppName)
            return nil
        }
    }

    // MARK: - 挂载迁移（沙盒应用容器数据）

    private func askMountMigrate(_ item: DataDirItem) {
        refreshAppDataBeforeMigration(item, continuing: askMountMigrateWithFreshData)
    }

    private func askMountMigrateWithFreshData(_ item: DataDirItem) {
        if partialWeChatMigrationEnabled, selectedWeChatPolicy.isAccount(item.path) {
            if requestAssociatedAppExit(for: item, continuing: { askMountMigrate(item) }) { return }
            weChatMigrationItem = item
            return
        }
        weChatMigrationMode = .whole
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
        if requestAssociatedAppExit(for: item, continuing: { checkMountMigrationDestination(for: item, destination: destination) }) { return }
        guard !isCheckingMountDestination else { return }
        isCheckingMountDestination = true
        let sourceAppID = selectedApp?.id
        Task { @MainActor in
            // 先只读检查目标盘（格式、加密、空间），再决定给确认框还是给引导。
            let outcome = await MountMigrationPreflight().evaluate(destination: destination, dataBytes: item.sizeBytes)
            isCheckingMountDestination = false
            guard selectedApp?.id == sourceAppID, !operationState.blocksInteraction else { return }
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
                        if case .encrypted = outcome {
                            encryptedMigrationRequest = EncryptedMigrationRequest(item: item)
                        } else { performMountMigrate(item) }
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

    private func performMountMigrate(_ item: DataDirItem, encryption: APFSVolumeEncryption.Credentials? = nil,
                                     retrying: MigrationJob.RetryToken? = nil) {
        if let retrying, !MigrationTaskCenter.shared.canRetry(retrying) { return }
        if retrying == nil, weChatMigrationMode == .split, selectedWeChatPolicy.isAccount(item.path) {
            performWeChatSplitOperation(item, restoring: false, encryption: encryption, retrying: retrying)
            return
        }
        guard let dest = externalDriveURL else { return }
        if requestAssociatedAppExit(for: item, retrying: retrying, continuing: {
            performMountMigrate(item, encryption: encryption, retrying: retrying)
        }) { return }
        let app = selectedApp
        let name = app?.displayName ?? item.name
        let bundleID = app.flatMap { (try? resolveRealAppURL($0)).flatMap { CodeSigner.bundleIdentifier(at: $0) } }
        submitDataTask(item, title: String(format: "正在挂载迁移「%@」".localized, item.name),
                       mount: true, retrying: retrying, recovery: { error, retry in
            presentAPFSFailure(error, item: item, retryToken: retry, retry: {
                performMountMigrate(item, encryption: encryption, retrying: retry)
            })
        }) { progress in
            let result = try await ContainerVolumeMigrator(encryption: encryption).migrateAndComplete(
                item: item, externalRootURL: dest, appName: name, bundleIdentifier: bundleID,
                progressHandler: { progress.update($0) })
            return result.cleanupWarning?.message
        }
    }

    private func performMount(_ item: DataDirItem, retrying: MigrationJob.RetryToken? = nil) {
        if let retrying, !MigrationTaskCenter.shared.canRetry(retrying) { return }
        let paths = item.weChatSplitMembers.isEmpty ? [item.path] : item.weChatSplitMembers.map(\.path)
        let records = paths.compactMap { ContainerMountStore.shared.record(forMountPoint: $0) }
        guard !records.isEmpty else {
            errorMessage = "找不到该目录的挂载记录".localized
            showError = true
            return
        }
        submitDataTask(item, title: String(format: "正在挂载「%@」".localized, item.name),
                       mount: true, requireAppStopped: false, retrying: retrying, recovery: { error, retry in
            presentAPFSFailure(error, item: item, retryToken: retry, retry: { performMount(item, retrying: retry) })
        }) { _ in
            let migrator = ContainerVolumeMigrator()
            for record in records {
                try await MigrationExecution.control?.checkpointAsync()
                try Task.checkCancellation()
                try await migrator.mount(record: record)
            }
            return nil
        }
    }

    private func performUnmount(_ item: DataDirItem) {
        guard let record = ContainerMountStore.shared.record(forMountPoint: item.path) else {
            errorMessage = "找不到该目录的挂载记录".localized
            showError = true
            return
        }
        submitDataTask(item, title: String(format: "正在卸载「%@」".localized, item.name), mount: true) { _ in
            try await ContainerVolumeMigrator().unmount(record: record)
            return nil
        }
    }

    private func askMountRestore(_ item: DataDirItem) {
        if !item.weChatSplitMembers.isEmpty {
            if requestAssociatedAppExit(for: item, continuing: { askMountRestore(item) }) { return }
            confirmRequest = makeConfirmRequest(title: "还原微信账号数据".localized, actionTitle: "还原".localized,
                message: "将这个账号的 msg 和 business 一起还原到本地。校验并切换成功后，自动清理外置旧副本。".localized) {
                    performWeChatSplitOperation(item, restoring: true)
                }
            return
        }
        if requestAssociatedAppExit(for: item, continuing: { askMountRestore(item) }) { return }
        guard let record = try? ContainerMountStore.shared.recordForRestore(at: item.path) else {
            errorMessage = "无法确认原位置对应的迁移记录，数据已保留，未执行还原。".localized
            showError = true
            return
        }

        confirmRequest = makeConfirmRequest(
            title: "还原挂载迁移目录".localized,
            actionTitle: "继续".localized,
            message: String(
                format: "将「%@」还原到本地。\n\n外部来源：%@\n还原到：%@\n\n校验和切换成功后自动清理外部旧副本，还原直接完成。".localized,
                item.name,
                record.volumeName,
                item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            ),
            action: { performMountRestore(item, record: record) }
        )
    }

    private func performMountRestore(_ item: DataDirItem, record: ContainerMountRecord,
                                     retrying: MigrationJob.RetryToken? = nil) {
        if let retrying, !MigrationTaskCenter.shared.canRetry(retrying) { return }
        if requestAssociatedAppExit(for: item, retrying: retrying, continuing: {
            performMountRestore(item, record: record, retrying: retrying)
        }) { return }
        submitDataTask(item, title: String(format: "正在还原「%@」".localized, item.name),
                       mount: true, retrying: retrying, recovery: { error, retry in
            presentAPFSFailure(error, item: item, record: record, retryToken: retry,
                retry: { performMountRestore(item, record: record, retrying: retry) })
        }) { progress in
            try await ContainerVolumeMigrator().restoreAndComplete(record: record,
                estimatedTotalBytes: item.sizeBytes, progressHandler: { progress.update($0) })?.message
        }
    }

    private func performWeChatSplitOperation(_ item: DataDirItem, restoring: Bool,
                                               encryption: APFSVolumeEncryption.Credentials? = nil,
                                               retrying: MigrationJob.RetryToken? = nil) {
        if let retrying, !MigrationTaskCenter.shared.canRetry(retrying) { return }
        if requestAssociatedAppExit(for: item, retrying: retrying, continuing: {
            performWeChatSplitOperation(item, restoring: restoring, encryption: encryption, retrying: retrying)
        }) { return }
        let destination = externalDriveURL
        let appName = selectedApp?.displayName ?? item.name
        let splitEnabled = partialWeChatMigrationEnabled
        let containerIdentifier = weChatContainerIdentifier
        let members = selectedWeChatPolicy.members(of: item.path)
        submitDataTask(item, title: restoring ? "正在还原微信账号数据".localized : "正在拆分迁移微信账号数据".localized,
                       destinations: members, mount: true, retrying: retrying, recovery: { error, retry in
            presentAPFSFailure(error, item: item, retryToken: retry, retry: {
                performWeChatSplitOperation(item, restoring: restoring, encryption: encryption, retrying: retry)
            })
        }) { progress in
            progress.configureUnits(members)
            let service = WeChatAccountMigrationService(enabled: splitEnabled,
                containerIdentifier: containerIdentifier, encryption: encryption)
            let warnings: [String]
            if restoring {
                warnings = try await service.restoreSplit(account: item.path, progress: { progress.update($0) })
            } else {
                guard let destination else { throw DataOperationSafety.Failure.inspection("请先选择外部存储路径".localized) }
                warnings = try await service.migrate(account: item.path, mode: .split, externalRoot: destination,
                    appName: appName, progress: { progress.update($0) })
            }
            return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        }
    }

    private func presentAPFSFailure(_ error: Error, item: DataDirItem, record: ContainerMountRecord? = nil,
                                    retryToken: MigrationJob.RetryToken? = nil,
                                    retry: @escaping () -> Void) {
        if let retryToken, !MigrationTaskCenter.shared.canRetry(retryToken) { return }
        if case APFSVolumeEncryption.Failure.waitingForUnlock(let uuid) = error {
            confirmRequest = WarningSheetRequest(title: "等待解锁".localized, tint: .orange,
                intro: error.localizedDescription, cancelTitle: "稍后".localized,
                actions: [WarningAction("解锁数据卷".localized, style: .preferred) {
                    if let retryToken, !MigrationTaskCenter.shared.canRetry(retryToken) { return }
                    encryptedMigrationRequest = EncryptedMigrationRequest(item: item, volumeUUID: uuid,
                        retryToken: retryToken, retry: retry)
                }])
            return
        }
        let record = record ?? (try? ContainerMountStore.shared.recordForRestore(at: item.path))
        var actions: [WarningAction] = []
        if DataOperationIssue.needsAccessPermission(error) {
            actions.append(WarningAction("访问权限设置".localized) {
                if let retryToken, !MigrationTaskCenter.shared.canRetry(retryToken) { return }
                if let url = LaunchReadinessChecker.Item.Action.fullDiskAccess.settingsURLs.first { NSWorkspace.shared.open(url) }
                // Keep the same operation available when the user returns.
                presentAPFSFailure(error, item: item, record: record, retryToken: retryToken, retry: retry)
            })
        }
        actions.append(WarningAction("重试".localized, style: .preferred, handler: retry))
        confirmRequest = WarningSheetRequest(title: "数据操作未完成".localized, tint: .orange,
            intro: error.localizedDescription, cancelTitle: "稍后".localized, actions: actions)
    }

    private func requestAssociatedAppExit(for item: DataDirItem, associatedApp: AppItem? = nil,
                                          useSelectedApp: Bool = true, retrying: MigrationJob.RetryToken? = nil,
                                          continuing action: @escaping () -> Void) -> Bool {
        if let retrying, !MigrationTaskCenter.shared.canRetry(retrying) { return true }
        let app = associatedApp ?? (useSelectedApp && selectedTab == .appDirs ? selectedApp : nil)
        let appURL = app.map { (try? resolveRealAppURL($0)) ?? $0.displayURL }
        let bundleID = appURL.flatMap { CodeSigner.bundleIdentifier(at: $0) } ?? item.associatedBundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { candidate in
            if let appURL {
                return AppRunningState.matches(appURL: appURL, bundleIdentifier: bundleID,
                    application: .init(bundleURL: candidate.bundleURL, bundleIdentifier: candidate.bundleIdentifier))
            }
            return bundleID != nil && candidate.bundleIdentifier == bundleID
        }
        guard !running.isEmpty else { return false }
        let name = app?.displayName ?? running.first?.localizedName ?? item.name
        confirmRequest = makeConfirmRequest(title: "先退出关联应用".localized, actionTitle: "退出应用并继续".localized,
            message: String(format: "「%@」正在使用这些数据。AppPorts 将请求它正常退出，退出后继续本次操作。".localized, name)) {
                Task { @MainActor in
                    if let retrying, !MigrationTaskCenter.shared.canRetry(retrying) { return }
                    for application in running where !application.isTerminated { _ = application.terminate() }
                    let deadline = ProcessInfo.processInfo.systemUptime + 8
                    while running.contains(where: { !$0.isTerminated }), ProcessInfo.processInfo.systemUptime < deadline {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if let retrying, !MigrationTaskCenter.shared.canRetry(retrying) { return }
                    if running.allSatisfy(\.isTerminated) { action() }
                    else {
                        confirmRequest = makeConfirmRequest(title: "等待应用退出".localized, actionTitle: "继续".localized,
                            message: "请先完成关联应用中的保存或退出确认，然后点击继续。".localized, action: action)
                    }
                }
            }
        return true
    }

    private func presentCleanupWarning(_ warning: ContainerVolumeMigrator.CleanupWarning?, additionalWarning: String? = nil) {
        if let additionalWarning {
            cleanupWarning = warning
            showCleanupWarning = false
            presentDataCompletionWarnings([warning?.message, additionalWarning])
            return
        }
        guard let warning else { return }
        cleanupWarning = warning
        showCleanupWarning = true
    }

    private func presentDataCompletionWarnings(_ warnings: [String?]) {
        dataCompletionWarning = warnings.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        showDataCompletionWarning = !dataCompletionWarning.isEmpty
    }

    private func retryPendingOperations(operationID: UUID? = nil) {
        // 依据待处理记录检查关联应用，不能只检查当前选中的应用。
        var pendingApps: [(String, String?, String)] = dataTransfers.filter {
            operationID == nil ? $0.cleanupDisposition != .keep : $0.operationID == operationID
        }.map { ($0.appName, $0.bundleIdentifier, $0.originalPath) }
        if operationID == nil {
            pendingApps += pendingCleanups.map { ($0.mountRecord.appName, $0.mountRecord.bundleIdentifier, $0.localPath) }
            pendingApps += preservedMaterials.compactMap { material in
                material.recoveryRecord.map { ($0.appName, $0.bundleIdentifier, $0.originalPath) }
            }
        }
        if let (name, identifier, path) = pendingApps.first(where: { _, identifier, _ in
            guard let identifier else { return false }
            return !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
        }) {
            var item = DataDirItem(name: name, path: URL(fileURLWithPath: path),
                type: .containers, priority: .critical, description: "")
            item.associatedBundleIdentifier = identifier
            if requestAssociatedAppExit(for: item, useSelectedApp: false, continuing: { retryPendingOperations(operationID: operationID) }) { return }
        }
        MigrationTaskCenter.shared.submit(title: "正在继续处理".localized, category: .appData,
            resources: MigrationResources(paths: [], keys: ["all-file-operations"]), operation: { _ in
                let warnings = await OperationMaintenance.shared.runManagedDataOperations(retryOperationID: operationID)
                try Task.checkCancellation()
                return warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
            }, completion: { reloadCurrentTab() })
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


}

// MARK: - 应用选择列表行

/// 左侧应用列表行视图（带 Hover 和选中态）
private struct AppListRow: View {
    let app: AppItem
    let isSelected: Bool
    let hasMigratedData: Bool

    @State private var isHovered = false

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

            Spacer(minLength: 4)
            if hasMigratedData {
                Text("已迁移".localized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.purple)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .help("此应用已有数据目录迁移到外置盘".localized)
            }
        }
        .frame(height: 32)
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
    }
}
