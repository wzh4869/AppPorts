//
//  CustomDirsView.swift
//  AppPorts
//
//  Created by Codex on 2026/6/26.
//

import SwiftUI
import AppKit
import Darwin

enum CustomDirRecoveryEligibility {
    static func isRetainedExternalCopy(config: CustomDirConfig, groups: [DataTransferGroup]) -> Bool {
        groups.contains { group in
            group.state == .restored
                && URL(fileURLWithPath: group.originalPath).standardizedFileURL == config.localURL
                && group.retainedCopies.contains { copy in
                    copy.path.map { URL(fileURLWithPath: $0).standardizedFileURL == config.externalDestinationURL } == true
                }
        }
    }

    static func canRestoreMissingSource(config: CustomDirConfig, managedLinks: [ManagedDataLinkRecord]) -> Bool {
        var localEntry = stat()
        guard lstat(config.localURL.path, &localEntry) != 0, errno == ENOENT,
              let indexed = managedLinks.first(where: {
                  URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path == config.localURL.path
              }),
              DataPathTopology.relationship(indexed.destinationPath, config.externalDestinationURL.path) == .same,
              let actual = try? DataPathIdentity.capture(config.externalDestinationURL),
              indexed.destinationIdentity.matchesFilesystemObject(actual) else { return false }
        return true
    }
}

@MainActor
struct CustomDirsView: View {
    var isActive: Bool = true
    var refreshTrigger: Int = 0
    var onScanningChanged: ((Bool) -> Void)? = nil
    @Environment(\.locale) private var locale
    @ObservedObject private var operationState = AppOperationState.shared
    @ObservedObject private var configStore = CustomDirConfigStore.shared
    private var configs: [CustomDirConfig] { configStore.configs }
    @State private var pairs: [CustomDirPair] = []
    @State private var selectedLocalIDs: Set<String> = []
    @State private var selectedExternalIDs: Set<String> = []
    @State private var isScanning = false
    @State private var refreshRequestID: UUID?
    @State private var directoryRefreshTask: Task<Void, Never>?
    @State private var recordRefreshTask: Task<Void, Never>?
    @State private var sizeCacheUpdatedAt: Date?
    @State private var isVisible = false
    @State private var showAddSheet = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showCompletionWarning = false
    @State private var completionWarning = ""
    @State private var retainedTransfers: [DataTransferRecord] = []
    @State private var managedLinks: [ManagedDataLinkRecord] = []
    private var transferGroups: [DataTransferGroup] { DataTransferGroup.groups(from: retainedTransfers) }

    /// 目标盘存不住文件所有者时的确认框；没有提示就保持 nil，不打扰用户。
    @State private var ownershipAdvisoryRequest: WarningSheetRequest?

    private var localEntries: [CustomDirEntry] {
        pairs.map(\.local)
    }

    private var externalEntries: [CustomDirEntry] {
        pairs.map { pair in
            var entry = pair.external
            if pair.local.status == CustomDirStatus.local,
               CustomDirRecoveryEligibility.isRetainedExternalCopy(config: pair.config, groups: transferGroups) {
                entry.status = CustomDirStatus.retainedCopy
            }
            return entry
        }
    }

    private var selectedLocalPairs: [CustomDirPair] {
        pairs.filter { selectedLocalIDs.contains($0.local.id) }
    }

    private var selectedExternalPairs: [CustomDirPair] {
        pairs.filter { selectedExternalIDs.contains($0.external.id) }
    }

    private var migratablePairs: [CustomDirPair] {
        selectedLocalPairs.filter { $0.local.status == CustomDirStatus.local }
    }

    private var relinkablePairs: [CustomDirPair] {
        selectedExternalPairs.filter {
            $0.external.status == CustomDirStatus.pendingRelink
                && !CustomDirRecoveryEligibility.isRetainedExternalCopy(config: $0.config, groups: transferGroups)
        }
    }

