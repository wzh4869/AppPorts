//
//  DataDirsView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/3/4.
//

import SwiftUI

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
    /// 选择外部存储路径的回调
    let onSelectExternalDrive: () -> Void

    // MARK: - 内部状态
    @State private var dotFolderItems: [DataDirItem] = []
    @State private var libraryItems:   [DataDirItem] = []
    @State private var selectedApp: AppItem? = nil

    @State private var selectedTab: DataTab = .toolDirs
    @State private var showAppDataFilters = false
    @State private var selectedPriorityFilters: Set<DataDirPriority> = []
    @State private var selectedStatusFilters: Set<String> = []
    @State private var selectedTypeFilters: Set<DataDirType> = []
    @State private var selectedAppDataSortMode: AppDataSortMode = .defaultOrder

    @State private var isScanning = false

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
    @State private var showManagedLinkNormalizationConfirm = false
    @State private var managedLinkNormalizationMessage = ""
    @State private var managedLinkNormalizationItem: DataDirItem? = nil
    @State private var managedLinkNormalizationCurrentTarget: URL? = nil

    // 错误弹窗
    @State private var showError = false
    @State private var errorMessage = ""

    // 选中项（用于高亮）
    @State private var selectedItemID: UUID? = nil

    enum DataTab: String, CaseIterable {
        case toolDirs  = "工具目录"
        case appDirs   = "应用数据"
    }

    enum AppDataSortMode: String, CaseIterable {
        case defaultOrder = "默认"
        case size = "按大小"
        case alphabetical = "按首字母"
    }

    private let appDataStatusOrder = ["本地", "已链接", "待规范", "现有软链", "待接回", "未找到"]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── 顶部 Tab 选择器 ──────────────────────────────────
            HStack(spacing: 16) {
                Picker("", selection: $selectedTab) {
                    ForEach(DataTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue.localized).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Spacer()

                // 刷新按钮
                Button(action: reloadCurrentTab) {
                    Image(systemName: isScanning ? "arrow.clockwise" : "arrow.clockwise")
                        .rotationEffect(.degrees(isScanning ? 360 : 0))
                        .animation(isScanning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isScanning)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(isScanning)
                .help("刷新列表".localized)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)

            Divider()

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
                presentPendingMigrationConfirmation()
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
        // 错误弹窗
        .alert("操作失败".localized, isPresented: $showError) {
            Button("好的".localized, role: .cancel) {}
        } message: {
            Text(errorMessage)
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
                    Image(systemName: "app.badge")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                    Text("选择应用".localized)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
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
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                Divider()

                if localApps.isEmpty {
                    ContentView.EmptyStateView(icon: "app.dashed", text: "无本地应用".localized)
                } else {
                    let filteredApps = localApps.filter { !$0.isFolder }
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredApps, id: \.id) { app in
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
                else { libraryItems = [] }
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
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
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
                            LazyVStack(spacing: 4) {
                                ForEach(sortedFilteredLibraryItems) { item in
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
                        Text(mode.rawValue.localized)
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
                Text(selectedAppDataSortMode.rawValue.localized)
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

                Text(String(format: "排序：%@".localized, selectedAppDataSortMode.rawValue.localized))
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
                    Toggle(priority.rawValue.localized, isOn: priorityFilterBinding(priority))
                        .toggleStyle(.checkbox)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("链接状态".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(appDataStatusOrder, id: \.self) { status in
                    Toggle(status.localized, isOn: statusFilterBinding(status))
                        .toggleStyle(.checkbox)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("数据类型".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(appDataFilterTypes, id: \.self) { type in
                    Toggle(type.rawValue.localized, isOn: typeFilterBinding(type))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func statsBar(items: [DataDirItem]) -> some View {
        let total = items.filter { $0.status == "本地" }.reduce(0) { $0 + $1.sizeBytes }
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

    private var filteredLibraryItems: [DataDirItem] {
        libraryItems.filter(matchesAppDataFilters)
    }

    private var sortedFilteredLibraryItems: [DataDirItem] {
        switch selectedAppDataSortMode {
        case .defaultOrder:
            return filteredLibraryItems
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

    private var hasActiveAppDataFilters: Bool {
        !selectedPriorityFilters.isEmpty || !selectedStatusFilters.isEmpty || !selectedTypeFilters.isEmpty
    }

    private var activeAppDataFilterCount: Int {
        selectedPriorityFilters.count + selectedStatusFilters.count + selectedTypeFilters.count
    }

    private var activeAppDataFilterLabels: [String] {
        var labels: [String] = []
        labels.append(contentsOf: DataDirPriority.allCases.filter(selectedPriorityFilters.contains).map { $0.rawValue.localized })
        labels.append(contentsOf: appDataStatusOrder.filter(selectedStatusFilters.contains).map { $0.localized })
        labels.append(contentsOf: appDataFilterTypes.filter(selectedTypeFilters.contains).map { $0.rawValue.localized })
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
        } else if let app = selectedApp {
            scanLibraryDirs(for: app)
        }
    }

    private func scanDotFolders() {
        isScanning = true
        let scanID = AppLogger.shared.makeOperationID(prefix: "scan-dot-folders")
        AppLogger.shared.logContext("开始扫描工具目录", details: [("scan_id", scanID)])
        Task.detached(priority: .userInitiated) {
            let scanner = DataDirScanner()
            var items = await scanner.scanKnownDotFolders()
            let initialItems = items

            await MainActor.run {
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

            // 后台逐个计算大小
            for i in items.indices {
                let sizeBytes = await scanner.calculateSize(for: items[i])
                let sizeStr = LocalizedByteCountFormatter.string(fromByteCount: sizeBytes)
                let itemID = items[i].id
                await MainActor.run {
                    if let idx = self.dotFolderItems.firstIndex(where: { $0.id == itemID }) {
                        withAnimation {
                            self.dotFolderItems[idx].size = sizeStr
                            self.dotFolderItems[idx].sizeBytes = sizeBytes
                        }
                    }
                }
                items[i].sizeBytes = sizeBytes
            }
        }
    }

    private func scanLibraryDirs(for app: AppItem) {
        isScanning = true
        libraryItems = []
        let appDisplayName = app.displayName
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
            var items = await scanner.scanLibraryDirs(for: app, externalRootURL: selectedExternalRoot)
            let initialItems = items

            await MainActor.run {
                self.libraryItems = initialItems
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

            // 后台逐个计算大小
            for i in items.indices {
                let sizeBytes = await scanner.calculateSize(for: items[i])
                let sizeStr = LocalizedByteCountFormatter.string(fromByteCount: sizeBytes)
                let itemID = items[i].id
                await MainActor.run {
                    if let idx = self.libraryItems.firstIndex(where: { $0.id == itemID }) {
                        withAnimation {
                            self.libraryItems[idx].size = sizeStr
                            self.libraryItems[idx].sizeBytes = sizeBytes
                        }
                    }
                }
                items[i].sizeBytes = sizeBytes
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

        let destPath = suggestedDestinationPath(for: item, under: dest)
        if selectedTab == .appDirs {
            pendingMigrationItem = item
            pendingMigrationDestinationPath = destPath
            showAppDataMigrationRiskConfirm = true
            return
        }

        presentMigrationConfirmation(for: item, destinationPath: destPath)
    }

    private func askRestore(_ item: DataDirItem) {
        let linkedDest = item.linkedDestination?.path ?? "（未知）"

        confirmTitle = "还原数据目录".localized
        confirmActionTitle = "继续".localized
        confirmMessage = """
        将「\(item.name)」从外部存储还原到本地。

        外部路径：\(linkedDest)
        还原到：\(item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))

        还原完成后，外部存储中的副本将被删除。
        """
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
        confirmMessage = """
        检测到「\(item.name)」已经是一个现有软链。

        软链路径：\(item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        目标路径：\(linkedDest.path)

        选择「规范化管理」后，AppPorts 会将这条软链接纳入受管状态，后续可直接还原。
        """
        confirmAction = { queueManagedLinkNormalization(item, currentTarget: linkedDest) }
        showConfirm = true
    }

    private func askNormalizeManagedLink(_ item: DataDirItem) {
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
        confirmMessage = """
        检测到「\(item.name)」已经由 AppPorts 接管，但外部目标仍位于旧路径。

        当前外部路径：\(linkedDest.path)
        规范后路径：\(normalizedTarget.path)

        继续后将进入二次确认，并执行真实迁移。
        """
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
        managedLinkNormalizationMessage = """
        请确认是否继续规范化管理「\(item.name)」。

        现在的路径：\(currentPath)
        规范后路径：\(normalizedPath)

        \(note)
        """
        showConfirm = false
        DispatchQueue.main.async {
            self.showManagedLinkNormalizationConfirm = true
        }
    }

    private func askRelinkExternalData(_ item: DataDirItem) {
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
        confirmMessage = """
        检测到「\(item.name)」的数据目录已存在于外部存储，但本地原路径尚未建立链接。

        本地原路径：\(item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        外部目录：\(linkedDest.path)

        选择「接回」后，AppPorts 会在原路径补建符号链接，并将其纳入受管状态。
        """
        confirmAction = { performRelinkExternalData(item, target: linkedDest) }
        showConfirm = true
    }

    // MARK: - 执行操作

    private func performMigrate(_ item: DataDirItem, to dest: URL) {
        progressTitle = String(format: "正在迁移「%@」".localized, item.name)
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-data-migrate")
        AppLogger.shared.logContext(
            "用户确认迁移数据目录",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("type", item.type.rawValue),
                ("source", item.path.path),
                ("destination_root", dest.path)
            ]
        )

        Task {
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
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func presentMigrationConfirmation(for item: DataDirItem, destinationPath: URL) {
        let sizeInfo = item.size.map { String(format: "，大小约 %@".localized, $0) } ?? ""

        confirmTitle = "迁移数据目录".localized
        confirmActionTitle = "继续".localized
        confirmMessage = """
        将「\(item.name)」迁移到外部存储\(sizeInfo)。

        源路径：\(item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        目标路径：\(destinationPath.path)

        迁移完成后，原路径将自动变成符号链接，相关工具无需任何修改即可继续使用。
        """
        confirmAction = { performMigrate(item, to: destinationPath.deletingLastPathComponent()) }
        showConfirm = true
    }

    private func presentPendingMigrationConfirmation() {
        guard let item = pendingMigrationItem,
              let destinationPath = pendingMigrationDestinationPath else {
            clearPendingMigrationConfirmation()
            return
        }

        clearPendingMigrationConfirmation()
        DispatchQueue.main.async {
            presentMigrationConfirmation(for: item, destinationPath: destinationPath)
        }
    }

    private func clearPendingMigrationConfirmation() {
        pendingMigrationItem = nil
        pendingMigrationDestinationPath = nil
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
            ]
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
            ]
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
            ]
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
            Text(title.localized)
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
