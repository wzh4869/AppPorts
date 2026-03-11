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

    // 错误弹窗
    @State private var showError = false
    @State private var errorMessage = ""

    // 选中项（用于高亮）
    @State private var selectedItemID: UUID? = nil

    enum DataTab: String, CaseIterable {
        case toolDirs  = "工具目录"
        case appDirs   = "应用数据"
    }

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
        .onChange(of: selectedTab) { _, _ in
            reloadCurrentTab()
        }
        // 确认弹窗
        .alert(LocalizedStringKey(confirmTitle), isPresented: $showConfirm) {
            Button(confirmActionTitle, role: .none) { confirmAction?() }
            Button("取消".localized, role: .cancel) {}
        } message: {
            Text(confirmMessage)
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
                                    onManageExistingLink: { askManageExistingLink($0) }
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
            .onChange(of: selectedApp) { _, newApp in
                if let app = newApp { scanLibraryDirs(for: app) }
                else { libraryItems = [] }
            }

            // 右侧：关联数据目录
            VStack(spacing: 0) {
                HStack {
                    if let app = selectedApp {
                        Text(String(format: "%@ 的数据目录".localized, app.name.replacingOccurrences(of: ".app", with: "")))
                    } else {
                        Text("请从左侧选择应用".localized)
                    }
                    Spacer()
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
                    statsBar(items: libraryItems)
                }

                ZStack {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

                    if selectedApp == nil {
                        ContentView.EmptyStateView(icon: "arrow.left.circle", text: "从左侧选择一个应用".localized)
                    } else if isScanning && libraryItems.isEmpty {
                        loadingView
                    } else if libraryItems.isEmpty {
                        ContentView.EmptyStateView(icon: "folder.badge.questionmark", text: "未找到关联数据目录".localized)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(libraryItems) { item in
                                    DataDirRowView(
                                        item: item,
                                        isSelected: selectedItemID == item.id,
                                        onMigrate: { askMigrate($0) },
                                        onRestore: { askRestore($0) },
                                        onManageExistingLink: { askManageExistingLink($0) }
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

    private func statsBar(items: [DataDirItem]) -> some View {
        let total = items.filter { $0.status == "本地" }.reduce(0) { $0 + $1.sizeBytes }
        let linked = items.filter { $0.status == "已链接" }.count
        let existingSymlinks = items.filter { $0.status == "现有软链" }.count
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]

        return HStack(spacing: 20) {
            Label(String(format: "%lld 个目录".localized, Int64(items.count)), systemImage: "folder.fill")
                .foregroundColor(.secondary)
            if total > 0 {
                Label(formatter.string(fromByteCount: total) + " 可释放".localized, systemImage: "sparkles")
                    .foregroundColor(.accentColor)
                    .fontWeight(.medium)
            }
            if linked > 0 {
                Label(String(format: "%lld 个已链接".localized, Int64(linked)), systemImage: "link.circle.fill")
                    .foregroundColor(.green)
            }
            if existingSymlinks > 0 {
                Label(String(format: "%lld 个现有软链".localized, Int64(existingSymlinks)), systemImage: "link.badge.questionmark")
                    .foregroundColor(.teal)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.primary.opacity(0.05)), alignment: .bottom)
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
        if selectedTab == .toolDirs {
            scanDotFolders()
        } else if let app = selectedApp {
            scanLibraryDirs(for: app)
        }
    }

    private func scanDotFolders() {
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let scanner = DataDirScanner()
            var items = await scanner.scanKnownDotFolders()

            await MainActor.run {
                self.dotFolderItems = items
                self.isScanning = false
            }

            // 后台逐个计算大小
            for i in items.indices {
                let sizeBytes = await scanner.calculateSize(for: items[i])
                let sizeStr = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
                await MainActor.run {
                    if let idx = self.dotFolderItems.firstIndex(where: { $0.id == items[i].id }) {
                        withAnimation {
                            self.dotFolderItems[idx].size = sizeBytes > 0 ? sizeStr : nil
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
        Task.detached(priority: .userInitiated) {
            let scanner = DataDirScanner()
            var items = await scanner.scanLibraryDirs(for: app)

            await MainActor.run {
                self.libraryItems = items
                self.isScanning = false
            }

            // 后台逐个计算大小
            for i in items.indices {
                let sizeBytes = await scanner.calculateSize(for: items[i])
                let sizeStr = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
                await MainActor.run {
                    if let idx = self.libraryItems.firstIndex(where: { $0.id == items[i].id }) {
                        withAnimation {
                            self.libraryItems[idx].size = sizeBytes > 0 ? sizeStr : nil
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
            errorMessage = "请先选择外部存储路径".localized
            showError = true
            return
        }

        let destPath = dest.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
        let sizeInfo = item.size.map { String(format: "，大小约 %@".localized, $0) } ?? ""

        confirmTitle = "迁移数据目录".localized
        confirmActionTitle = "继续".localized
        confirmMessage = """
        将「\(item.name)」迁移到外部存储\(sizeInfo)。

        源路径：\(item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        目标路径：\(destPath.path)

        迁移完成后，原路径将自动变成符号链接，相关工具无需任何修改即可继续使用。
        """
        confirmAction = { performMigrate(item, to: destPath.deletingLastPathComponent()) }
        showConfirm = true
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
        confirmAction = { performManageExistingLink(item, target: linkedDest) }
        showConfirm = true
    }

    // MARK: - 执行操作

    private func performMigrate(_ item: DataDirItem, to dest: URL) {
        progressTitle = String(format: "正在迁移「%@」".localized, item.name)
        showProgress = true

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
                await MainActor.run {
                    self.showProgress = false
                    self.reloadCurrentTab()
                }
            } catch {
                await MainActor.run {
                    self.showProgress = false
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performRestore(_ item: DataDirItem) {
        progressTitle = String(format: "正在还原「%@」".localized, item.name)
        showProgress = true

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
                await MainActor.run {
                    self.showProgress = false
                    self.reloadCurrentTab()
                }
            } catch {
                await MainActor.run {
                    self.showProgress = false
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performManageExistingLink(_ item: DataDirItem, target: URL) {
        Task {
            let mover = DataDirMover()
            do {
                try await mover.createLink(localPath: item.path, externalPath: target)
                await MainActor.run {
                    self.reloadCurrentTab()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
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
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
