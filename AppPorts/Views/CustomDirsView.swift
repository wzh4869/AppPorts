//
//  CustomDirsView.swift
//  AppPorts
//
//  Created by Codex on 2026/6/26.
//

import SwiftUI
import AppKit

struct CustomDirsView: View {
    @State private var configs: [CustomDirConfig] = CustomDirConfigStore.load()
    @State private var pairs: [CustomDirPair] = []
    @State private var selectedLocalIDs: Set<String> = []
    @State private var selectedExternalIDs: Set<String> = []
    @State private var isScanning = false
    @State private var showAddSheet = false
    @State private var showError = false
    @State private var errorMessage = ""

    @State private var showProgress = false
    @State private var progressTitle = ""
    @State private var progressBytes: Int64 = 0
    @State private var progressTotalBytes: Int64 = 0
    @State private var progressFileName = ""

    private var localEntries: [CustomDirEntry] {
        pairs.map(\.local)
    }

    private var externalEntries: [CustomDirEntry] {
        pairs.map(\.external)
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
        selectedExternalPairs.filter { $0.external.status == CustomDirStatus.pendingRelink }
    }

    private var restorablePairs: [CustomDirPair] {
        selectedExternalPairs.filter { $0.external.status == CustomDirStatus.linked }
    }

    var body: some View {
        ZStack {
            HSplitView {
                localPane
                    .frame(minWidth: 320, maxWidth: .infinity)

                externalPane
                    .frame(minWidth: 320, maxWidth: .infinity)
            }

            if showProgress {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()

                DataDirProgressOverlay(
                    title: progressTitle,
                    copiedBytes: progressBytes,
                    totalBytes: progressTotalBytes,
                    currentFile: progressFileName
                )
            }
        }
        .onAppear {
            refresh()
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
    }

    private var localPane: some View {
        VStack(spacing: 0) {
            ContentView.HeaderView(
                title: "本地文件夹",
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
                    }
                    .listStyle(.plain)
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
                title: "外部文件夹",
                subtitle: String(format: "%lld 个目录".localized, Int64(configs.count)),
                icon: "externaldrive.fill"
            )

            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

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
                    }
                    .listStyle(.plain)
                }
            }

            VStack(spacing: 0) {
                Divider()
                    .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: -1)

                HStack(spacing: 8) {
                    Button(action: relinkSelected) {
                        footerLabel(title: relinkButtonTitle, icon: "link")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(relinkablePairs.isEmpty)

                    Button(action: restoreSelected) {
                        footerLabel(title: restoreButtonTitle, icon: "arrow.turn.up.left")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange.opacity(0.85))
                    .disabled(restorablePairs.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.bar)
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

    private func footerLabel(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(title.localized)
                .fontWeight(.medium)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
    }

    private func addConfig(_ config: CustomDirConfig) -> String? {
        guard !configs.contains(where: { $0.localURL == config.localURL }) else {
            return "该目录已在目录迁移列表中".localized
        }

        do {
            try CustomDirValidator.validate(
                localURL: config.localURL,
                externalBaseURL: config.externalBaseURL,
                existingConfigs: configs
            )
        } catch {
            return error.localizedDescription
        }

        configs.append(config)
        saveConfigs()
        return nil
    }

    private func addAndMigrateConfig(_ config: CustomDirConfig) -> String? {
        if let errorMessage = addConfig(config) {
            return errorMessage
        }

        runBatch(
            title: "正在迁移目录".localized,
            pairs: [CustomDirPair.pendingMigration(for: config)],
            operation: migratePair
        )
        return nil
    }

    private func removeConfig(_ config: CustomDirConfig) {
        configs.removeAll { $0.id == config.id }
        selectedLocalIDs.remove("\(config.id.uuidString)-\(CustomDirEntryKind.local.rawValue)")
        selectedExternalIDs.remove("\(config.id.uuidString)-\(CustomDirEntryKind.external.rawValue)")
        saveConfigs()
        refresh()
    }

    private func saveConfigs() {
        CustomDirConfigStore.save(configs)
    }

    private func refresh() {
        isScanning = true
        Task {
            let scanner = CustomDirScanner()
            let result = await scanner.scan(configs: configs, calculateSizes: true)
            await MainActor.run {
                pairs = result
                selectedLocalIDs.formIntersection(Set(result.map(\.local.id)))
                selectedExternalIDs.formIntersection(Set(result.map(\.external.id)))
                isScanning = false
            }
        }
    }

    private func migrateSelected() {
        runBatch(
            title: "正在迁移目录".localized,
            pairs: migratablePairs,
            operation: migratePair
        )
    }

    private func migratePair(_ pair: CustomDirPair, progressHandler: FileCopier.ProgressHandler?) async throws {
        let item = pair.local.dataDirItem
        try await DataDirMover().migrate(
            item: item,
            to: pair.config.externalBaseURL,
            progressHandler: progressHandler
        )
    }

    private func relinkSelected() {
        runBatch(
            title: "正在接回目录".localized,
            pairs: relinkablePairs,
            operation: { pair, _ in
                try await DataDirMover().createLink(
                    localPath: pair.config.localURL,
                    externalPath: pair.config.externalDestinationURL
                )
            }
        )
    }

    private func restoreSelected() {
        runBatch(
            title: "正在还原目录".localized,
            pairs: restorablePairs,
            operation: { pair, progressHandler in
                let item = pair.local.dataDirItem
                try await DataDirMover().restore(item: item, progressHandler: progressHandler)
            }
        )
    }

    private func deleteLocalLink(_ entry: CustomDirEntry) {
        guard entry.kind == .local else { return }

        AppLogger.shared.logContext(
            "用户请求断开目录迁移链接",
            details: [
                ("name", entry.name),
                ("local_path", entry.url.path),
                ("external_path", entry.counterpartURL.path),
                ("status", entry.status)
            ]
        )

        Task {
            do {
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

    private func runBatch(
        title: String,
        pairs selectedPairs: [CustomDirPair],
        operation: @escaping (CustomDirPair, FileCopier.ProgressHandler?) async throws -> Void
    ) {
        guard !selectedPairs.isEmpty else { return }

        progressTitle = title
        progressBytes = 0
        progressTotalBytes = 0
        progressFileName = ""
        showProgress = true

        Task {
            do {
                for pair in selectedPairs {
                    await MainActor.run {
                        progressFileName = pair.config.displayName
                    }

                    try await operation(pair) { progress in
                        await MainActor.run {
                            progressBytes = progress.copiedBytes
                            progressTotalBytes = progress.totalBytes
                            progressFileName = progress.currentFile.isEmpty ? pair.config.displayName : progress.currentFile
                        }
                    }
                }

                await MainActor.run {
                    showProgress = false
                    selectedLocalIDs.removeAll()
                    selectedExternalIDs.removeAll()
                    refresh()
                }
            } catch {
                await MainActor.run {
                    showProgress = false
                    errorMessage = error.localizedDescription
                    showError = true
                    refresh()
                }
            }
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

private enum CustomDirConfigStore {
    private static let key = "customDirConfigs"

    static func load() -> [CustomDirConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configs = try? JSONDecoder().decode([CustomDirConfig].self, from: data) else {
            return []
        }
        return configs
    }

    static func save(_ configs: [CustomDirConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct AddCustomDirSheet: View {
    let existingConfigs: [CustomDirConfig]
    let onMigrate: (CustomDirConfig) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var localURL: URL?
    @State private var externalBaseURL: URL?
    @State private var errorMessage: String?

    private var finalDestinationURL: URL? {
        guard let localURL, let externalBaseURL else { return nil }
        return externalBaseURL.appendingPathComponent(localURL.lastPathComponent).standardizedFileURL
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
                .disabled(localURL == nil || externalBaseURL == nil)
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
