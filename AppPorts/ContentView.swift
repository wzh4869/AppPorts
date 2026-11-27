//
//  ContentView.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/18.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// NOTE: AppItem and AppMoverError are in AppModels.swift
// NOTE: AppLogger is in Services/AppLogger.swift

// MARK: - UI 组件 (已提取到 Views/Components/)
// ProgressOverlay -> Views/Components/ProgressOverlay.swift
// StatusBadge -> Views/Components/StatusBadge.swift
// AppIconView -> Views/Components/AppIconView.swift
// AppRowView -> Views/Components/AppRowView.swift



// MARK: - 主视图
struct ContentView: View {

    @Environment(\.locale) private var locale
    @AppStorage(MainWindowAppearance.defaultsKey) private var appAppearance = "system"
    @ObservedObject private var operationState = AppOperationState.shared
    @ObservedObject private var migrationTasks = MigrationTaskCenter.shared
    @ObservedObject private var diskEjection = DiskEjectionController.shared
    private typealias ScanRequest = AppListScanState.Request
    @State private var localScanState = AppListScanState()
    @State private var externalScanState = AppListScanState()
    @State private var appScanTask: Task<Void, Never>?
    @State private var unmountingVolumePaths: Set<String> = []
    @State private var unmountGraceTask: Task<Void, Never>?
    @State private var isVisible = false
    @State private var needsAppRescan = false
    @State private var runningStateGeneration: UInt64 = 0
    @State private var runningStateRefreshTask: Task<Void, Never>?

    @State private var localApps: [AppItem] = []
    @State private var externalApps: [AppItem] = []
    /// 应用体积缓存（key = AppItem.id），独立保存并在下次启动恢复。
    @State private var sizeCache: [String: CachedAppSize] = [:]
    @State private var hasRestoredSizeCache = false
    
    @State private var searchText: String = ""
    @FocusState private var isAppSearchFocused: Bool
    @State private var appConnectionFilter: AppConnectionFilter = .all

    enum AppConnectionFilter: CaseIterable {
        case all, linked, unlinked

        var title: String {
            switch self {
            case .all: return "全部".localized
            case .linked: return "已链接".localized
            case .unlinked: return "未链接".localized
            }
        }
    }
    
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
    
    @State private var availableUpdate: AppUpdateInfo?
    
    // 受保护应用迁移预警（App Store / root 拥有，自动迁移可能因权限失败）
    @State private var protectedAppsRequest: WarningSheetRequest?
    @State private var appMigrationRiskRequest: WarningSheetRequest?
    // 经典模式下重签名沙盒应用前的二次确认
    @State private var manualResignRequest: WarningSheetRequest?
    @State private var pendingManualResignApp: AppItem? = nil
    @State private var pendingManualResignTarget: DataMigrationWorkflow.SigningTarget?
    @State private var pendingProtectedApps: [AppItem] = []
    @State private var pendingMigrationAfterWarning: [AppItem] = []
    /// Apps held back by the target-volume capability warning.
    @State private var pendingStorageLimitationApps: [AppItem] = []
    @State private var storageLimitationRequest: WarningSheetRequest?
    /// Apps held back because the external copy being restored already lost
    /// metadata on the volume it lives on.
    @State private var pendingDegradedRestoreApps: [AppItem] = []
    @State private var degradedRestoreRequest: WarningSheetRequest?

    // 自更新应用迁移确认（Sparkle/Electron，锁定模式保护）
    @State private var updateProtectionSelection: UpdateProtectionSelection?
    @State private var appReplacementRequest: WarningSheetRequest?

    
    // 进度弹窗状态
    @State private var showProgress = false
    @State private var progressTitle = "正在迁移应用".localized
    @State private var progressCurrent = 0
    @State private var progressTotal = 0
    @State private var progressAppName = ""
    
    // App Store 外部安装引导
    @State private var masGuidanceRequest: WarningSheetRequest?
    @ObservedObject private var guardianSync = AppLibraryAgentSync.shared
    @AppStorage(BackgroundAgentPreferences.updateGuardianKey) private var guardianEnabled = true
    @ObservedObject private var appStoreInstall = AppStoreExternalInstallSettings.shared

    @State private var showSearchExclusion = false

    private let fileManager = FileManager.default

    // Monitors
    @State private var localMonitor: FolderMonitor?
    @State private var externalMonitor: FolderMonitor?
    @State private var externalLibraryMonitor: FolderMonitor?

    // Monitor 防抖：合并两个 monitor 的扫描请求
    @State private var monitorRescanDebouncer = RescanDebouncer()

    // Track previous external drive URL for logging
    @State private var previousExternalDriveURL: URL?

    // 插盘通知：重新挂载容器卷
    @State private var libraryVolumeObserver: AppLibraryVolumeObserver?

    enum SortOption {
        case name, size
    }

    enum AppListSort: String {
        case nameAscending, nameDescending, sizeAscending, sizeDescending

        var option: SortOption {
            switch self {
            case .nameAscending, .nameDescending: return .name
            case .sizeAscending, .sizeDescending: return .size
            }
        }

        var ascending: Bool { self == .nameAscending || self == .sizeAscending }

        mutating func select(_ option: SortOption) {
            switch option {
            case .name: self = self == .nameAscending ? .nameDescending : .nameAscending
            case .size: self = self == .sizeDescending ? .sizeAscending : .sizeDescending
            }
        }
    }

    @AppStorage("homeLocalAppSort") private var localAppSort = AppListSort.nameAscending
    @AppStorage("homeExternalAppSort") private var externalAppSort = AppListSort.nameAscending

    // MARK: - Tab
    enum MainTab { case apps, dataDirs, customDirs, tasks, settings }
    @State private var mainTab: MainTab = .apps
    @State private var hasOpenedDataDirs = false
    @State private var hasOpenedCustomDirs = false
    @State private var operationTab: MainTab?
    @State private var operationDataTab: DataDirsView.DataTab?
    @State private var selectedDataDirsTab: DataDirsView.DataTab = .toolDirs
    @State private var selectedDataDirsApp: AppItem? = nil
    @State private var isDataDirsScanning = false
    @State private var dataDirsRefreshTrigger = 0
    @State private var customDirsRefreshTrigger = 0
    @State private var isCustomDirsScanning = false
    @AppStorage(MigrationPreferences.classicDataMigrationKey) private var classicDataMigrationEnabled = false

    // 签名被替换的应用：启动提醒与修复面板
    @State private var signatureRepairApp: AppItem? = nil
    @State private var signatureRepairReminderRequest: WarningSheetRequest?
    @State private var signatureRestoreSourceRequest: WarningSheetRequest?
    @State private var signatureRepairReminderApps: [SignatureReplacedApp] = []
    @State private var hasShownSignatureRepairReminder = false
    @State private var legacyPermissionResetRequest: WarningSheetRequest?
    @State private var showLegacyReadinessSheet = false
    @State private var hasEvaluatedLegacyPermissionReset = false
    @ObservedObject private var permissionReadiness = PermissionReadiness.shared
    @State private var localAppFilter: LocalAppFilter = .all

    enum LocalAppFilter { case all, signatureReplaced }

    /// 经典模式生效：用户开启且系统版本允许
    private var classicModeActive: Bool {
        classicDataMigrationEnabled && MigrationPreferences.isClassicModeSupported
    }

