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
            HStack(spacing: 0) {
                ForEach(DataTab.allCases, id: \.self) { tab in
                    Button(action: { withAnimation { selectedTab = tab } }) {
                        VStack(spacing: 4) {
                            Text(tab.rawValue.localized)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                            Rectangle()
                                .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 0)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                // 刷新按钮
                Button(action: reloadCurrentTab) {
                    Image(systemName: isScanning ? "arrow.clockwise" : "arrow.clockwise")
                        .rotationEffect(.degrees(isScanning ? 360 : 0))
                        .animation(isScanning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isScanning)
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 16)
                .padding(.top, 8)
                .disabled(isScanning)
                .help("刷新列表")
            }
            .background(.ultraThinMaterial)

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
            Button("继续".localized, role: .none) { confirmAction?() }
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
                    ContentView.EmptyStateView(icon: "folder.badge.questionmark", text: "未发现已知工具目录")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(dotFolderItems) { item in
                                DataDirRowView(
                                    item: item,
                                    isSelected: selectedItemID == item.id,
                                    onMigrate: { askMigrate($0) },
                                    onRestore: { askRestore($0) }
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
                HStack {
                    Text("选择应用".localized)
                        .font(.headline)
                        .padding(.leading, 16)
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                Divider()

                if localApps.isEmpty {
                    ContentView.EmptyStateView(icon: "app.dashed", text: "无本地应用")
                } else {
                    let filteredApps = localApps.filter { !$0.isFolder }
                    List(filteredApps, id: \.id) { app in
                        HStack(spacing: 10) {
                            AppIconView(url: app.path)
                                .frame(width: 28, height: 28)
                            Text(app.name.replacingOccurrences(of: ".app", with: ""))
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            selectedApp?.id == app.id
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                        )
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedApp = app
                        }
                    }
                    .listStyle(.plain)
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
                        Text("\(app.name.replacingOccurrences(of: ".app", with: "")) 的数据目录".localized)
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
                        ContentView.EmptyStateView(icon: "arrow.left.circle", text: "从左侧选择一个应用")
                    } else if isScanning && libraryItems.isEmpty {
                        loadingView
                    } else if libraryItems.isEmpty {
                        ContentView.EmptyStateView(icon: "folder.badge.questionmark", text: "未找到关联数据目录")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(libraryItems) { item in
                                    DataDirRowView(
                                        item: item,
                                        isSelected: selectedItemID == item.id,
                                        onMigrate: { askMigrate($0) },
                                        onRestore: { askRestore($0) }
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
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]

        return HStack(spacing: 20) {
            Label("\(items.count) 个目录", systemImage: "folder")
            if total > 0 {
                Label(formatter.string(fromByteCount: total) + " 可迁移", systemImage: "arrow.up.circle")
                    .foregroundColor(.blue)
            }
            if linked > 0 {
                Label("\(linked) 个已链接", systemImage: "link")
                    .foregroundColor(.green)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
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
            errorMessage = "请先选择外部存储路径"
            showError = true
            return
        }

        let destPath = dest.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
        let sizeInfo = item.size.map { "，大小约 \($0)" } ?? ""

        confirmTitle = "迁移数据目录"
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

        confirmTitle = "还原数据目录"
        confirmMessage = """
        将「\(item.name)」从外部存储还原到本地。

        外部路径：\(linkedDest)
        还原到：\(item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))

        还原完成后，外部存储中的副本将被删除。
        """
        confirmAction = { performRestore(item) }
        showConfirm = true
    }

    // MARK: - 执行操作

    private func performMigrate(_ item: DataDirItem, to dest: URL) {
        progressTitle = "正在迁移「\(item.name)」"
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
        progressTitle = "正在还原「\(item.name)」"
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