    private var restorablePairs: [CustomDirPair] {
        selectedExternalPairs.filter {
            $0.external.status == CustomDirStatus.linked
                || ($0.external.status == CustomDirStatus.pendingRelink
                    && CustomDirRecoveryEligibility.canRestoreMissingSource(config: $0.config, managedLinks: managedLinks))
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if retainedTransfers.contains(where: { $0.needsAttention }) {
                    HStack {
                        Text(retainedTransfers.contains(where: { $0.cleanupDisposition == .deferred })
                            ? "部分操作已暂停，可手动重试。".localized
                            : "部分数据操作尚未完成，副本已保留。".localized).foregroundStyle(.secondary)
                        Spacer()
                        Button("重试".localized) { retryPendingOperations() }
                    }.padding(12)
                }
                HSplitView {
                    localPane
                        .frame(minWidth: 320, maxWidth: .infinity)

                    externalPane
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
            }
            .disabled(operationState.blocksInteraction)


        }
        .onAppear {
            isVisible = isActive
            refresh()
        }
        .onChange(of: isActive) { active in
            isVisible = active
            if active { refresh() } else { invalidateRefresh() }
        }
        .onChange(of: refreshTrigger) { _ in
            guard isActive, !isScanning, !operationState.blocksInteraction else { return }
            refresh(forceSizeRefresh: true)
        }
        .onChange(of: isScanning) { scanning in
            onScanningChanged?(scanning)
        }
        .onChange(of: operationState.recordsRevision) { _ in refresh() }
        .onChange(of: configStore.configs) { _ in refresh() }
        .onDisappear {
            isVisible = false
            invalidateRefresh()
            onScanningChanged?(false)
        }
        .sheet(isPresented: $showAddSheet) {
            AddCustomDirSheet(existingConfigs: configs) { config in
                addAndMigrateConfig(config)
            }
        }

        .alert("操作失败".localized, isPresented: $showError) {
            Button("好的".localized, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("操作尚未完成".localized, isPresented: $showCompletionWarning) {
            Button("好的".localized, role: .cancel) {}
        } message: {
            Text(completionWarning)
        }
        .warningSheet($ownershipAdvisoryRequest)
    }

    private var localPane: some View {
        VStack(spacing: 0) {
            ContentView.HeaderView(
                title: "本地文件夹".localized,
                subtitle: String(format: "%lld 个目录".localized, Int64(configs.count)),
                icon: "folder.fill",
                actionButtonText: "＋",
                onAction: { showAddSheet = true }
            )

            ZStack {
                Color(nsColor: .controlBackgroundColor).ignoresSafeArea()

                if isScanning && localEntries.isEmpty {
                    ContentView.EmptyStateView(icon: "magnifyingglass", text: "正在扫描...".localized)
                } else if localEntries.isEmpty {
                    ContentView.EmptyStateView(icon: "folder.badge.plus", text: "未添加目录迁移".localized)
                } else {
                    List(localEntries, selection: $selectedLocalIDs) { entry in
                        CustomDirRowView(
                            entry: entry,
                            isSelected: selectedLocalIDs.contains(entry.id),
                            onDeleteLink: deleteLocalLink,
                            onRemove: removeConfig
                        )
                        .tag(entry.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .modifier(ContentView.RowSeparatorVisibility())
                    }
                    .listStyle(.plain)
                    .modifier(ContentView.TransparentListBackground())
                }
            }

            ContentView.ActionFooter(
                title: migrateButtonTitle,
                icon: "arrow.right",
                isEnabled: !migratablePairs.isEmpty,
                action: migrateSelected
            )
        }
    }

    private var externalPane: some View {
        VStack(spacing: 0) {
            ContentView.HeaderView(
                title: "外部文件夹".localized,
                subtitle: String(format: "%lld 个目录".localized, Int64(configs.count)),
                icon: "externaldrive.fill",
                tint: .teal
            )

            ZStack {
                Color(nsColor: .controlBackgroundColor).ignoresSafeArea()

                if externalEntries.isEmpty {
                    ContentView.EmptyStateView(icon: "externaldrive.badge.plus", text: "未添加目录迁移".localized)
                } else {
                    List(externalEntries, selection: $selectedExternalIDs) { entry in
                        CustomDirRowView(
                            entry: entry,
                            isSelected: selectedExternalIDs.contains(entry.id),
                            onDeleteLink: deleteLocalLink,
                            onRemove: removeConfig
                        )
                        .tag(entry.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .modifier(ContentView.RowSeparatorVisibility())
                    }
                    .listStyle(.plain)
                    .modifier(ContentView.TransparentListBackground())
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: restoreSelected) {
                    Label(restoreButtonTitle, systemImage: "arrow.turn.up.left")
                        .frame(minWidth: 100, minHeight: 22)
                }
                .buttonStyle(.bordered)
                .disabled(restorablePairs.isEmpty)

                Button(action: relinkSelected) {
                    Label(relinkButtonTitle, systemImage: "link")
                        .frame(minWidth: 100, minHeight: 22)
                }
                .buttonStyle(AppListPrimaryButtonStyle())
                .disabled(relinkablePairs.isEmpty)
            }
            .modifier(AppListFooterStyle())
        }
    }

    private var migrateButtonTitle: String {
        if migratablePairs.isEmpty {
            return "迁移文件夹".localized
        }
        return String(format: "迁移 %lld 个文件夹".localized, Int64(migratablePairs.count))
    }

    private var relinkButtonTitle: String {
        if relinkablePairs.isEmpty {
            return "接回文件夹".localized
        }
        return String(format: "接回 %lld 个文件夹".localized, Int64(relinkablePairs.count))
    }

    private var restoreButtonTitle: String {
        if restorablePairs.isEmpty {
            return "还原文件夹".localized
        }
        return String(format: "还原 %lld 个文件夹".localized, Int64(restorablePairs.count))
    }

    private func addConfig(_ config: CustomDirConfig) -> String? {
        do { try configStore.insert(config); return nil }
        catch { return error.localizedDescription }
    }

    private func addAndMigrateConfig(_ config: CustomDirConfig) -> String? {
        if let errorMessage = addConfig(config) { return errorMessage }
        submitDirectoryTasks(title: "正在迁移目录".localized,
                             pairs: [CustomDirPair.pendingMigration(for: config)]) { pair, handler in
            try await Self.migratePair(pair, progressHandler: handler)
        }
        return nil
    }

    private func removeConfig(_ config: CustomDirConfig) {
        guard !operationState.isBusy else { return }
        do { try configStore.remove(id: config.id) }
        catch { errorMessage = error.localizedDescription; showError = true; return }
        pairs.removeAll { $0.config.id == config.id }
        selectedLocalIDs.remove("\(config.id.uuidString)-\(CustomDirEntryKind.local.rawValue)")
        selectedExternalIDs.remove("\(config.id.uuidString)-\(CustomDirEntryKind.external.rawValue)")
        refresh()
    }

    private func refresh(forceSizeRefresh: Bool = false) {
        guard isVisible else { return }
        directoryRefreshTask?.cancel()
        recordRefreshTask?.cancel()
        let requestID = UUID()
        let requestedConfigs = configs
        refreshRequestID = requestID
        isScanning = true

        // Directory status/size must not wait for the shared migration journal.
        directoryRefreshTask = Task.detached(priority: .userInitiated) {
            let scanner = CustomDirScanner()
            let result = await scanner.scan(configs: requestedConfigs, calculateSizes: true,
                                            forceSizeRefresh: forceSizeRefresh)
            let cacheTime = await scanner.sizeCacheUpdatedAt
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isVisible, refreshRequestID == requestID, configs == requestedConfigs else { return }
                pairs = result
                sizeCacheUpdatedAt = cacheTime
                selectedLocalIDs.formIntersection(Set(result.map(\.local.id)))
                selectedExternalIDs.formIntersection(Set(result.map(\.external.id)))
                isScanning = false
            }
        }
        guard !requestedConfigs.isEmpty else {
            managedLinks = []
            retainedTransfers = []
            return
        }
        recordRefreshTask = Task.detached(priority: .utility) {
            do {
                // Parse and validate once off the main thread. This document
                // also contains large application-data verification manifests.
                let inspection = try ContainerMountStore.shared.recordsForInspection()
                if let error = inspection.validationError { throw error }
                let links = inspection.managedLinks.filter { link in
                    requestedConfigs.contains { DataPathTopology.relationship($0.localURL.path, link.originalPath) == .same }
                }
                let transfers = inspection.transfers.filter { transfer in
                    requestedConfigs.contains { DataPathTopology.relationship($0.localURL.path, transfer.originalPath) == .same }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard isVisible, refreshRequestID == requestID, configs == requestedConfigs else { return }
                    managedLinks = links
                    retainedTransfers = transfers
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard isVisible, refreshRequestID == requestID, configs == requestedConfigs else { return }
                    managedLinks = []
                    retainedTransfers = []
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func invalidateRefresh() {
        directoryRefreshTask?.cancel()
        recordRefreshTask?.cancel()
        refreshRequestID = nil
        isScanning = false
    }

    private func retryPendingOperations() {
        let operationIDs = retainedTransfers.filter(\.needsAttention).map(\.operationID)
        guard !operationIDs.isEmpty else { return }
        MigrationTaskCenter.shared.submit(title: "正在继续处理目录".localized, category: .directories,
            resources: MigrationResources(paths: [], keys: ["all-file-operations"]), operation: { _ in
                var warnings: [String] = []
                for id in operationIDs {
                    try await MigrationExecution.control?.checkpointAsync()
                    try Task.checkCancellation()
                    warnings += await OperationMaintenance.shared.runManagedDataOperations(retryOperationID: id)
                }
                try Task.checkCancellation()
                return warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
            }, completion: { refresh() })
    }

    private func beginOperation() -> UUID? {
        guard let operationID = operationState.begin() else { return nil }
        invalidateRefresh()
        return operationID
    }

    private func migrateSelected() {
        let selectedPairs = migratablePairs
        guard !selectedPairs.isEmpty else { return }
        if presentOwnershipAdvisoryIfNeeded(for: selectedPairs) { return }
        startMigration(of: selectedPairs)
    }

    /// 目标盘存不住文件所有者时先说明一次；用户确认后照常迁移，不改变能否迁移的判定。
    /// - Returns: 是否已改为展示提示（此时不开始迁移）。
    private func presentOwnershipAdvisoryIfNeeded(for selectedPairs: [CustomDirPair]) -> Bool {
        let advisory = OwnershipStorageAdvisory()
        let drives = Set(selectedPairs.compactMap { pair -> String? in
            let destination = pair.config.externalDestinationURL
            guard let limitation = advisory.limitation(for: destination) else { return nil }
            let driveName = MountMigrationGuidance.driveName(for: destination.path)
            AppLogger.shared.logContext(
                "目录迁移目标盘不保存文件所有者",
                details: [
                    ("destination", destination.path),
                    ("drive_name", driveName),
                    ("limitation", String(describing: limitation))
                ],
                level: "WARN"
            )
            return limitation.advisoryMessage(driveName: driveName)
        })
        guard !drives.isEmpty else { return false }
        ownershipAdvisoryRequest = WarningSheetRequest(
            title: "这块磁盘不保存文件所有者".localized,
            tint: .orange,
            intro: drives.sorted().joined(separator: "\n\n"),
            actions: [
                WarningAction("继续迁移".localized, style: .preferred) { startMigration(of: selectedPairs) }
            ]
        )
        return true
    }

    private func startMigration(of selectedPairs: [CustomDirPair]) {
        submitDirectoryTasks(title: "正在迁移目录".localized, pairs: selectedPairs) { pair, handler in
            try await Self.migratePair(pair, progressHandler: handler)
        }
    }

    nonisolated private static func migratePair(_ pair: CustomDirPair, progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
        let item = pair.local.dataDirItem
        let result = try await DataDirMover().migrateAndComplete(
            item: item,
            to: pair.config.externalBaseURL,
            progressHandler: progressHandler
        )
        return result.cleanupWarning
    }

    private func relinkSelected() {
        submitDirectoryTasks(title: "正在接回目录".localized, pairs: relinkablePairs) { pair, _ in
            try await DataDirMover().createLink(localPath: pair.config.localURL,
                                               externalPath: pair.config.externalDestinationURL)
            return nil
        }
    }

    private func restoreSelected() {
        submitDirectoryTasks(title: "正在还原目录".localized, pairs: restorablePairs) { pair, handler in
            let result = try await DataDirMover().restoreAndComplete(item: pair.local.dataDirItem, progressHandler: handler)
            return result.cleanupWarning
        }
    }

    private func deleteLocalLink(_ entry: CustomDirEntry) {
        guard entry.kind == .local, let operationID = beginOperation() else { return }

        AppLogger.shared.logContext(
            "用户请求断开目录迁移链接",
            details: [
                ("name", entry.name),
                ("local_path", entry.url.path),
                ("external_path", entry.counterpartURL.path),
                ("status", entry.status)
            ]
        )

        operationState.startTask(for: operationID) { @MainActor in
            let lock = OperationLock()
            let acquired = await lock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                if acquired { lock.release() }
                operationState.finish(operationID)
            }
            do {
                guard acquired else { throw DataOperationSafety.Failure.occupied(entry.url.path) }
                try await DataDirMover().deleteLink(localPath: entry.url)
                await MainActor.run {
                    selectedLocalIDs.remove(entry.id)
                    refresh()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    refresh()
                }
            }
        }
    }

    private func submitDirectoryTasks(
        title: String, pairs selectedPairs: [CustomDirPair],
        operation: @escaping @Sendable (CustomDirPair, FileCopier.ProgressHandler?) async throws -> String?
    ) {
        for (index, pair) in selectedPairs.enumerated() {
            MigrationTaskCenter.shared.submit(title: title + " · " + pair.config.displayName,
                category: .directories,
                resources: MigrationResources(paths: [pair.config.localURL, pair.config.externalDestinationURL]),
                presentDetails: index == 0, operation: { progress in
                    try await MigrationExecution.control?.checkpointAsync()
                    progress.setDirectory(pair.config.localURL)
                    return try await operation(pair, { progress.update($0) })
                }, completion: {
                    selectedLocalIDs.remove(pair.local.id)
                    selectedExternalIDs.remove(pair.external.id)
                    refresh(forceSizeRefresh: true)
                })
        }
    }
}

private final class CustomDirLocalOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private let guardrail: CustomDirLocalOpenPanelGuard

    init(guardrail: CustomDirLocalOpenPanelGuard) {
        self.guardrail = guardrail
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        guardrail.shouldEnable(url)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        if let error = guardrail.validationError(for: url) {
            throw error
        }
    }
}

/// All windows share one published snapshot. Mutations reload the persisted state,
/// so even a second client cannot overwrite another client's completed edit.
@MainActor
final class CustomDirConfigStore: ObservableObject {
    static let shared = CustomDirConfigStore()
    private static let key = "customDirConfigs"
    private let defaults: UserDefaults
    @Published private(set) var configs: [CustomDirConfig]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configs = Self.load(defaults)
    }

    private static func load(_ defaults: UserDefaults) -> [CustomDirConfig] {
        guard let data = defaults.data(forKey: key),
              let configs = try? JSONDecoder().decode([CustomDirConfig].self, from: data) else { return [] }
        return configs
    }

    func insert(_ config: CustomDirConfig, homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        var current = Self.load(defaults)
        try CustomDirValidator.validate(localURL: config.localURL, externalBaseURL: config.externalBaseURL,
                                        existingConfigs: current, homeURL: homeURL)
        current.append(config)
        try save(current)
    }

    func remove(id: UUID) throws {
        try save(Self.load(defaults).filter { $0.id != id })
    }

    private func save(_ current: [CustomDirConfig]) throws {
        defaults.set(try JSONEncoder().encode(current), forKey: Self.key)
        configs = current
    }
}

@MainActor
private struct AddCustomDirSheet: View {
    let existingConfigs: [CustomDirConfig]
    let onMigrate: (CustomDirConfig) -> String?

    @ObservedObject private var operationState = AppOperationState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var localURL: URL?
    @State private var externalBaseURL: URL?
    @State private var errorMessage: String?

    private var finalDestinationURL: URL? {
        guard let localURL, let externalBaseURL else { return nil }
        return externalBaseURL.appendingPathComponent(localURL.lastPathComponent).standardizedFileURL
    }

    /// 目标盘存不住文件所有者时直接写在本页：这里点「迁移」就开始，弹窗会和
    /// 本页的关闭动画抢显示，反而容易漏看。
    private var ownershipNotice: String? {
        guard let finalDestinationURL,
              let limitation = OwnershipStorageAdvisory().limitation(for: finalDestinationURL) else { return nil }
        let driveName = MountMigrationGuidance.driveName(for: finalDestinationURL.path)
        return limitation.advisoryMessage(driveName: driveName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加目录迁移".localized)
                .font(.title3.weight(.semibold))

            directoryPickerRow(
                title: "本地目录 - 只支持迁移用户目录下的文件夹".localized,
                value: localURL?.path ?? "未选择".localized,
                buttonTitle: "选择本地目录".localized,
                buttonIcon: "folder.badge.plus",
                action: chooseLocalDirectory
            )

            directoryPickerRow(
                title: "外部目标文件夹".localized,
                value: externalBaseURL?.path ?? "未选择".localized,
                buttonTitle: "选择外部目标文件夹".localized,
                buttonIcon: "externaldrive.badge.plus",
                action: chooseExternalBaseDirectory
            )

            if let finalDestinationURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最终位置".localized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(finalDestinationURL.path)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(finalDestinationURL.path)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(8)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            if let ownershipNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text(ownershipNotice)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            }

            HStack {
                Spacer()
                Button(action: {
                    dismiss()
                }) {
                    sheetFooterLabel(title: "取消".localized, icon: "xmark")
                }
                .buttonStyle(.bordered)

                Button(action: {
                    add()
                }) {
                    sheetFooterLabel(title: "迁移".localized, icon: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(operationState.blocksInteraction || localURL == nil || externalBaseURL == nil)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private func directoryPickerRow(
        title: String,
        value: String,
        buttonTitle: String,
        buttonIcon: String,
        action: @escaping () -> Void
    ) -> some View {
        let placeholder = "未选择".localized

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundColor(value == placeholder ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(value)

                Button(action: action) {
                    HStack(spacing: 6) {
                        Image(systemName: buttonIcon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(buttonTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .frame(minWidth: 154)
                    .background(Color.accentColor.opacity(0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(buttonTitle)
            }
        }
    }

    private func sheetFooterLabel(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(title)
                .fontWeight(.medium)
                .font(.system(size: 13))
        }
        .frame(minWidth: 82)
        .frame(height: 28)
    }

    private func chooseLocalDirectory() {
        let panelGuard = CustomDirLocalOpenPanelGuard(existingConfigs: existingConfigs)
        if let url = chooseDirectory(
            message: "选择要迁移的本地文件夹".localized,
            startingAt: FileManager.default.homeDirectoryForCurrentUser,
            localPanelGuard: panelGuard
        ) {
            do {
                try CustomDirValidator.validateLocalDirectory(
                    url,
                    existingConfigs: existingConfigs
                )
            } catch {
                localURL = nil
                errorMessage = error.localizedDescription
                return
            }

            localURL = url
            errorMessage = nil
        }
    }

    private func chooseExternalBaseDirectory() {
        if let url = chooseDirectory(message: "选择外部目标父文件夹".localized) {
            do {
                try CustomDirValidator.validateExternalBaseDirectory(url)
                if let localURL {
                    try CustomDirValidator.validate(
                        localURL: localURL,
                        externalBaseURL: url,
                        existingConfigs: existingConfigs
                    )
                }
            } catch {
                externalBaseURL = nil
                errorMessage = error.localizedDescription
                return
            }

            externalBaseURL = url
            errorMessage = nil
        }
    }

    private func chooseDirectory(
        message: String,
        startingAt directoryURL: URL? = nil,
        localPanelGuard: CustomDirLocalOpenPanelGuard? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = "选择文件夹".localized
        panel.message = message
        panel.directoryURL = directoryURL
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false

        let panelDelegate = localPanelGuard.map(CustomDirLocalOpenPanelDelegate.init)
        panel.delegate = panelDelegate
        let response = withExtendedLifetime(panelDelegate) {
            panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    private func add() {
        guard !operationState.blocksInteraction else { return }
        guard let localURL, let externalBaseURL else {
            errorMessage = "请选择本地目录和外部目标文件夹".localized
            return
        }

        do {
            try CustomDirValidator.validate(
                localURL: localURL,
                externalBaseURL: externalBaseURL,
                existingConfigs: existingConfigs
            )
            let config = CustomDirConfig(localPath: localURL.path, externalBasePath: externalBaseURL.path)
            if let callbackError = onMigrate(config) {
                errorMessage = callbackError
                return
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