    var body: some View {
        let updateContext = updateRecommendationContext
        mainContent
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 930, minHeight: 620)
        .onAppear {
            // A unit-test host must not scan apps, refresh agents, or observe real volumes.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            permissionReadiness.refresh()
            if !hasEvaluatedLegacyPermissionReset {
                hasEvaluatedLegacyPermissionReset = true
                Task {
                    if let prompt = await LegacyPermissionResetter.shared.evaluateAndResetOnLaunchIfNeeded() {
                        await MainActor.run {
                            permissionReadiness.refresh()
                            legacyPermissionResetRequest = makeLegacyPermissionResetRequest(for: prompt)
                        }
                    }
                }
            }
            refreshMASGuidance()
            isVisible = true
            if !hasRestoredSizeCache {
                let snapshot = AppSizeCacheStore.shared.load()
                sizeCache = snapshot.entries
                hasRestoredSizeCache = true
            }
            let previousDrive = externalDriveURL
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
            // Restoring a different drive already schedules the initial scan in onChange.
            if previousDrive == externalDriveURL {
                scanBothApps()
            } else {
                prepareAppListSources(local: true, external: true)
            }

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
                        self.availableUpdate = update
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            permissionReadiness.refresh()
            refreshMASGuidance()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            let latest = UserDefaults.standard.stringArray(forKey: "customLocalScanPaths") ?? []
            guard isVisible, latest != customLocalScanPaths else { return }
            customLocalScanPaths = latest
            startMonitoringLocal()
            scanBothApps()
        }
        .onDisappear {
            monitorRescanDebouncer.cancel()
            isVisible = false
            runningStateRefreshTask?.cancel()
            runningStateRefreshTask = nil
            appScanTask?.cancel()
            appScanTask = nil
            unmountGraceTask?.cancel()
            unmountGraceTask = nil
            unmountingVolumePaths.removeAll()
            localScanState.invalidate()
            externalScanState.invalidate()
            localMonitor?.stopMonitoring()
            customLocalMonitors.forEach { $0.stopMonitoring() }
            stopMonitoringExternal()
            stopObservingVolumeMounts()
        }
        .onReceive(
            NSWorkspace.shared.publisher(for: \.runningApplications)
                .receive(on: RunLoop.main)
        ) { _ in
            scheduleRunningAppsRefresh()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            scheduleRunningAppsRefresh()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            scheduleRunningAppsRefresh()
            remountContainerVolumes(trigger: "application-exited")
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { break }
                remountContainerVolumes(trigger: "retry")
            }
        }
        .onChange(of: migrationTasks.showsList) { showsList in
            if showsList {
                mainTab = .tasks
                migrationTasks.showsList = false
            }
        }
        .onChange(of: migrationTasks.recoveryJobID) { id in
            guard let id, let job = migrationTasks.jobs.first(where: { $0.id == id }) else { return }
            migrationTasks.detailID = nil
            migrationTasks.showsList = false
            migrationTasks.recoveryJobID = nil
            switch job.category {
            case .apps: mainTab = .apps
            case .appData: selectedDataDirsTab = .appDirs; mainTab = .dataDirs
            case .tools: selectedDataDirsTab = .toolDirs; mainTab = .dataDirs
            case .directories: mainTab = .customDirs
            }
            Task { @MainActor in
                await Task.yield()
                job.recoveryAction?()
            }
        }
        .onChange(of: updateContext) { context in
            // 守护可能在目录发现结束后才就绪，缓存应反映此时用户看到的徽章。
            guard isVisible else { return }
            if !localApps.isEmpty, let source = localScanState.source {
                AppListCacheStore.shared.save(localApps, pane: .local, source: source, context: context)
            }
            if !externalApps.isEmpty, let source = externalScanState.source {
                AppListCacheStore.shared.save(externalApps, pane: .external, source: source, context: context)
            }
        }
        .onChange(of: diskEjection.yieldRevision) { _ in
            guard isExternalAccessSuppressed(for: externalDriveURL) else { return }
            yieldExternalVolumeAccess(reason: "disk-ejection")
        }
        .onChange(of: diskEjection.pauses) { _ in
            resumeExternalMonitoringAfterEjectionIfNeeded()
        }
        .onChange(of: diskEjection.imagePauses) { _ in
            resumeExternalMonitoringAfterEjectionIfNeeded()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willUnmountNotification)
                .receive(on: RunLoop.main)
        ) { notification in
            handleWorkspaceWillUnmount(notification)
        }
        .onChange(of: operationState.recordsRevision) { _ in
            AppLibraryAgentSync.shared.selectionDidChange()
            guard isVisible else { return }
            scanBothApps()
        }
        .onChange(of: operationState.isBusy) { isBusy in
            if isBusy {
                operationTab = mainTab
                operationDataTab = mainTab == .dataDirs ? selectedDataDirsTab : nil
            } else {
                operationTab = nil
                operationDataTab = nil
            }
            // 补上操作期间延后的监控刷新，也初始化操作期间新打开的窗口。
            if !isBusy,
               !isExternalVolumeSuppressedAndMounted(externalDriveURL),
               needsAppRescan || localScanState.request == nil || externalScanState.request == nil {
                scanBothApps()
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
            AppLibraryAgentSync.shared.selectionDidChange()
            scanBothApps()

            refreshMASGuidance()
        }
        
        .alert(Text(verbatim: alertTitle), isPresented: $showAlert) {
            Button("好的".localized, role: .cancel) { }
        } message: {
            Text(verbatim: alertMessage)
        }
        .warningSheet($signatureRepairReminderRequest)
        .warningSheet($signatureRestoreSourceRequest)
        .warningSheet($manualResignRequest)
        .sheet(item: $signatureRepairApp) { app in
            signatureRepairSheet(for: app)
        }
        .modifier(AppUpdatePresentation(update: $availableUpdate))
        // 受保护应用（App Store / root）迁移预警
        .warningSheet($protectedAppsRequest)
        .warningSheet($appMigrationRiskRequest)
        // 目标存储无法保存部分应用信息
        .warningSheet($storageLimitationRequest)
        // 要还原的外部副本可能已经降级
        .warningSheet($degradedRestoreRequest)
        // 自更新应用迁移确认弹窗
        .sheet(item: $updateProtectionSelection) { selection in
            UpdateProtectionDialog(selection: selection) { updateProtectionSelection = nil }
        }
        .warningSheet($appReplacementRequest)
        // App Store 外部安装引导弹窗
        .warningSheet($masGuidanceRequest)
        // 证书更新后旧权限记录清理与重新授权引导弹窗
        .warningSheet($legacyPermissionResetRequest)
        .sheet(isPresented: $showLegacyReadinessSheet) {
            ReadinessCheckSheet()
        }
        // App Store 设置页面
        .sheet(isPresented: $showSearchExclusion) {
            AppSearchExclusionView(load: loadExternalAppSearchStatus, process: excludeExternalAppsFromSearch)
        }
        .overlay {
            if let job = migrationTasks.detail {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    MigrationTaskDetail(job: job)
                }
                .zIndex(10)
            }
        }
        // 进度覆盖层
        .overlay {
            if showProgress {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()

                    VStack(spacing: 10) {
                        // Batch counter belongs outside the stage view: it is the
                        // only number that spans several applications.
                        if progressTotal > 1 {
                            Text(String(format: "应用 %lld / %lld".localized,
                                        Int64(progressCurrent), Int64(progressTotal)))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        ProgressOverlay(
                            title: progressTitle,
                            current: progressCurrent,
                            total: progressTotal,
                            appName: progressAppName,
                            copiedBytes: 0,
                            totalBytes: 0,
                            currentFile: ""
                        )
                    }
                }
            }
        }
        .environment(\.updateRecommendation, updateContext)
    }

    private var updateRecommendationContext: UpdateRecommendationContext {
        UpdateRecommendationContext(enabled: guardianEnabled, ready: guardianSync.guardianReady, store: appStoreInstall)
    }
    
    // MARK: - 过滤逻辑
    
    var filteredLocalApps: [AppItem] {
        let rows = localApps.isEmpty ? localScanState.preview : localApps
        let apps = localAppFilter == .signatureReplaced ? rows.filter(\.signatureReplaced) : rows
        return sortApps(apps.filter(matchesAppListFilters), sorting: localAppSort)
    }

    var filteredExternalApps: [AppItem] {
        let rows = externalApps.isEmpty ? externalScanState.preview : externalApps
        return sortApps(rows.filter(matchesAppListFilters), sorting: externalAppSort)
    }

    private func matchesAppListFilters(_ app: AppItem) -> Bool {
        // Keep partial/broken links visible so unfinished migrations can still be handled.
        switch appConnectionFilter {
        case .all: break
        case .linked: if app.status != AppStatus.linked { return false }
        case .unlinked: if app.status == AppStatus.linked { return false }
        }
        return searchText.isEmpty || app.displayName.localizedCaseInsensitiveContains(searchText)
            || app.name.localizedCaseInsensitiveContains(searchText)
    }

    func sortApps(_ apps: [AppItem], sorting: AppListSort) -> [AppItem] {
        apps.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sorting.option {
            case .name:
                comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case .size:
                comparison = lhs.sizeBytes == rhs.sizeBytes ? .orderedSame
                    : (lhs.sizeBytes < rhs.sizeBytes ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame {
                let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
            }
            return sorting.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func appListColumnHeader(sorting: Binding<AppListSort>, columnTrailingInset: CGFloat) -> some View {
        AppListColumns {
            sortColumnButton("名称".localized, option: .name, sorting: sorting)
        } size: {
            sortColumnButton("大小".localized, option: .size, sorting: sorting)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1, height: 16)
                        .offset(x: -10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } actions: {
            Color.clear.frame(height: 1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.leading, 12)
        .padding(.trailing, max(0, columnTrailingInset - 12))
        .frame(height: 30)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func sortColumnButton(_ title: String, option: SortOption, sorting: Binding<AppListSort>) -> some View {
        Button { sorting.wrappedValue.select(option) } label: {
            HStack(spacing: 4) {
                Text(title)
                if sorting.wrappedValue.option == option {
                    Image(systemName: sorting.wrappedValue.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AppPressButtonStyle())
        .accessibilityAddTraits(sorting.wrappedValue.option == option ? .isSelected : [])
    }

    // MARK: - 辅助组件
    
    struct HeaderView: View {
        let title: String
        let subtitle: String // subtitle 可能是路径，也可能是 "未选择"
        let icon: String
        var iconColumnWidth: CGFloat = 32
        var appCount: Int? = nil
        var sizeSummary: String? = nil
        var tint: Color = .accentColor
        var actionButtonText: String? = nil
        var onAction: (() -> Void)? = nil
        var onRefresh: (() -> Void)? = nil
        var isRefreshing = false
        var accessory: AnyView? = nil
        
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 28, height: 28)
                    .frame(width: iconColumnWidth, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 8)

                        HStack(spacing: 8) {
                            if let btnText = actionButtonText, let action = onAction {
                                Button(action: action) {
                                    Text(btnText)
                                        .font(.system(size: btnText == "＋" ? 18 : 13, weight: .medium))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 10)
                                        .frame(minWidth: 36, minHeight: 34)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(AppPressButtonStyle())
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
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(AppPressButtonStyle())
                                .disabled(isRefreshing)
                                .accessibilityLabel(isRefreshing ? "正在扫描...".localized : "刷新列表".localized)
                                .help(isRefreshing ? "正在扫描...".localized : "刷新列表".localized)
                            }
                        }
                        .fixedSize()
                    }
                    .frame(minHeight: 24)

                    HStack(spacing: 6) {
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(subtitle)
                        }
                        if let appCount {
                            if !subtitle.isEmpty { Text(verbatim: "·") }
                            Text("%lld 个应用".localizedFormat(Int64(appCount)))
                                .fixedSize()
                        }
                        if let sizeSummary, !sizeSummary.isEmpty {
                            if !subtitle.isEmpty || appCount != nil { Text(verbatim: "·") }
                            Text(sizeSummary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(sizeSummary)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // 与列表行图标对齐：系统外边距 8 + 行 inset 4 + 行内边距 12。
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 56)
            .overlay(alignment: .bottom) { Divider() }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
    
    struct ActionFooter: View {
        let title: String
        let icon: String
        let isEnabled: Bool
        var columnTrailingInset: CGFloat? = nil
        let action: () -> Void

        var body: some View {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(title)
                        Image(systemName: icon)
                    }
                    .frame(minWidth: 112, minHeight: 22)
                }
                .buttonStyle(AppListPrimaryButtonStyle())
                .disabled(!isEnabled)

            .modifier(AppListFooterStyle(columnTrailingInset: columnTrailingInset))
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
        SidebarSplitView {
            sidebar
        } content: {
            mainPageContent
                .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: mainTab) { tab in
            if tab == .dataDirs { hasOpenedDataDirs = true }
            if tab == .customDirs { hasOpenedCustomDirs = true }
        }
    }

    private var mainPageContent: some View {
        VStack(spacing: 0) {
            if mainTab == .apps {
                appListToolbar
                    .disabled(operationState.blocksInteraction)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            if mainTab == .dataDirs, selectedDataDirsTab == .appDirs,
               selectedDataDirsApp?.isResigned == true {
                HStack {
                    Spacer()
                    dataDirsToolbarControls
                        .disabled(operationState.blocksInteraction)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if operationState.blocksInteraction, let operationTab,
               mainTab != operationTab || (mainTab == .dataDirs && selectedDataDirsTab != operationDataTab) {
                HStack {
                    Text("任务正在处理中".localized)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("查看进度".localized) {
                        if let operationDataTab { selectedDataDirsTab = operationDataTab }
                        mainTab = operationTab
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // MARK: - 主内容区（Tab 切换）
            // Keep visited pages alive so switching tabs cannot discard an active
            // operation's progress, result alerts, or batch state. Hidden pages
            // suspend their list scans through isActive.
            ZStack(alignment: .topLeading) {
                if mainTab == .settings {
                    AppStoreSettingsView()
                }
                if mainTab == .tasks {
                    MigrationTaskList(isEmbedded: true)
                }
                if mainTab == .dataDirs || hasOpenedDataDirs {
                    DataDirsView(
                        isActive: mainTab == .dataDirs,
                        externalDriveURL: externalDriveURL,
                        localApps: localApps.filter(\.showsAppData),
                        selectedTab: $selectedDataDirsTab,
                        selectedApp: $selectedDataDirsApp,
                        isScanning: $isDataDirsScanning,
                        isScanningApps: localScanState.isScanning,
                        classicModeActive: classicModeActive,
                        refreshTrigger: dataDirsRefreshTrigger,
                        onSelectExternalDrive: openPanelForExternalDrive,
                        onRepairSignature: { app in signatureRepairApp = app },
                        onResignApp: { app in performSingleResign(app: app) },
                        resolveRealAppURL: resolveRealAppURL(for:)
                    )
                    .modifier(AppPageVisibility(isActive: mainTab == .dataDirs))
                }
                if mainTab == .customDirs || hasOpenedCustomDirs {
                    CustomDirsView(
                        isActive: mainTab == .customDirs,
                        refreshTrigger: customDirsRefreshTrigger,
                        onScanningChanged: { isCustomDirsScanning = $0 }
                    )
                        .disabled(operationState.blocksInteraction)
                        .modifier(AppPageVisibility(isActive: mainTab == .customDirs))
                }
                HStack(spacing: 8) {
                    AppLibraryPane(content: localAppsPane)
                    AppLibraryPane(content: externalAppsPane)
                }
                .padding(6)
                .disabled(operationState.blocksInteraction)
                .modifier(AppPageVisibility(isActive: mainTab == .apps))
            }
            .clipped()
        }
        .background(AppSurfaceColors.content)
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            primaryNavigation
            Divider()
            TabButton(title: "任务中心".localized, systemImage: "list.bullet",
                      isSelected: mainTab == .tasks,
                      badgeCount: migrationTasks.unfinishedCount,
                      needsAttention: migrationTasks.hasAttention) {
                mainTab = .tasks
            }
            Divider()
            SidebarTargetSection(directory: externalDriveURL,
                showsTarget: true,
                onChoose: { _ = openPanelForExternalDrive() },
                onImageReady: { externalDriveURL = $0 })
            Spacer(minLength: 8)
            SidebarStorageSection(directory: externalDriveURL,
                showsTarget: true)
            Divider()
            HStack(spacing: 6) {
                PermissionSettingsButton(level: permissionReadiness.level, attentionText: permissionReadiness.attentionText,
                                         isSelected: mainTab == .settings) {
                    mainTab = .settings
                }
                .disabled(operationState.blocksInteraction)
                cacheRefreshButton
                Spacer(minLength: 0)
                Button {
                    switch appAppearance {
                    case "system": appAppearance = "light"
                    case "light": appAppearance = "dark"
                    default: appAppearance = "system"
                    }
                } label: {
                    Group {
                        if appAppearance == "system" {
                            Text(verbatim: "A").font(.system(size: 14, weight: .medium))
                        } else {
                            Image(systemName: appAppearance == "dark" ? "moon" : "sun.max")
                        }
                    }
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("外观".localized + " · " + appearanceTitle)
                .accessibilityLabel("外观".localized)
                .accessibilityValue(appearanceTitle)
            }
            .font(.system(size: 14))
            .foregroundColor(.primary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 12)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appearanceTitle: String {
        switch appAppearance {
        case "light": return "浅色".localized
        case "dark": return "深色".localized
        default: return "跟随系统".localized
        }
    }

    private var primaryNavigation: some View {
        VStack(spacing: 4) {
            TabButton(title: "应用".localized, systemImage: "cube", isSelected: mainTab == .apps) {
                mainTab = .apps
            }
            TabButton(title: "工具目录".localized, systemImage: "wrench.and.screwdriver", isSelected: mainTab == .dataDirs && selectedDataDirsTab == .toolDirs) {
                selectedDataDirsTab = .toolDirs
                mainTab = .dataDirs
            }
            TabButton(title: "应用数据".localized, systemImage: "cylinder", isSelected: mainTab == .dataDirs && selectedDataDirsTab == .appDirs) {
                selectedDataDirsTab = .appDirs
                mainTab = .dataDirs
            }
            TabButton(title: "目录迁移".localized, systemImage: "folder.badge.gearshape", isSelected: mainTab == .customDirs) {
                mainTab = .customDirs
            }
        }
    }

    private var appListToolbar: some View {
        appListFilters
    }

    private var appListFilters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button { isAppSearchFocused = true } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(AppPressButtonStyle())
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("搜索应用 (本地 / 外部)...".localized)
                TextField("搜索应用 (本地 / 外部)...".localized, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isAppSearchFocused)
                Text(verbatim: "⌘F")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.primary.opacity(0.03))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))

            HStack(spacing: 2) {
                ForEach(AppConnectionFilter.allCases, id: \.self) { filter in
                    Button { appConnectionFilter = filter } label: {
                        Text(filter.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(appConnectionFilter == filter ? Color.white : .secondary)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(appConnectionFilter == filter ? Color.accentColor : .clear)
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(AppPressButtonStyle())
                    .accessibilityAddTraits(appConnectionFilter == filter ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.03))
            .clipShape(Capsule())
            .fixedSize()
            .onChange(of: appConnectionFilter) { _ in
                pruneHiddenAppSelections()
            }
            .onChange(of: searchText) { _ in
                pruneHiddenAppSelections()
            }
            .onChange(of: localAppFilter) { _ in
                pruneHiddenAppSelections()
            }

            Button {
                showSearchExclusion = true
            } label: {
                Label("排除外盘应用索引".localized, systemImage: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(operationState.isBusy || externalDriveURL == nil)
        }
    }

    private var isCurrentPageRefreshing: Bool {
        switch mainTab {
        case .apps: return localScanState.isScanning || externalScanState.isScanning
        case .dataDirs: return isDataDirsScanning
        case .customDirs: return isCustomDirsScanning
        case .tasks, .settings: return false
        }
    }

    private var cacheRefreshButton: some View {
        Button {
            switch mainTab {
            case .apps: scanBothApps(forceSizeRefresh: true)
            case .dataDirs: dataDirsRefreshTrigger += 1
            case .customDirs: customDirsRefreshTrigger += 1
            case .tasks, .settings: break
            }
        } label: {
            Group {
                if isCurrentPageRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
            }
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .disabled(operationState.blocksInteraction || isCurrentPageRefreshing || mainTab == .tasks || mainTab == .settings)
        .help("刷新缓存".localized)
        .accessibilityLabel("刷新缓存".localized)
    }

    private func pruneHiddenAppSelections() {
        selectedLocalApps.formIntersection(Set(filteredLocalApps.map(\.id)))
        selectedExternalApps.formIntersection(Set(filteredExternalApps.map(\.id)))
    }

    // MARK: - 应用页两个面板（拆出以减轻 body 的类型推断负担）

    private func localAppsPane(columnTrailingInset: CGFloat, nameLineLimit: Int) -> some View {
        let entries = filteredLocalApps.enumerated().map { AppListEntry(app: $0.element, index: $0.offset) }
        return VStack(spacing: 0) {
            HeaderView(
                title: "Mac 本地应用".localized,
                subtitle: localAppsSubtitle,
                icon: "desktopcomputer",
                iconColumnWidth: 40,
                appCount: entries.count,
                actionButtonText: "＋",
                onAction: addCustomLocalScanPath,
                onRefresh: { scanLocalApps(forceSizeRefresh: true) },
                isRefreshing: localScanState.isScanning,
                accessory: customLocalScanPaths.isEmpty ? nil : AnyView(localScanSourcesMenu)
            )

            if localAppFilter == .signatureReplaced {
                signatureReplacedFilterBanner
            }

            appListColumnHeader(sorting: $localAppSort, columnTrailingInset: columnTrailingInset)

            ZStack {
                AppSurfaceColors.content.ignoresSafeArea()

                if entries.isEmpty {
                    if localScanState.isScanning && localApps.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", text: "正在扫描...".localized)
                    } else {
                        EmptyStateView(icon: "doc.text.magnifyingglass", text: "未找到匹配应用".localized)
                    }
                } else {
                    List(selection: $selectedLocalApps) {
                        ForEach(entries) { entry in
                        let app = entry.app
                        let activeJob = activeJob(for: app)
                        AppRowView(
                            app: app,
                            nameLineLimit: nameLineLimit,
                            showsStatus: !localScanState.pendingIDs.contains(entry.id),
                            showDeleteLinkButton: true,
                            onDeleteLink: performDeleteLink,
                            onResign: { performSingleResign(app: $0) },
                            onRestoreSignature: performRestoreSignature,
                            onMoveOutWholeSymlink: performMoveOutWholeSymlink,
                            onRepairDock: performRepairDockShortcuts,
                            onRepairSignature: { signatureRepairApp = $0 },
                            activeTaskStatus: activeJob?.badgeStatus,
                            onViewTask: activeJob.map { job in { migrationTasks.openJobDetail(job) } }
                        )
                        .disabled(localApps.isEmpty)
                        .tag(entry.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        .modifier(AppListRowAppearance(
                            isSelected: selectedLocalApps.contains(entry.id),
                            index: entry.index
                        ))
                        .modifier(RowSeparatorVisibility())
                        }
                        Color.clear.frame(height: 48)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .modifier(ContentView.RowSeparatorVisibility())
                            .accessibilityHidden(true)
                    }
                    .listStyle(.plain)
                    .modifier(TransparentListBackground())
                }
            }


        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            ActionFooter(
                title: getMoveButtonTitle(),
                icon: "arrow.right",
                isEnabled: canMoveOut,
                columnTrailingInset: columnTrailingInset,
                action: performMoveOut
            )
        }
        .modifier(AppListPanelStyle())

    }

    private func externalAppsPane(columnTrailingInset: CGFloat, nameLineLimit: Int) -> some View {
        let filteredApps = filteredExternalApps
        let entries = filteredApps.enumerated().map { AppListEntry(app: $0.element, index: $0.offset) }
        let sizeSummary: String? = AppListDisplaySizeSummary(apps: filteredApps).headerText
        return VStack(spacing: 0) {
            HeaderView(
                title: "外部应用库".localized,
                subtitle: "",
                icon: "externaldrive.fill",
                iconColumnWidth: 40,
                appCount: entries.count,
                sizeSummary: sizeSummary,
                tint: .teal,
                onRefresh: { scanExternalApps(forceSizeRefresh: true) },
                isRefreshing: externalScanState.isScanning
            )

        appListColumnHeader(sorting: $externalAppSort, columnTrailingInset: columnTrailingInset)

        ZStack {
            AppSurfaceColors.content.ignoresSafeArea()

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

                }
            } else if entries.isEmpty {
                if externalScanState.isScanning && externalApps.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", text: "正在扫描...".localized)
                } else if !externalApps.isEmpty || !searchText.isEmpty {
                    EmptyStateView(icon: "doc.text.magnifyingglass", text: "未找到匹配应用".localized)
                } else {
                    EmptyStateView(icon: "folder", text: "空文件夹".localized)
                }
            } else {
                List(selection: $selectedExternalApps) {
                    ForEach(entries) { entry in
                    let app = entry.app
                    let activeJob = activeJob(for: app)
                    AppRowView(
                        app: app,
                        nameLineLimit: nameLineLimit,
                        showsStatus: !externalScanState.pendingIDs.contains(entry.id),
                        showDeleteLinkButton: false,
                        onDeleteLink: performDeleteLink,
                        onResign: { performSingleResign(app: $0) },
                        onRestoreSignature: performRestoreSignature,
                        onRepairSignature: { signatureRepairApp = $0 },
                        activeTaskStatus: activeJob?.badgeStatus,
                        onViewTask: activeJob.map { job in { migrationTasks.openJobDetail(job) } }
                    )
                    .disabled(externalApps.isEmpty)
                    .tag(entry.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .modifier(AppListRowAppearance(
                        isSelected: selectedExternalApps.contains(entry.id),
                        index: entry.index
                    ))
                    .modifier(RowSeparatorVisibility())
                    }
                        Color.clear.frame(height: 48)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .modifier(ContentView.RowSeparatorVisibility())
                            .accessibilityHidden(true)
                    }
                .listStyle(.plain)
                .modifier(TransparentListBackground())
            }
        }


    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottomTrailing) {
        HStack(spacing: 8) {
            Button(action: performBatchMoveBack) {
                Label(getMoveBackButtonTitle(), systemImage: "arrow.turn.up.left")
                    .frame(minWidth: 100, minHeight: 22)
            }
            .buttonStyle(AppListPrimaryButtonStyle(isSecondary: true))
            .disabled(!canMoveBack)

            Button(action: performLinkIn) {
                Label(getLinkButtonTitle(), systemImage: "link")
                    .frame(minWidth: 100, minHeight: 22)
            }
            .buttonStyle(AppListPrimaryButtonStyle())
            .disabled(!canLinkIn)
        }
        .modifier(AppListFooterStyle(columnTrailingInset: columnTrailingInset))
    }
    .modifier(AppListPanelStyle())
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
            if selectedDataDirsTab == .appDirs, let app = selectedDataDirsApp, app.isResigned {
                Button(action: { performRestoreSignature(app: app) }) {
                    Label("恢复原始签名".localized, systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.teal)
                .help("恢复选中应用的原始代码签名".localized)
            }


        }
    }

    /// 侧栏页面切换按钮。
    struct TabButton: View {
        let title: String
        var systemImage: String? = nil
        let isSelected: Bool
        var badgeCount: Int = 0
        var needsAttention: Bool = false
        let action: () -> Void

        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if needsAttention {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.orange)
                            .accessibilityLabel("需要处理".localized)
                            .help("需要处理".localized)
                    }
                    if badgeCount > 0 {
                        Text(badgeCount, format: .number)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovered ? Color.primary.opacity(0.04) : .clear)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : AppMotion.interaction, value: isHovered)
        }
    }

    // MARK: - 逻辑函数
    
    private func activeJob(for app: AppItem) -> MigrationJob? {
        migrationTasks.activeJob(overlappingAllPaths: [app.path, app.displayURL], includeObserved: true)
    }

    private var localMoveSelection: [AppItem] {
        localApps.filter { selectedLocalApps.contains($0.id) }
    }

    func getMoveButtonTitle() -> String {
        if localMoveSelection.contains(where: { $0.bodyMigrationPolicy == .localOnly }) { return "迁移到外部".localized }
        // 获取所有选中且可迁移的应用
        let validApps = selectedLocalApps.compactMap { id in
            localApps.first { $0.id == id }
        }.filter { !$0.isSystemApp && !$0.isRunning && $0.status != AppStatus.linked && activeJob(for: $0) == nil }
        
        if selectedLocalApps.isEmpty {
            return "迁移到外部".localized
        }

        if validApps.isEmpty {
            // 检查是否全是不可迁移的
            let selectedAppsData = selectedLocalApps.compactMap { id in localApps.first { $0.id == id } }
            if selectedAppsData.contains(where: { activeJob(for: $0) != nil }) { return "查看进度".localized }
            if selectedAppsData.contains(where: { $0.isSystemApp }) { return "含系统应用".localized }
            if selectedAppsData.contains(where: { $0.isRunning }) { return "含运行中应用".localized }
            if selectedAppsData.contains(where: { $0.status == AppStatus.linked }) { return "已链接".localized }
            return "迁移到外部".localized
        }

        if validApps.count == 1 {
            return "迁移到外部".localized
        }
        
        return "迁移 %lld 个应用".localizedFormat(Int64(validApps.count))
    }
    
    var canMoveOut: Bool {
        if localMoveSelection.contains(where: { $0.bodyMigrationPolicy == .localOnly }) { return true }
        guard externalDriveURL != nil else { return false }
        
        // 至少有一个可迁移的应用
        let validApps = selectedLocalApps.compactMap { id in
            localApps.first { $0.id == id }
        }.filter { !$0.isSystemApp && !$0.isRunning && $0.status != AppStatus.linked && activeJob(for: $0) == nil }
        
        return !validApps.isEmpty
    }
    
    var canLinkIn: Bool {
        // 至少有一个可链接的应用
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { ($0.status == AppStatus.unlinked || $0.status == AppStatus.external || $0.status == AppStatus.partialLinked) && activeJob(for: $0) == nil }
        
        return !validApps.isEmpty
    }

    var canMoveBack: Bool {
        !selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { !$0.isRunning && activeJob(for: $0) == nil }.isEmpty
    }
    
    func getLinkButtonTitle() -> String {
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { ($0.status == AppStatus.unlinked || $0.status == AppStatus.external || $0.status == AppStatus.partialLinked) && activeJob(for: $0) == nil }
        
        if selectedExternalApps.isEmpty || validApps.isEmpty {
            return "链接回本地".localized
        }
        
        if validApps.count == 1 {
            return "链接回本地".localized
        }
        
        return "链接 %lld 个应用".localizedFormat(Int64(validApps.count))
    }
    
    func getRunningApplications() -> [AppRunningState.RunningApplication] {
        NSWorkspace.shared.runningApplications.map {
            AppRunningState.RunningApplication(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
        }
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
        scanAppLists(local: true, external: false, forceSizeRefresh: forceSizeRefresh)
    }

    @MainActor
    func scanExternalApps(forceSizeRefresh: Bool = false) {
        scanAppLists(local: false, external: true, forceSizeRefresh: forceSizeRefresh)
    }

    @MainActor
    private func scanBothApps(forceSizeRefresh: Bool = false) {
        guard !operationState.isBusy else {
            prepareAppListSources(local: true, external: true)
            needsAppRescan = true
            return
        }
        needsAppRescan = false
        scanAppLists(local: true, external: true, forceSizeRefresh: forceSizeRefresh)
    }

    @MainActor
    private func prepareAppListSources(local: Bool, external: Bool) {
        func restore(_ pane: AppListCacheStore.Pane, from source: AppListCacheStore.Source) -> [AppItem] {
            let rows = AppListCacheStore.shared.load(pane, source: source, sizes: sizeCache)
            if !rows.isEmpty {
                AppLogger.shared.logContext("恢复首页应用清单", details: [("pane", pane.rawValue), ("count", String(rows.count))], level: "TRACE")
            }
            return rows
        }
        if local {
            let source = AppListCacheStore.Source([localAppsURL] + customLocalScanPaths.map { URL(fileURLWithPath: $0) })
            if localScanState.source != source {
                localApps.removeAll()
                selectedLocalApps.removeAll()
                localScanState.changeSource(to: source) { restore(.local, from: source) }
            }
        }
        if external {
            let source = AppListCacheStore.Source(externalDriveURL.map { [$0] } ?? [])
            if externalScanState.source != source {
                externalApps.removeAll()
                selectedExternalApps.removeAll()
                externalScanState.changeSource(to: source) { restore(.external, from: source) }
            }
        }
    }

    private struct PaneSizeWork {
        let isLocal: Bool
        let request: ScanRequest
        let misses: [(app: AppItem, mtime: Date?)]
    }

    @MainActor
    private func scanAppLists(local: Bool, external: Bool, forceSizeRefresh: Bool) {
        guard isVisible else { return }
        if !forceSizeRefresh, isExternalVolumeSuppressedAndMounted(externalDriveURL) {
            return
        }
        prepareAppListSources(local: local, external: external)
        let localRequest = local ? localScanState.begin(externalDirectory: externalDriveURL,
            customPaths: customLocalScanPaths, isManual: forceSizeRefresh) : nil
        let externalRequest = external ? externalScanState.begin(externalDirectory: externalDriveURL,
            customPaths: customLocalScanPaths, isManual: forceSizeRefresh) : nil
        guard localRequest != nil || externalRequest != nil else { return }
        let localPreviewCache = localApps.isEmpty ? sizeCache : nil
        let externalPreviewCache = externalApps.isEmpty ? sizeCache : nil
        let localRows = localApps.isEmpty ? localScanState.preview : localApps
        let externalRows = externalApps.isEmpty ? externalScanState.preview : externalApps
        let generation = AppMigrationService.maintenanceGeneration
        appScanTask?.cancel()
        appScanTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            let runningApplications = await MainActor.run { self.getRunningApplications() }
            guard !Task.isCancelled else { return }
            let runningURLs = Set(runningApplications.compactMap(\.bundleURL))
            await withTaskGroup(of: PaneSizeWork?.self) { group in
                if let request = localRequest {
                    if localPreviewCache != nil && !request.forceSizeRefresh {
                        group.addTask {
                            await self.verifyRestoredUpdates(localRows, request: request, isLocal: true)
                            return nil
                        }
                    }
                    group.addTask {
                        let apps = await self.discoverLocalApps(request: request, previous: localRows, runningURLs: runningURLs,
                            runningApplications: runningApplications, previewCache: localPreviewCache,
                            maintenanceGeneration: generation)
                        guard !Task.isCancelled else { return nil }
                        return await self.publishDiscoveredApps(apps, isLocal: true, request: request)
                    }
                }
                if let request = externalRequest {
                    if externalPreviewCache != nil && !request.forceSizeRefresh {
                        group.addTask {
                            await self.verifyRestoredUpdates(externalRows, request: request, isLocal: false)
                            return nil
                        }
                    }
                    group.addTask {
                        let apps = await self.discoverExternalApps(request: request, previous: externalRows, runningURLs: runningURLs,
                            runningApplications: runningApplications, previewCache: externalPreviewCache)
                        guard !Task.isCancelled else { return nil }
                        return await self.publishDiscoveredApps(apps, isLocal: false, request: request)
                    }
                }
                // Discovery publishes independently. Size misses share the existing four-worker budget.
                let scanner = AppScanner()
                for await work in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let work {
                        await self.computeAndStoreSizes(misses: work.misses, isLocal: work.isLocal,
                            scanner: scanner, request: work.request)
                    }
                }
            }
        }
    }

    nonisolated private func verifyRestoredUpdates(_ rows: [AppItem], request: ScanRequest, isLocal: Bool) async {
        var verified: [String: AppItem] = [:]
        for row in rows {
            if let cached = row.updateInspection, let current = cached.verifiedPreview(row) {
                verified[row.id] = current
            }
        }
        guard !verified.isEmpty else { return }
        let updates = verified
        await MainActor.run {
            guard isCurrentScan(request, isLocal: isLocal) else { return }
            let pending = isLocal ? localScanState.pendingIDs : externalScanState.pendingIDs
            let count = updates.keys.filter(pending.contains).count
            guard count > 0 else { return }
            if isLocal { localScanState.publishCachedUpdates(updates, for: request) }
            else { externalScanState.publishCachedUpdates(updates, for: request) }
            AppLogger.shared.logContext("首页预览复用更新方式",
                details: [("pane", isLocal ? "local" : "external"), ("count", String(count))], level: "TRACE")
        }
    }

    nonisolated private func homeScanner(previous: [AppItem], request: ScanRequest) -> AppScanner {
        var records: [String: AppUpdateInspection] = [:]
        if !request.forceSizeRefresh {
            for row in previous { records[row.id] = row.updateInspection }
        }
        return AppScanner(cachedUpdates: records)
    }

    nonisolated private func discoverLocalApps(request: ScanRequest, previous: [AppItem], runningURLs: Set<URL>,
                                   runningApplications: [AppRunningState.RunningApplication],
                                   previewCache: [String: CachedAppSize]?, maintenanceGeneration: UInt64) async -> [AppItem] {
        let scanner = homeScanner(previous: previous, request: request)
        var apps: [AppItem] = []
        for root in [localAppsURL] + request.customPaths.map({ URL(fileURLWithPath: $0) }) {
            guard await MainActor.run(body: { isCurrentScan(request, isLocal: true) }) else { return [] }
            let batch = await scanner.scanLocalApps(at: root, runningAppURLs: runningURLs,
                externalAppsDir: request.externalDirectory, runningApplications: runningApplications,
                onProgress: previewPublisher(for: request, isLocal: true, completed: apps, cache: previewCache))
            apps = mergeLocalApps(apps, with: batch)
        }

        for app in apps {
            guard await MainActor.run(body: { isCurrentScan(request, isLocal: true) && !operationState.isBusy }) else { break }
            _ = AppPortalMaintenance.refreshEntries(at: app.path, expectedGeneration: maintenanceGeneration)
        }
        guard await MainActor.run(body: { isCurrentScan(request, isLocal: true) }) else { return [] }
        do { try AppSearchRecordStore.shared.reconcileLocalPresence() }
        catch { AppLogger.shared.logError("核对本地入口搜索状态失败", error: error) }
        return apps
    }

    nonisolated private func discoverExternalApps(request: ScanRequest, previous: [AppItem], runningURLs: Set<URL>,
                                      runningApplications: [AppRunningState.RunningApplication],
                                      previewCache: [String: CachedAppSize]?) async -> [AppItem] {
        guard let root = request.externalDirectory else { return [] }
        let scanner = homeScanner(previous: previous, request: request)
        var apps: [AppItem] = []
        for localDir in [localAppsURL] + request.customPaths.map({ URL(fileURLWithPath: $0) }) {
            guard await MainActor.run(body: { isCurrentScan(request, isLocal: false) }) else { return [] }
            let batch = await scanner.scanExternalApps(at: root, localAppsDir: localDir,
                runningAppURLs: runningURLs, runningApplications: runningApplications,
                onProgress: previewPublisher(for: request, isLocal: false, completed: apps, cache: previewCache))
            apps = mergeExternalApps(apps, with: batch)
        }
        return apps
    }

    nonisolated private func previewPublisher(for request: ScanRequest, isLocal: Bool, completed: [AppItem],
                                  cache: [String: CachedAppSize]?) -> (([String: AppItem]) -> Void)? {
        guard let cache else { return nil }
        let previous = fillCachedSizes(into: completed, cache: cache, isLocal: isLocal).filled
        var directory: [String: AppItem] = [:]
        return { changes in
            for (key, var app) in changes {
                if let entry = cache[app.id] {
                    let mtime = self.bundleModificationDate(for: app)
                    _ = self.applyCachedSize(entry, to: &app, mtime: mtime, isLocal: isLocal)
                }
                directory[key] = app
            }
            let current = Array(directory.values)
            let rows = previous.isEmpty ? current : (isLocal
                ? self.mergeLocalApps(previous, with: current) : self.mergeExternalApps(previous, with: current))
            DispatchQueue.main.async {
                guard self.isCurrentScan(request, isLocal: isLocal) else { return }
                if isLocal {
                    self.localScanState.publishPreview(rows, for: request)
                } else {
                    self.externalScanState.publishPreview(rows, for: request)
                }
            }
        }
    }

    nonisolated private func mergeLocalApps(_ existing: [AppItem], with scanned: [AppItem]) -> [AppItem] {
        guard !existing.isEmpty else { return scanned }
        let paths = Set(existing.map(\.id))
        return existing + scanned.filter { !paths.contains($0.id) }
    }

    nonisolated func mergeExternalApps(_ existingApps: [AppItem], with scannedApps: [AppItem]) -> [AppItem] {
        var mergedApps = existingApps
        var indexByPath: [String: Int] = [:]
        for (index, app) in existingApps.enumerated() { indexByPath[app.id] = index }
        for app in scannedApps {
            let path = app.id
            if let index = indexByPath[path] {
                let isRunning = mergedApps[index].isRunning || app.isRunning
                if shouldPreferExternalApp(app, over: mergedApps[index]) {
                    mergedApps[index] = app
                }
                mergedApps[index].isRunning = isRunning
            } else {
                indexByPath[path] = mergedApps.count
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
    
    /// 目录 mtime 仅用于展示缓存判断，手动刷新始终重测包内内容。
    typealias CachedAppSize = AppSizeCacheStore.Entry

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
            let valid = applyCachedSize(cache[filled[i].id], to: &filled[i], mtime: currentMtime, isLocal: isLocal)
            if forceRefresh || !valid {
                misses.append((filled[i], currentMtime))
            }
        }
        return (filled, misses)
    }

    nonisolated private func applyCachedSize(_ entry: CachedAppSize?, to app: inout AppItem, mtime: Date?, isLocal: Bool) -> Bool {
        guard let entry, let mtime, entry.mtime == mtime,
              entry.isLocalPortal == (isLocal && app.status == AppStatus.linked) else { return false }
        app.size = entry.size
        app.sizeBytes = entry.bytes
        return true
    }

    /// Bound independent size reads; publish each completed row immediately.
    nonisolated private func computeAndStoreSizes(
        misses: [(app: AppItem, mtime: Date?)],
        isLocal: Bool,
        scanner: AppScanner,
        request: ScanRequest
    ) async {
        guard !Task.isCancelled,
              await MainActor.run(body: { self.isCurrentScan(request, isLocal: isLocal) }) else { return }
        await withTaskGroup(of: (Int, Int64).self) { group in
            var nextIndex = 0
            for _ in 0..<min(4, misses.count) {
                let index = nextIndex
                let app = misses[index].app
                group.addTask { (index, scanner.calculateDisplayedSize(for: app, isLocalEntry: isLocal)) }
                nextIndex += 1
            }
            for await (index, bytes) in group {
                let miss = misses[index]
                let applied = await MainActor.run {
                    guard !Task.isCancelled, self.isCurrentScan(request, isLocal: isLocal) else { return false }
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
                    return true
                }
                guard applied else { group.cancelAll(); return }
                if nextIndex < misses.count {
                    let index = nextIndex
                    let app = misses[index].app
                    group.addTask { (index, scanner.calculateDisplayedSize(for: app, isLocalEntry: isLocal)) }
                    nextIndex += 1
                }
            }
        }
        // 空列表或全部命中缓存时也必须结束进度；过期请求不能结束新一轮扫描。
        await MainActor.run {
            guard !Task.isCancelled, self.isCurrentScan(request, isLocal: isLocal) else { return }
            if !misses.isEmpty || request.forceSizeRefresh {
                let updatedAt = Date()
                AppSizeCacheStore.shared.save(entries: self.sizeCache, updatedAt: updatedAt)
            }
            if isLocal {
                self.localScanState.finish(request)
            } else {
                self.externalScanState.finish(request)
            }
        }
    }

    /// 统一的体积应用入口：先用缓存填充列表后赋值（命中项瞬时显示、无“计算中”闪烁），
    /// 再在后台计算缺失/失效项并写回缓存。所有扫描路径都走这里。
    @MainActor
    private func isCurrentScan(_ request: ScanRequest, isLocal: Bool) -> Bool {
        isVisible
            && (isLocal ? localScanState.request : externalScanState.request) == request
            && externalDriveURL == request.externalDirectory
            && customLocalScanPaths == request.customPaths
    }

    nonisolated private func publishDiscoveredApps(_ apps: [AppItem], isLocal: Bool, request: ScanRequest) async -> PaneSizeWork? {
        guard await MainActor.run(body: { self.isCurrentScan(request, isLocal: isLocal) }) else { return nil }
        let cache = await MainActor.run { self.sizeCache }
        let (filled, misses) = fillCachedSizes(into: apps, cache: cache, isLocal: isLocal,
                                             forceRefresh: request.forceSizeRefresh)
        AppLogger.shared.logContext(isLocal ? "本地应用扫描完成" : "外部应用扫描完成", details: [
            ("count", String(apps.count)), ("size_remeasure_count", String(misses.count)),
            ("status_summary", summarizeStatuses(for: apps))
        ], level: "TRACE")
        let committed = await MainActor.run {
            guard self.isCurrentScan(request, isLocal: isLocal) else { return false }
            if let source = (isLocal ? self.localScanState : self.externalScanState).source {
                AppListCacheStore.shared.save(filled, pane: isLocal ? .local : .external, source: source,
                                              context: self.updateRecommendationContext)
            }
            if isLocal {
                self.localScanState.clearPreview()
                self.localApps = filled
                self.selectedLocalApps.formIntersection(Set(self.filteredLocalApps.map(\.id)))
                // 兜底路径：启动快检之后本会话新签名的应用，仍然会在扫描完成时提醒一次。
                self.presentSignatureRepairReminderIfNeeded(
                    apps: filled.filter(\.signatureReplaced).map(\.signatureRepairEntry)
                )
            } else {
                self.externalScanState.clearPreview()
                self.externalApps = filled
                self.selectedExternalApps.formIntersection(Set(self.filteredExternalApps.map(\.id)))
            }
            if misses.isEmpty {
                if isLocal { self.localScanState.finish(request) } else { self.externalScanState.finish(request) }
            }
            self.scheduleRunningAppsRefresh()
            return true
        }
        guard committed, !misses.isEmpty || request.forceSizeRefresh else { return nil }
        return PaneSizeWork(isLocal: isLocal, request: request, misses: misses)
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
        return base + " + " + "%lld 个目录".localizedFormat(Int64(customLocalScanPaths.count))
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
        scanBothApps()
    }

    func removeCustomLocalScanPath(_ path: String) {
        customLocalScanPaths = UserDefaults.standard.stringArray(forKey: "customLocalScanPaths") ?? []
        customLocalScanPaths.removeAll { $0 == path }
        UserDefaults.standard.set(customLocalScanPaths, forKey: "customLocalScanPaths")
        startMonitoringLocal()
        scanBothApps()
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
            applications: getRunningApplications()
        )
    }

    /// Recompute `isRunning` in place without resetting concurrent size calculations
    /// and without being blocked by an active/paused migration operation.
    @MainActor
    private func scheduleRunningAppsRefresh() {
        guard isVisible, !(localApps.isEmpty && externalApps.isEmpty) else { return }
        runningStateGeneration &+= 1
        let generation = runningStateGeneration
        runningStateRefreshTask?.cancel()
        let localSnapshot = localApps
        let externalSnapshot = externalApps
        let runningSnapshot = getRunningApplications()
        runningStateRefreshTask = Task.detached(priority: .userInitiated) {
            let updatedLocal = AppRunningState.applyingRunningState(to: localSnapshot, applications: runningSnapshot)
            guard !Task.isCancelled else { return }
            let updatedExternal = AppRunningState.applyingRunningState(to: externalSnapshot, applications: runningSnapshot)
            guard !Task.isCancelled else { return }
            let localMap = Dictionary(updatedLocal.map { ($0.id, $0.isRunning) }, uniquingKeysWith: { $0 || $1 })
            let externalMap = Dictionary(updatedExternal.map { ($0.id, $0.isRunning) }, uniquingKeysWith: { $0 || $1 })
            await MainActor.run {
                guard self.isVisible, self.runningStateGeneration == generation else { return }
                for index in self.localApps.indices {
                    if let running = localMap[self.localApps[index].id], self.localApps[index].isRunning != running {
                        self.localApps[index].isRunning = running
                    }
                }
                for index in self.externalApps.indices {
                    if let running = externalMap[self.externalApps[index].id], self.externalApps[index].isRunning != running {
                        self.externalApps[index].isRunning = running
                    }
                }
            }
        }
    }

    /// Fresh discovery for the board must not depend on the main pane's scan finishing.
    /// AppScanner and entries(at:) only read; portal maintenance is intentionally absent.
    private func searchExclusionSnapshot(root: URL, localDirectories: [URL]) async
        -> (apps: [AppItem], entries: [AppPortalMaintenance.Entry]) {
        let scanner = AppScanner()
        var apps: [AppItem] = []
        var entries: [AppPortalMaintenance.Entry] = []
        for directory in localDirectories {
            apps = mergeExternalApps(apps, with: await scanner.scanExternalApps(
                at: root, localAppsDir: directory, grouping: .filePath
            ))
            let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                         options: .skipsHiddenFiles)) ?? []
            entries += children.flatMap { AppPortalMaintenance.entries(at: $0) }
        }
        return (apps, entries)
    }

    @MainActor
    private func loadExternalAppSearchStatus() async -> AppSearchExclusionReport {
        guard let root = externalDriveURL else { return AppSearchExclusionReport() }
        let directories = [localAppsURL] + customLocalScanPaths.map { URL(fileURLWithPath: $0) }
        return await Task.detached(priority: .userInitiated) {
            let snapshot = await searchExclusionSnapshot(root: root, localDirectories: directories)
            return AppSearchExclusionService.inspect(apps: snapshot.apps, externalRoot: root, localEntries: snapshot.entries)
        }.value
    }

    @MainActor
    private func excludeExternalAppsFromSearch() async -> AppSearchExclusionReport {
        guard let root = externalDriveURL, let token = operationState.begin() else {
            return AppSearchExclusionReport(operationError: "正在执行其他应用操作，请稍后重试。".localized)
        }
        localScanState.invalidate()
        externalScanState.invalidate()
        defer {
            operationState.finish(token)
            startMonitoringExternal(url: root)
            scanBothApps()
        }
        let directories = [localAppsURL] + customLocalScanPaths.map { URL(fileURLWithPath: $0) }
        let task = Task.detached(priority: .userInitiated) {
            let snapshot = await searchExclusionSnapshot(root: root, localDirectories: directories)
            let current = AppSearchExclusionService.inspect(apps: snapshot.apps, externalRoot: root, localEntries: snapshot.entries)
            if current.operationError != nil { return current }
            var report = AppSearchExclusionReport()
            for app in snapshot.apps {
                if Task.isCancelled {
                    report.operationError = "操作已停止，可从当前记录继续。".localized
                    break
                }
                if let observed = current.entries.first(where: { $0.id == app.id }),
                   observed.outcome != .pending && observed.outcome != .dockWarning {
                    report.entries.append(observed)
                    continue
                }
                do {
                    let localURLs = snapshot.entries.filter { $0.externalURL.path == app.path.standardizedFileURL.path }.map(\.localURL)
                    let result = try await AppMigrationService().excludeFromSearch(
                        app: app, externalRoot: root, localEntries: localURLs)
                    let message = result.dockSynchronized
                        ? "应用存储位置已排除索引。".localized
                        : "应用存储位置已排除索引，Dock 快捷方式同步失败。".localized
                    report.entries.append(.init(id: app.id, name: app.displayName, iconURL: result.destination,
                        outcome: result.dockSynchronized ? .completed : .dockWarning, message: message))
                } catch is CancellationError {
                    report.operationError = "操作已停止，可从当前记录继续。".localized
                    break
                } catch {
                    report.entries.append(.init(id: app.id, name: app.displayName, iconURL: app.displayURL,
                                                outcome: .failed, message: error.localizedDescription))
                    AppLogger.shared.logError("排除外盘应用索引失败", error: error, relatedURLs: [("app", app.path)])
                }
            }
            return report
        }
        operationState.registerCancellation(for: token) { task.cancel() }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// Publish completed operations before scheduling a fresh scan.
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
        scheduleRunningAppsRefresh()
    }

    private func enqueueAppTransfer(_ app: AppItem, destination: URL, restoring: Bool = false,
                                    wholeSymlink: Bool = false, lockExternal: Bool = false,
                                    acceptedRiskBundles: Set<URL> = [],
                                    replacementChoice: AppMigrationService.ReplacementChoice? = nil,
                                    presentDetails: Bool = true) {
        let title = (restoring ? "还原应用".localized : "迁移应用".localized) + " · " + app.displayName
        MigrationTaskCenter.shared.submit(title: title, category: .apps,
            resources: MigrationResources.application(paths: [app.path, app.displayURL, destination], appURL: app.displayURL),
            presentDetails: presentDetails, operation: { progress in
                progress.setDirectory(app.path)
                try await MigrationExecution.control?.checkpointAsync()
                if restoring {
                    let result = try await AppMigrationService().moveBack(app: app, localDestinationURL: destination,
                        progressHandler: { progress.update($0) })
                    await MainActor.run {
                        recordCompletedTransfer(.movedBack(app, localDestination: destination,
                            externalSourceRemains: result.externalSourceRemains,
                            retiredLocalURLs: result.retiredLocalPortalURLs))
                    }
                    return result.transferResult.pendingMessage
                }
                if app.isAppStoreApp && AppMigrationService.isMASExternalInstallSupported {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                }
                let running = await MigrationApplicationState.isRunning(appURL: app.displayURL)
                let service: AppMigrationService
                if wholeSymlink {
                    service = AppMigrationService(portalCreationOverride: { item, external in
                        try FileManager.default.createSymbolicLink(at: item.path, withDestinationURL: external)
                    })
                } else { service = AppMigrationService() }
                let result = try await service.moveAndLink(appToMove: app, destinationURL: destination,
                    isRunning: running, lockExternal: lockExternal, acceptedRiskBundles: acceptedRiskBundles,
                    replacementChoice: replacementChoice,
                    deleteSourceFallback: AppMigrationService.removeItemViaFinder(at:),
                    progressHandler: { progress.update($0) })
                await MainActor.run {
                    recordCompletedTransfer(.movedOut(app, destination: destination,
                        isMASExternal: !wholeSymlink && app.isAppStoreApp && AppMigrationService.isMASExternalInstallSupported))
                }
                return result.pendingMessage
            }, completion: { scanBothApps() })
    }

    func performMoveOutWholeSymlink(_ app: AppItem) {
        if presentAppPortsMigrationNotice(for: [app], onContinue: { _ in }) { return }
        if let job = activeJob(for: app) { migrationTasks.openJobDetail(job); return }
        guard let dest = externalDriveURL else { return }
        prepareAppTransfers([app], destination: dest, wholeSymlink: true)
    }

    func deleteLink(app: AppItem) throws {
        // Capture targets while the entry still exists. Search exclusion outlives deletion.
        do { try AppPortalMaintenance.rememberEntries(at: app.path) }
        catch { AppLogger.shared.logError("保存删除前的应用搜索记录失败", error: error) }
        try AppMigrationService().deleteLink(app: app)
        do { try AppPortalMaintenance.recordDeletion(at: app.path) }
        catch { AppLogger.shared.logError("保存入口删除后的搜索状态失败", error: error) }
    }

    private func presentAppPortsMigrationNotice(for apps: [AppItem], onContinue: @escaping ([AppItem]) -> Void) -> Bool {
        guard let notice = Self.appPortsMigrationNotice(for: apps, service: AppMigrationService(), hasDestination: externalDriveURL != nil, onContinue: onContinue) else { return false }
        appMigrationRiskRequest = notice
        return true
    }

    static func appPortsMigrationNotice(for apps: [AppItem], service: AppMigrationService, hasDestination: Bool,
                                        onContinue: @escaping ([AppItem]) -> Void) -> WarningSheetRequest? {
        let others = apps.filter { service.appPortsBundle(in: $0) == nil }
        guard others.count < apps.count else { return nil }
        let actions = others.isEmpty || !hasDestination ? [] : [WarningAction("仅迁移其他应用".localized, style: .preferred, isDefault: true) {
            onContinue(others)
        }]
        return WarningSheetRequest(title: "AppPorts 需要保留在本机".localized, icon: "internaldrive", tint: .accentColor,
            intro: UpdateAvailability.appPorts.explanation, cancelTitle: actions.isEmpty ? "好".localized : "取消".localized, actions: actions)
    }

    func performMoveOut() {
        let selected = localMoveSelection
        if presentAppPortsMigrationNotice(for: selected, onContinue: { others in
            DispatchQueue.main.async { performMoveOut(selectedApps: others) }
        }) { return }
        performMoveOut(selectedApps: selected)
    }

    private func performMoveOut(selectedApps: [AppItem]) {
        guard let dest = externalDriveURL else { return }
        
        // 读取用户设置（macOS 15.1+ 自动启用）
        let masSupported = AppMigrationService.isMASExternalInstallSupported
        let allowAppStoreMigration = masSupported || UserDefaults.standard.bool(forKey: "allowAppStoreMigration")
        let allowIOSAppMigration = masSupported || UserDefaults.standard.bool(forKey: "allowIOSAppMigration")
        
        // 获取所有选中且可迁移的应用
        let validApps = selectedApps.filter { app in
            // 基本过滤条件
            guard !app.isSystemApp && !app.isRunning && app.status != AppStatus.linked && activeJob(for: app) == nil else { return false }
            
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
        let skippedApps = selectedApps.filter { app in
            guard !app.isSystemApp && app.status != AppStatus.linked else { return false }
            
            if app.isIOSApp && !allowIOSAppMigration {
                return true
            }
            if app.isAppStoreApp && !allowAppStoreMigration {
                return true
            }
            return false
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

    /// 校验通过后的迁移收尾：先处理目标存储能力提示，再处理自更新应用确认。
    func proceedWithMigration(
        validApps: [AppItem],
        dest: URL,
        skipStorageLimitationCheck: Bool = false
    ) {
        // 目标盘存不住应用需要的元数据时先说明代价；只提示，不阻断。
        if !skipStorageLimitationCheck,
           storageLimitationRequest == nil,
           let capabilities = StorageCapabilityProbe.probe(destination: dest),
           !capabilities.missing.isEmpty {
            pendingStorageLimitationApps = validApps
            storageLimitationRequest = makeStorageLimitationRequest(capabilities, dest: dest)
            return
        }

        prepareAppTransfers(validApps, destination: dest)
    }

    /// 组装「App Store 应用外部安装」引导弹窗的内容快照。
    private func makeMASGuidanceRequest() -> WarningSheetRequest {
        appStoreInstall.makeGuidanceRequest(onOpenAppStore: AppStoreExternalInstallSection.openAppStoreSettings) {
            appStoreInstall.refresh(for: externalDriveURL)
            if appStoreInstall.state == .ready { scanExternalApps() }
            else {
                DispatchQueue.main.async {
                    masGuidanceRequest = makeMASGuidanceRequest()
                }
            }
        }
    }

    private func refreshMASGuidance() {
        appStoreInstall.refresh(for: externalDriveURL)
        if !appStoreInstall.shouldPresentGuidance {
            masGuidanceRequest = nil
            return
        }
        guard mainTab != .settings, !operationState.blocksInteraction,
              masGuidanceRequest == nil, legacyPermissionResetRequest == nil else { return }
        masGuidanceRequest = makeMASGuidanceRequest()
    }

    /// 组装「证书更新后重新授予系统权限」引导弹窗的内容快照。
    private func makeLegacyPermissionResetRequest(for prompt: LegacyPermissionResetter.ResetPrompt) -> WarningSheetRequest {
        var bullets: [WarningBullet] = []
        if prompt.permissions.contains(.appManagement) {
            bullets.append(WarningBullet(
                "app.badge.checkmark",
                "App 管理权限：用于迁移、替换或还原“应用程序”文件夹中的应用。".localized
            ))
        }
        if prompt.permissions.contains(.fullDiskAccess) {
            bullets.append(WarningBullet(
                "lock.shield",
                "完全磁盘访问权限：用于读取和迁移受系统保护的应用数据目录。".localized
            ))
        }

        let detail: String
        if prompt.permissions.contains(.fullDiskAccess) {
            detail = "若系统设置中仍看到已开启的旧版 AppPorts，请在“准备情况”中点击“清理旧版授权记录”，或选中旧条目点左下角“-”移除后再重新拖入。".localized
        } else {
            detail = "前往设置后，将悬浮提示中的 AppPorts 图标拖入列表并打开开关即可；若仍见已开启的旧条目，请先点“-”移除再重新添加。".localized
        }

        let primaryAction: WarningAction
        if prompt.permissions == [.appManagement] {
            primaryAction = WarningAction("前往「App 管理」设置".localized, style: .preferred, isDefault: true) {
                FullDiskAccessGuide.shared.openSettings(for: .appManagement, dismiss: {
                    legacyPermissionResetRequest = nil
                })
            }
        } else if prompt.permissions == [.fullDiskAccess] {
            primaryAction = WarningAction("前往「完全磁盘访问权限」设置".localized, style: .preferred, isDefault: true) {
                FullDiskAccessGuide.shared.openSettings(for: .fullDiskAccess, dismiss: {
                    legacyPermissionResetRequest = nil
                })
            }
        } else {
            primaryAction = WarningAction("打开准备情况检查".localized, style: .preferred, isDefault: true) {
                DispatchQueue.main.async {
                    showLegacyReadinessSheet = true
                }
            }
        }

        return WarningSheetRequest(
            title: "需要重新授予系统权限".localized,
            icon: "checkmark.shield.fill",
            tint: .orange,
            intro: "检测到 AppPorts 的签名证书已更新，旧版本留下的系统权限记录已不再适用。AppPorts 已尝试自动清理失效的旧记录，请前往系统设置重新授予以下权限：".localized,
            bullets: bullets,
            detail: detail,
            cancelTitle: "稍后再说".localized,
            actions: [primaryAction]
        )
    }

    /// 组装「受保护应用」迁移预警的内容快照。
    private func makeProtectedAppsRequest() -> WarningSheetRequest {
        let names = pendingProtectedApps.map { $0.displayName }.localizedListJoined
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
                        DispatchQueue.main.async {
                            proceedWithMigration(validApps: apps, dest: dest)
                        }
                    }
                }
            ]
        )
    }

    /// 组装「目标存储无法保存部分应用信息」提示。
    private func makeStorageLimitationRequest(_ capabilities: StorageCapabilities, dest: URL) -> WarningSheetRequest {
        let driveName = MountMigrationGuidance.driveName(for: dest.path)
        let items = capabilities.missing.map { $0.localizedDescription }.joined(separator: "\n")
        AppLogger.shared.logContext(
            "迁移目标无法保存部分应用信息",
            details: [
                ("destination", dest.path),
                ("drive_name", driveName),
                ("missing", capabilities.missing.map(\.rawValue).joined(separator: ","))
            ],
            level: "WARN"
        )
        return WarningSheetRequest(
            title: "迁移目标无法保存部分应用信息".localized,
            tint: .orange,
            intro: String(format: "目标磁盘「%@」不支持以下项目：\n\n%@\n\n迁移后应用仍可正常打开和使用，应用签名校验也仍然通过。但上面这些信息无法保留：文件权限会变成磁盘的固定默认值，部分应用内部共用的文件会各存一份（占用更多空间），少数应用的自定义图标等资源可能缺失。\n\n如果这个应用带有需要管理员权限的后台服务，迁移后可能无法正常工作。这种情况建议改用 APFS 格式的磁盘。".localized, driveName, items),
            documentationURL: DocumentationLink.url(page: "storage-capabilities", anchor: "summary"),
            onCancel: { pendingStorageLimitationApps = [] },
            actions: [
                WarningAction("仍要迁移".localized, style: .preferred) {
                    let apps = pendingStorageLimitationApps
                    pendingStorageLimitationApps = []
                    storageLimitationRequest = nil
                    DispatchQueue.main.async {
                        proceedWithMigration(
                            validApps: apps,
                            dest: dest,
                            skipStorageLimitationCheck: true
                        )
                    }
                }
            ]
        )
    }

    /// 组装「外部副本可能已降级」提示。
    ///
    /// A restore copies the bundle *from* the external volume. If that volume
    /// could not store ACLs, hard links, resource forks or permission bits, the
    /// copy it holds was written without them — the loss happened during the
    /// migration and restoring cannot recover it. Say so before the user acts,
    /// because afterwards the external original is deleted and the gap becomes
    /// permanent.
    private func makeDegradedRestoreRequest(apps: [AppItem], source: URL,
                                            capabilities: StorageCapabilities? = nil) -> WarningSheetRequest {
        let names = apps.map { $0.displayName }.localizedListJoined
        let driveName = MountMigrationGuidance.driveName(for: source.path)
        let resolvedCapabilities = capabilities ?? StorageCapabilityProbe.probe(destination: source)
        let items = (resolvedCapabilities?.missing ?? []).map { $0.localizedDescription }.joined(separator: "\n")
        AppLogger.shared.logContext(
            "还原的外部副本可能已降级",
            details: [
                ("source", source.path),
                ("drive_name", driveName),
                ("apps", names),
                ("missing", capabilities?.missing.map(\.rawValue).joined(separator: ",") ?? "(unknown)")
            ],
            level: "WARN"
        )
        return WarningSheetRequest(
            title: "外部存储上的应用包可能已降级".localized,
            tint: .orange,
            intro: String(format: "以下应用目前存放在「%@」上，这块磁盘不支持以下项目：\n\n%@\n\n这些应用是在迁出时被复制到这里的，当时就已经无法保留上述信息。还原会把这份副本复制回本机，但无法补回已经丢失的部分——还原完成后，外部原件会被删除，这些缺失将变成永久的。\n\n如果这些应用对权限或访问控制有要求，建议不要在此时还原，而是重新安装官方版本。".localized, driveName, items),
            documentationURL: DocumentationLink.url(page: "storage-capabilities", anchor: "degraded"),
            onCancel: { pendingDegradedRestoreApps = [] },
            actions: [
                WarningAction("仍要还原".localized, style: .preferred) {
                    let pending = pendingDegradedRestoreApps
                    pendingDegradedRestoreApps = []
                    degradedRestoreRequest = nil
                    if pending.count == 1 { executeMoveBack(app: pending[0]) }
                    else { executeBatchMoveBack(validApps: pending) }
                }
            ]
        )
    }

    /// 组装「自更新应用迁移」确认弹窗的内容快照。
    private func confirmUpdateProtection(for apps: [AppItem], onChoice: @escaping (Bool) -> Void) {
        guard let selection = UpdateProtectionSelection(apps: apps, service: AppMigrationService(), onChoice: onChoice) else {
            onChoice(false)
            return
        }
        updateProtectionSelection = selection
    }

    struct UpdateProtectionSelection: Identifiable {
        let id = UUID()
        let names: String
        let routes: [(route: AppUpdateRoute, beforeStoreMigration: Bool)]
        let onChoice: (Bool) -> Void

        init?(apps: [AppItem], service: AppMigrationService, onChoice: @escaping (Bool) -> Void) {
            var names: [String] = []
            var routes: [(AppUpdateRoute, Bool)] = []
            for app in apps {
                let bundles = service.updateConfirmationBundles(for: app)
                if bundles.isEmpty { continue }
                names.append(app.displayName)
                for url in bundles {
                    let route: AppUpdateRoute
                    if case .success(let identity) = AppIdentityResolver.resolve(at: url), identity.bundleIsLocked == false {
                        route = AppUpdateRoute.inspect(identity)
                    } else {
                        route = .unknown
                    }
                    routes.append((route, app.willMigrateToStoreDirectory))
                }
            }
            guard !routes.isEmpty else { return nil }
            self.names = names.localizedListJoined
            self.routes = routes
            self.onChoice = onChoice
        }
    }

    private struct UpdateProtectionDialog: View {
        let selection: UpdateProtectionSelection
        let dismiss: () -> Void
        @Environment(\.updateRecommendation) private var context

        var body: some View {
            WarningSheet(ContentView.updateProtectionRequest(for: selection, context: context), onResolve: dismiss)
        }
    }

    static func updateProtectionRequest(for selection: UpdateProtectionSelection,
                                        context: UpdateRecommendationContext) -> WarningSheetRequest {
        let recommended = selection.routes.allSatisfy {
            $0.route.availability(in: context, beforeStoreMigration: $0.beforeStoreMigration).isAvailable
        }
        let introduction = updateMigrationIntroduction(names: selection.names)
        return WarningSheetRequest(
            title: "自更新应用迁移".localized,
            icon: "arrow.triangle.2.circlepath",
            tint: .orange,
            intro: introduction.plain,
            introText: introduction.text,
            documentationURL: DocumentationLink.url(page: "blog/how-updates-work", anchor: "migration"),
            actions: [
                WarningAction("锁定迁移".localized) {
                    selection.onChoice(true)
                },
                WarningAction(recommended ? "非锁定迁移（推荐）".localized : "非锁定迁移".localized,
                              style: recommended ? .preferred : .normal, isDefault: recommended) {
                    selection.onChoice(false)
                }
            ]
        )
    }

    private static func updateMigrationIntroduction(names: String) -> (plain: String, text: Text) {
        let template = "以下应用的更新方式可能受到迁移影响：\n\n%@\n\n• 非锁定迁移：不对应用包加锁，可尝试继续使用应用内更新。在%@中开启“应用更新守护”后，AppPorts 可协助处理更新异常，但无法保证所有应用都能处理成功。\n\n• 锁定迁移：对应用包加锁，应用内更新可能受限。需要更新时，可先通过 AppPorts 迁回本机。\n\n实际更新效果取决于应用自身的更新方式。".localized
        let settings = "设置".localized
        let marker = UUID().uuidString
        let parts = String(format: template, names, marker).components(separatedBy: marker)
        let plain = String(format: template, names, settings)
        guard parts.count == 2 else { return (plain, Text(plain)) }
        let prefix = parts[0].hasSuffix(" ") ? String(parts[0].dropLast()) : parts[0]
        let text = Text(prefix + "\u{202F}") + Text(Image(systemName: "gearshape")) + Text("\u{202F}" + settings) + Text(parts[1])
        return (plain, text)
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

    
    /// Resolve all version choices before creating any candidate in this batch.
    /// The service revalidates the selected source and target under its lock.
    private func confirmUnrecognizedAppReplacements(
        apps: [AppItem], destination: URL,
        completion: @escaping ([String: AppMigrationService.ReplacementChoice]) -> Void
    ) {
        do {
            let service = AppMigrationService()
            var choices: [String: AppMigrationService.ReplacementChoice] = [:]
            var paths: [String] = []
            for app in apps {
                let target = AppSearchExclusionService.destination(for: app, in: destination)
                if let choice = try service.replacementChoice(for: app, destinationURL: target),
                   choice.versionComparison == .unrecognized {
                    choices[app.id] = choice
                    paths.append(app.displayName + "\n" + choice.sourceURL.path + "\n→ " + choice.destinationURL.path)
                }
            }
            guard !choices.isEmpty else { completion([:]); return }
            let confirmedChoices = choices
            appReplacementRequest = WarningSheetRequest(
                title: "选择要保留的应用版本".localized,
                icon: "arrow.triangle.swap", tint: .orange,
                intro: "以下位置已有同一应用，但无法自动比较版本。继续会使用本地版本；新副本校验完成后才替换并清理外盘旧版。".localized,
                detail: paths.joined(separator: "\n\n"),
                actions: [WarningAction("使用本地版本并继续".localized, style: .preferred) {
                    completion(confirmedChoices)
                }]
            )
        } catch {
            showError(title: "无法迁移".localized, message: error.localizedDescription)
        }
    }

    private func prepareAppTransfers(_ apps: [AppItem], destination: URL, wholeSymlink: Bool = false) {
        func proceed(_ selected: [AppItem], _ accepted: Set<URL>) {
            confirmUpdateProtection(for: selected) { lockExternal in
                confirmUnrecognizedAppReplacements(apps: selected, destination: destination) { choices in
                    for (index, app) in selected.enumerated() {
                        enqueueAppTransfer(app, destination: AppSearchExclusionService.destination(for: app, in: destination),
                            wholeSymlink: wholeSymlink, lockExternal: lockExternal, acceptedRiskBundles: accepted,
                            replacementChoice: choices[app.id], presentDetails: index == 0)
                    }
                    if !wholeSymlink { selectedLocalApps.removeAll() }
                }
            }
        }
        if let request = Self.migrationRiskRequest(for: apps, service: AppMigrationService(), onChoice: { selected, accepted in
            DispatchQueue.main.async { proceed(selected, accepted) }
        }) {
            appMigrationRiskRequest = request
        } else {
            proceed(apps, [])
        }
    }

    static func migrationRiskRequest(for apps: [AppItem], service: AppMigrationService,
                                     onChoice: @escaping ([AppItem], Set<URL>) -> Void) -> WarningSheetRequest? {
        var restricted: [URL] = []
        var ordinary: [AppItem] = []
        for app in apps {
            let bundles = service.migrationRiskBundles(for: app)
            if bundles.isEmpty { ordinary.append(app) }
            else { restricted.append(contentsOf: bundles) }
        }
        guard !restricted.isEmpty else { return nil }
        let names = restricted.map(\.lastPathComponent).sorted().joined(separator: "\n")
        var actions = [WarningAction("无视风险迁移".localized) { onChoice(apps, Set(restricted)) }]
        if !ordinary.isEmpty {
            actions.append(WarningAction("仅迁移其他应用".localized, style: .preferred, isDefault: true) {
                onChoice(ordinary, [])
            })
        }
        return WarningSheetRequest(title: "应用本体迁移需要确认".localized, tint: .orange,
            intro: String(format: "以下应用默认保留在本机。迁出后，应用或依赖它的工具可能无法正常工作。\n\n%@".localized, names),
            actions: actions)
    }

    func performLinkIn() {
        // 获取所有选中且可链接的应用
        let validApps = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }.filter { ($0.status == AppStatus.unlinked || $0.status == AppStatus.external || $0.status == AppStatus.partialLinked) && activeJob(for: $0) == nil }

        guard !validApps.isEmpty else { return }

        confirmUpdateProtection(for: validApps) { lockExternal in
            executeBatchLinkIn(apps: validApps, lockExternal: lockExternal)
        }
    }

    private func executeBatchLinkIn(apps: [AppItem], lockExternal: Bool) {
        for (index, app) in apps.enumerated() {
            let destination = localAppsURL.appendingPathComponent(app.path.lastPathComponent)
            MigrationTaskCenter.shared.submit(title: "链接回本地".localized + " · " + app.displayName,
                category: .apps,
                resources: MigrationResources.application(paths: [app.path, app.displayURL, destination], appURL: app.displayURL),
                presentDetails: index == 0, operation: { progress in
                    progress.setDirectory(app.path)
                    try await MigrationExecution.control?.checkpointAsync()
                    let service = AppMigrationService()
                    try await service.linkAppWhenReady(appToLink: app, destinationURL: destination)
                    if lockExternal && service.needsUpdateProtection(app) { service.lockExternalApp(at: app.path) }
                    await MainActor.run { recordCompletedTransfer(.linkedIn(app, localDestination: destination)) }
                    return nil
                }, completion: { scanBothApps() })
        }
        selectedExternalApps.removeAll()
    }
    
    func performDeleteLink(app: AppItem) {
        if let job = activeJob(for: app) { migrationTasks.openJobDetail(job); return }
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
        showProgress = true

        operationState.startTask(for: activityToken) { @MainActor in
            defer {
                showProgress = false
                operationState.finish(activityToken)
            }
            do {
                let repair = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try AppMigrationService().repairDockShortcuts(for: app)
                }
                let updatedCount = try await withTaskCancellationHandler(operation: { try await repair.value },
                    onCancel: { repair.cancel() })
                AppLogger.shared.logContext(
                    "用户修复 Dock 固定项完成",
                    details: [("app_name", app.displayName), ("updated_count", String(updatedCount))]
                )
                alertTitle = updatedCount > 0 ? "Dock 图标已修复".localized : "Dock 图标无需修复".localized
                alertMessage = updatedCount > 0
                    ? "已更新现有 Dock 固定项，位置保持不变。Dock 将短暂刷新；从 Dock 打开此应用需要连接外部存储。".localized
                    : "没有需要更新的 Dock 固定项。如果还未固定此应用，请打开应用后选择“在程序坞中保留”。".localized
                showAlert = true
            } catch is CancellationError {
                // The service checks cancellation before changing Dock items.
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
        if let job = activeJob(for: app) { migrationTasks.openJobDetail(job); return }
        // 已链接的应用：传进来的可能是本地入口记录，不是本体。直接用它会变成「入口还原到入口自己」，
        // 入口检查认不出，于是报「本地已存在同名真实文件，无法覆盖」。先换成外部本体记录。
        let target = AppMigrationService().externalCounterpart(of: app, in: externalApps) ?? app
        // 还原读取的是外部副本。如果那块盘本来就存不住 ACL/硬链接/资源叉/权限位，
        // 这份副本在迁出时就已经缺了这些信息，还原补不回来。先说明再动手。
        if degradedRestoreRequest == nil,
           let capabilities = StorageCapabilityProbe.probe(destination: target.path),
           capabilities.mayHoldDegradedBundle {
            pendingDegradedRestoreApps = [target]
            degradedRestoreRequest = makeDegradedRestoreRequest(apps: [target], source: target.path,
                                                                capabilities: capabilities)
            return
        }
        executeMoveBack(app: target)
    }

    private func executeMoveBack(app target: AppItem) {
        enqueueAppTransfer(target, destination: localDestinationForMoveBack(app: target), restoring: true)
    }

    /// 批量迁移回本地
    func performBatchMoveBack() {
        // 获取所有选中的外部应用
        let selected = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }
        let validApps = selected.filter { !$0.isRunning && activeJob(for: $0) == nil }
        if validApps.isEmpty {
            if let job = selected.compactMap({ activeJob(for: $0) }).first {
                migrationTasks.openJobDetail(job)
            }
            return
        }
        // 还原读取的是外部副本；外部盘存不住的能力，在迁出时就已丢失。
        // 只要其中任意一个来自降级的卷，先统一说明一次再动手。
        var degradedTarget: (app: AppItem, capabilities: StorageCapabilities)?
        if degradedRestoreRequest == nil {
            for app in validApps {
                if let capabilities = StorageCapabilityProbe.probe(destination: app.path),
                   capabilities.mayHoldDegradedBundle {
                    degradedTarget = (app, capabilities)
                    break
                }
            }
        }
        if let degraded = degradedTarget {
            pendingDegradedRestoreApps = validApps
            degradedRestoreRequest = makeDegradedRestoreRequest(apps: validApps, source: degraded.app.path,
                                                                capabilities: degraded.capabilities)
            return
        }
        executeBatchMoveBack(validApps: validApps)
    }

    private func executeBatchMoveBack(validApps: [AppItem]) {
        for (index, app) in validApps.enumerated() {
            enqueueAppTransfer(app, destination: localDestinationForMoveBack(app: app),
                               restoring: true, presentDetails: index == 0)
        }
        selectedExternalApps.removeAll()
    }

    func getMoveBackButtonTitle() -> String {
        let selected = selectedExternalApps.compactMap { id in
            externalApps.first { $0.id == id }
        }
        let validCount = selected.filter { !$0.isRunning && activeJob(for: $0) == nil }.count
        if !selected.isEmpty && validCount == 0 {
            if selected.contains(where: { activeJob(for: $0) != nil }) { return "查看进度".localized }
            if selected.contains(where: { $0.isRunning }) { return "含运行中应用".localized }
        }
        if validCount <= 1 {
            return "迁移回本地".localized
        }
        return "迁移 %lld 个应用".localizedFormat(Int64(validCount))
    }
    
    // MARK: - 独立签名与官方修复

    func performSingleResign(
        app: AppItem,
        approvedTarget: DataMigrationWorkflow.SigningTarget? = nil
    ) {
        if let job = activeJob(for: app) { migrationTasks.openJobDetail(job); return }
        guard !isAppRunning(url: app.displayURL) else {
            showError(title: "签名失败".localized, message: AppMoverError.appIsRunning.localizedDescription)
            return
        }
        guard let activityToken = operationState.begin() else { return }
        progressTitle = approvedTarget == nil ? "正在检查应用…".localized : "重签名此应用".localized
        progressAppName = app.displayName
        progressCurrent = 1
        progressTotal = 1
        showProgress = true
        let task = Task { @MainActor in
            defer {
                showProgress = false
                operationState.finish(activityToken)
            }
            do {
                let target: DataMigrationWorkflow.SigningTarget
                if let approvedTarget {
                    target = approvedTarget
                } else {
                    let inspection = Task.detached(priority: .userInitiated) {
                        try DataMigrationWorkflow.signingTarget(at: app.displayURL)
                    }
                    target = try await withTaskCancellationHandler(operation: { try await inspection.value },
                        onCancel: { inspection.cancel() })
                }
                try Task.checkCancellation()
                guard approvedTarget != nil else {
                    pendingManualResignApp = app
                    pendingManualResignTarget = target
                    manualResignRequest = WarningSheetRequest(
                        title: "手动重签名".localized,
                        intro: manualResignConfirmMessage,
                        onCancel: {
                            pendingManualResignApp = nil
                            pendingManualResignTarget = nil
                        },
                        actions: [WarningAction("重签名".localized, style: .destructive) { confirmManualResign() }]
                    )
                    return
                }
                guard try resolveRealAppURL(for: app) == target.url else {
                    throw CodeSigner.SigningError.applicationChanged
                }
                // The service checks the selected object and content again under
                // its operation lock before it creates or commits a candidate.
                try await performResign(target: target, allowSandboxed: target.isSandboxed)
            } catch is CancellationError {
                // A committed result is returned by the service, not reported as cancellation.
            } catch {
                AppLogger.shared.logOperationFailure(category: "manual_sign",
                    operationID: AppLogger.shared.makeOperationID(prefix: "manual-sign"), error: error,
                    details: [("application_path", app.displayURL.path)], relatedURLs: [("target_app", app.displayURL)])
                showError(title: "签名失败".localized, message: error.localizedDescription)
            }
        }
        operationState.registerCancellation(for: activityToken) { task.cancel() }
    }

    func performRestoreSignature(app: AppItem) {
        if let job = activeJob(for: app) { migrationTasks.openJobDetail(job); return }
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
        showProgress = true
        let task = Task { @MainActor in
            defer {
                showProgress = false
                operationState.finish(activityToken)
            }
            let signer = CodeSigner()
            do {
                let realURL = try resolveRealAppURL(for: app)
                guard let bundleID = getBundleIdentifier(from: realURL) else {
                    throw CodeSigner.SigningError.restoreFailed("无法读取应用 Bundle Identifier".localized)
                }
                AppLogger.shared.logContext(
                    "用户请求恢复原始签名",
                    details: [("app_name", app.displayName), ("real_path", realURL.path), ("bundle_id", bundleID)]
                )
                guard !isAppRunning(url: realURL) else { throw AppMoverError.appIsRunning }
                let result = try await signer.restoreSignature(appURL: realURL, bundleIdentifier: bundleID, originalApplication: originalApplication)
                if let warning = result.cleanupWarning {
                    showError(title: "应用已恢复，正在完成收尾".localized, message: warning)
                }
                await MainActor.run {
                    scanLocalApps()
                    scanExternalApps()
                }
            } catch CodeSigner.SigningError.noBackupFound {
                offerOriginalApplication(for: app, reason: "没有内置原版备份，请选择同版本官方原件。".localized)
            } catch CodeSigner.SigningError.legacyBackupIncomplete {
                offerOriginalApplication(for: app, reason: CodeSigner.SigningError.legacyBackupIncomplete.localizedDescription)
            } catch CodeSigner.SigningError.applicationChanged {
                offerOriginalApplication(for: app, reason: CodeSigner.SigningError.applicationChanged.localizedDescription)
            } catch CodeSigner.SigningError.snapshotInvalid {
                offerOriginalApplication(for: app, reason: CodeSigner.SigningError.snapshotInvalid.localizedDescription)
            } catch is DecodingError {
                offerOriginalApplication(for: app, reason: CodeSigner.SigningError.snapshotInvalid.localizedDescription)
            } catch {
                await MainActor.run {
                    AppLogger.shared.logOperationFailure(category: "signature_restore",
                        operationID: AppLogger.shared.makeOperationID(prefix: "signature-restore"), error: error,
                        details: [("application_path", app.displayURL.path)])
                    showError(title: "恢复签名失败".localized, message: error.localizedDescription)
                }
            }
        }
        operationState.registerCancellation(for: activityToken) { task.cancel() }
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

    /// Manual signing is independent of every migration action.
    func performResign(target: DataMigrationWorkflow.SigningTarget, allowSandboxed: Bool) async throws {
        let result = try await CodeSigner().sign(
            appURL: target.url,
            bundleIdentifier: getBundleIdentifier(from: target.url),
            allowSandboxed: allowSandboxed,
            expectedFingerprint: target.fingerprint,
            expectedIdentity: target.identity
        )
        if let warning = result.cleanupWarning {
            showError(title: "签名已完成，正在完成收尾".localized, message: warning)
        }
        scanBothApps()
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
        externalLibraryMonitor?.stopMonitoring()
        externalLibraryMonitor = nil
        externalMonitor = nil
        guard !isExternalAccessSuppressed(for: url) else {
            AppLogger.shared.logContext("外盘处于弹出退让期，暂不启动外部目录监控", details: [("path", url.path)], level: "TRACE")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        AppLogger.shared.logContext("启动外部目录监控", details: [("path", url.path)])

        let monitor = FolderMonitor(url: url)
        monitor.startMonitoring { [self] in
            scheduleMonitorRescan(local: false)
        }
        self.externalMonitor = monitor
        let library = AppSearchExclusionService.library(in: url)
        if library != url, FileManager.default.fileExists(atPath: library.path) {
            let libraryMonitor = FolderMonitor(url: library)
            libraryMonitor.startMonitoring { [self] in scheduleMonitorRescan(local: false) }
            externalLibraryMonitor = libraryMonitor
        }
    }

    /// 统一防抖：合并两个 monitor 的扫描请求，避免列表连续跳两下
    private func scheduleMonitorRescan(local: Bool) {
        monitorRescanDebouncer.schedule { [self] in
            Task { @MainActor in
                guard self.isVisible else { return }
                if self.isExternalVolumeSuppressedAndMounted(self.externalDriveURL) {
                    return
                }
                AppLogger.shared.logContext("Monitor 防抖触发扫描", details: [("trigger", local ? "local" : "external")], level: "TRACE")
                if let root = self.externalDriveURL { self.startMonitoringExternal(url: root) }
                self.scanBothApps()
            }
        }
    }

    func stopMonitoringExternal() {
        AppLogger.shared.log("停止外部目录监控", level: "TRACE")
        externalMonitor?.stopMonitoring()
        externalLibraryMonitor?.stopMonitoring()
        externalLibraryMonitor = nil
        externalMonitor = nil
    }

    @MainActor
    private func isExternalAccessSuppressed(for url: URL?) -> Bool {
        guard let url else { return false }
        if diskEjection.suppressesVolumeAccess(at: url) { return true }
        return unmountingVolumePaths.contains { DiskEjectionController.path(url.path, isWithin: $0) }
    }

    @MainActor
    private func isExternalVolumeSuppressedAndMounted(_ url: URL?) -> Bool {
        guard let url, isExternalAccessSuppressed(for: url) else { return false }
        return DiskEjectionController.mountedExternalVolumeRoot(for: url) != nil
    }

    @MainActor
    private func yieldExternalVolumeAccess(reason: String) {
        monitorRescanDebouncer.cancel()
        stopMonitoringExternal()
        appScanTask?.cancel()
        appScanTask = nil
        localScanState.cancelInFlight()
        externalScanState.cancelInFlight()
        needsAppRescan = false
        AppLogger.shared.logContext(
            "外盘即将卸载，暂停外部扫描与目录监控",
            details: [("reason", reason), ("path", externalDriveURL?.path)],
            level: "TRACE"
        )
    }

    @MainActor
    private func handleWorkspaceWillUnmount(_ notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let external = externalDriveURL else { return }
        let volumePath = DiskEjectionController.standardizedPath(volumeURL.path)
        guard DiskEjectionController.path(external.path, isWithin: volumePath) else { return }
        unmountingVolumePaths.insert(volumePath)
        yieldExternalVolumeAccess(reason: "workspace-will-unmount")
        unmountGraceTask?.cancel()
        unmountGraceTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            unmountingVolumePaths.remove(volumePath)
            unmountGraceTask = nil
            resumeExternalMonitoringAfterEjectionIfNeeded(triggerScan: false)
        }
    }

    @MainActor
    private func resumeExternalMonitoringAfterEjectionIfNeeded(triggerScan: Bool = true) {
        guard isVisible, let root = externalDriveURL,
              !isExternalAccessSuppressed(for: root),
              DiskEjectionController.mountedExternalVolumeRoot(for: root) != nil,
              externalMonitor == nil else { return }
        startMonitoringExternal(url: root)
        if triggerScan { scanBothApps() }
    }

    // MARK: - 签名被替换的应用提醒

    private var signatureRepairReminderMessage: String {
        let names = signatureRepairReminderApps.map(\.displayName).localizedListJoined
        let count = Int64(signatureRepairReminderApps.count)
        if !MigrationPreferences.isMacOS27OrLater {
            return "AppPorts 曾用 Ad-hoc 签名替换了 %lld 个应用的开发者签名：\n\n%@\n\n升级到 macOS 27 后它们可能无法打开。建议升级前检查一遍：点这些应用右侧的「修复」按钮。".localizedFormat(count, names)
        }
        return "AppPorts 曾用 Ad-hoc 签名替换了 %lld 个应用的开发者签名：\n\n%@\n\n在 macOS 27 上它们可能无法打开。能正常打开的可以先不处理；打不开的点右侧的「修复」按钮。".localizedFormat(count, names)
    }

    private var manualResignConfirmMessage: String {
        pendingManualResignTarget?.confirmationMessage ?? ""
    }

    private func confirmManualResign() {
        let app = pendingManualResignApp
        let approvedTarget = pendingManualResignTarget
        pendingManualResignApp = nil
        pendingManualResignTarget = nil
        guard let app, let approvedTarget else { return }
        DispatchQueue.main.async {
            self.performSingleResign(app: app, approvedTarget: approvedTarget)
        }
    }

    private func signatureRepairSheet(for app: AppItem) -> some View {
        SignatureRepairSheet(
            app: localApps.first(where: { $0.id == app.id }) ?? app,
            onRestoreSignature: { target in
                DispatchQueue.main.async { performRestoreSignature(app: target) }
            },
            onMoveBack: { target in
                DispatchQueue.main.async { performMoveBack(app: target) }
            },
            onOpenDataDirs: { target in
                selectedDataDirsApp = target
                selectedDataDirsTab = .appDirs
                mainTab = .dataDirs
            },
            onDismiss: { signatureRepairApp = nil },
            onChooseOfficialOriginal: { target in
                DispatchQueue.main.async {
                    offerOriginalApplication(for: target, reason: "选择同版本的官方原版应用".localized)
                }
            }
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
                    mainTab = .apps
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

    /// 插拔后目录监控的旧描述符不能复用；同时刷新外部列表和本地入口状态。
    @MainActor
    private func startObservingVolumeMounts() {
        stopObservingVolumeMounts()
        let observer = AppLibraryVolumeObserver(center: NSWorkspace.shared.notificationCenter)
        observer.start { isMount in
            guard self.isVisible else { return }
            if let root = self.externalDriveURL {
                let mountedRoot = DiskEjectionController.mountedExternalVolumeRoot(for: root)
                if mountedRoot == nil {
                    self.unmountingVolumePaths.removeAll()
                    self.unmountGraceTask?.cancel()
                    self.unmountGraceTask = nil
                } else if isMount {
                    self.unmountingVolumePaths.removeAll()
                    self.unmountGraceTask?.cancel()
                    self.unmountGraceTask = nil
                }
            }
            if isMount { self.remountContainerVolumes(trigger: "volume-mounted") }
            if self.isExternalVolumeSuppressedAndMounted(self.externalDriveURL) {
                return
            }
            // Reuse the scan debounce so sibling APFS volume events coalesce.
            // Its callback rebuilds monitoring at the current mount and scans both panes.
            self.scheduleMonitorRescan(local: false)
        }
        libraryVolumeObserver = observer
    }

    @MainActor
    private func stopObservingVolumeMounts() {
        libraryVolumeObserver?.stop()
        libraryVolumeObserver = nil
    }

    @MainActor
    private func remountContainerVolumes(trigger: String) {
        // 前台操作已经执行过自己的收尾；失败后交由定时检查或用户手动重试。
        guard trigger != "operation-finished",
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !operationState.isBusy else { return }
        Task {
            _ = await OperationMaintenance.shared.run(minimumInterval: trigger == "retry" ? 60 : 0)
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
