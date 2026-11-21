import SwiftUI

/// Preferences share the main window's content area and persistent app state.
@MainActor
struct AppStoreSettingsView: View {
    @AppStorage(MigrationTaskHistoryStore.clearCompletedOnExitKey) private var clearCompletedTasksOnExit = true
    @AppStorage("allowAppStoreMigration") private var allowAppStoreMigration = false
    @AppStorage("allowIOSAppMigration") private var allowIOSAppMigration = false
    @AppStorage("LogEnabled") private var isLoggingEnabled = true
    @AppStorage("MaxLogSizeBytes") private var maxLogSize = 2 * 1024 * 1024
    @AppStorage(AutoResignInstaller.policyErrorDefaultsKey) private var autoResignPolicyError = ""
    @AppStorage(MigrationPreferences.classicDataMigrationKey) private var classicDataMigrationEnabled = false
    @AppStorage(BackgroundAgentPreferences.diskMaintenanceKey) private var diskMaintenanceEnabled = true
    @AppStorage(BackgroundAgentPreferences.updateGuardianKey) private var updateGuardianEnabled = true
    @AppStorage(LaunchReadinessChecker.externalDrivePathKey) private var externalDrivePath = ""
    @State private var isRetryingAutoResignCleanup = false
    @State private var showClassicModeAcknowledgement = false
    @State private var classicModeAcknowledged = false
    @StateObject private var readiness: ReadinessCheckModel
    @ObservedObject private var operationState = AppOperationState.shared
    @ObservedObject private var permissionReadiness = PermissionReadiness.shared
    @ObservedObject private var agentSync: AppLibraryAgentSync
    @ObservedObject private var appStoreInstall: AppStoreExternalInstallSettings

    init(agentSync: AppLibraryAgentSync? = nil, readiness: ReadinessCheckModel? = nil,
         appStoreInstall: AppStoreExternalInstallSettings? = nil) {
        self.agentSync = agentSync ?? .shared
        self.appStoreInstall = appStoreInstall ?? .shared
        _readiness = StateObject(wrappedValue: readiness ?? ReadinessCheckModel())
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                settingsContent(width: geometry.size.width - 2 * AppSettingsStyle.contentInset)
                    .padding(AppSettingsStyle.contentInset)
                Text("更改设置后，请刷新应用列表以查看效果".localized)
                    .font(AppSettingsStyle.secondaryFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSettingsStyle.contentInset)
                    .padding(.bottom, AppSettingsStyle.contentInset)
            }
        }
        .font(AppSettingsStyle.bodyFont)
        .controlSize(AppSettingsStyle.controlSize)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSettingsStyle.background)
        .sheet(isPresented: $showClassicModeAcknowledgement) { classicModeAcknowledgementSheet }
        .modifier(AppUpdatePresentationDismissal {
            showClassicModeAcknowledgement = false
        })
        .onAppear(perform: refreshAppStoreInstall)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAppStoreInstall()
        }
        .onChange(of: externalDrivePath) { _ in refreshAppStoreInstall() }
        .onChange(of: diskMaintenanceEnabled) { _ in agentSync.selectionDidChange() }
        .onChange(of: updateGuardianEnabled) { _ in agentSync.selectionDidChange() }
    }

    @ViewBuilder
    private func settingsContent(width: CGFloat) -> some View {
        settingsColumns(width: width)
    }

    private var applicationReadinessSection: some View {
        VStack(alignment: .leading, spacing: AppSettingsStyle.sectionGap) {
            UpdateSettingsSection(isEmbedded: true)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: AppSettingsStyle.rowGap) {
                Text("准备情况".localized)
                    .font(AppSettingsStyle.sectionFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PermissionCheckButton(level: permissionReadiness.level, attentionText: permissionReadiness.attentionText) {
                    readiness.refresh()
                    refreshAppStoreInstall()
                }
                .disabled(readiness.isChecking)
            }
            ReadinessCheckView(refreshPlacement: .hidden, isEmbedded: true, model: readiness)
        }
        .modifier(AppSettingsPanelStyle())
    }

    @ViewBuilder
    private func settingsColumns(width: CGFloat) -> some View {
        if width >= 2 * AppSettingsStyle.minimumColumnWidth + AppSettingsStyle.gap {
            let columnWidth = (width - AppSettingsStyle.gap) / 2
            HStack(alignment: .top, spacing: AppSettingsStyle.gap) {
                VStack(spacing: AppSettingsStyle.gap) {
                    backgroundAgentsSection
                    migrationSection
                    logsSection
                }
                .frame(width: columnWidth)
                VStack(spacing: AppSettingsStyle.gap) {
                    applicationReadinessSection
                    classicModeSection
                    taskCenterSection
                }
                .frame(width: columnWidth)
            }
        } else {
            VStack(spacing: AppSettingsStyle.gap) {
                applicationReadinessSection
                backgroundAgentsSection
                migrationSection
                classicModeSection
                logsSection
                taskCenterSection
            }
        }
    }

    private var taskCenterSection: some View {
        AppSettingsSection(title: "任务中心".localized) {
            Toggle("退出后清理已完成的任务列表".localized, isOn: $clearCompletedTasksOnExit)
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var backgroundAgentsSection: some View {
        AppSettingsSection(title: "Background agents".localized) {
            AppSettingsToggle(title: "Disk maintenance agent".localized,
                detail: "At login or when an external drive reconnects, restore migrated data volumes and the app library, and keep AppPorts-managed APFS data volumes hidden.".localized,
                isOn: $diskMaintenanceEnabled)
            Divider()
            AppSettingsToggle(title: "Application update guardian".localized,
                detail: "Keep watching migrated apps after AppPorts quits. Attempt recovery when a ShipIt update fails and report the result in the task center.".localized,
                isOn: $updateGuardianEnabled)
            if agentSync.isSynchronizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Applying background settings…".localized).foregroundStyle(.secondary)
                }
                .font(AppSettingsStyle.secondaryFont)
            }
            if agentSync.errorMessage != nil || agentSync.guardianRetrying {
                VStack(alignment: .leading, spacing: AppSettingsStyle.rowGap) {
                    if let error = agentSync.errorMessage {
                        Text("Background agent settings could not be applied.".localized).foregroundStyle(.red)
                        Text(verbatim: error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("更新守护尚未就绪，正在重试…".localized).foregroundStyle(.secondary)
                    }
                    Button("重试".localized) { agentSync.selectionDidChange() }
                        .font(AppSettingsStyle.bodyFont)
                }
                .font(AppSettingsStyle.secondaryFont)
            }
        }
        .disabled(operationState.blocksInteraction || agentSync.isSynchronizing)
    }

    @ViewBuilder
    private var migrationSection: some View {
        if AppMigrationService.isMASExternalInstallSupported {
            AppStoreExternalInstallSection(settings: appStoreInstall)
                .onAppear { allowAppStoreMigration = true; allowIOSAppMigration = true }
        } else {
            AppSettingsSection(title: "Migration behavior".localized) {
                AppSettingsToggle(title: "允许迁移 Mac App Store 应用".localized,
                    detail: "启用后可以迁移来自 Mac App Store 的原生 Mac 应用".localized, isOn: $allowAppStoreMigration)
                if allowAppStoreMigration {
                    WarningBanner(icon: "exclamationmark.triangle.fill", color: .orange,
                        text: "迁移后的 App Store 应用将无法自动更新，需要手动还原后才能更新".localized)
                }
                Divider()
                AppSettingsToggle(title: "允许迁移非原生应用".localized,
                    detail: "启用后可以迁移来自 iPhone/iPad 的非原生 Mac 应用".localized, isOn: $allowIOSAppMigration)
            }
        }
    }

    private func refreshAppStoreInstall() {
        appStoreInstall.refresh(for: externalDrivePath.isEmpty ? nil : URL(fileURLWithPath: externalDrivePath))
    }

    private var classicModeSection: some View {
        AppSettingsSection(title: "经典数据迁移模式（不推荐）".localized) {
            AppSettingsToggle(title: "开启经典模式".localized,
                detail: (!MigrationPreferences.isMacOS27OrLater
                    ? "容器数据改回符号链接迁移，并允许对沙盒应用重签名。只适合暂不升级 macOS 27 且外置盘不是 APFS 的用户。"
                    : "在 macOS 27 上，被重签名的沙盒应用可能无法打开。仍可开启，但推荐挂载迁移。").localized,
                isOn: Binding(get: { classicDataMigrationEnabled && MigrationPreferences.isClassicModeSupported }, set: { enabled in
                    if enabled { classicModeAcknowledged = false; showClassicModeAcknowledgement = true }
                    else { classicDataMigrationEnabled = false; AppLogger.shared.log("经典数据迁移模式已关闭") }
                }))
                .disabled(!MigrationPreferences.isClassicModeSupported)
            Link("查看完整说明".localized,
                 destination: DocumentationLink.url(page: "settings", anchor: "classic-data-migration-mode"))
                .font(AppSettingsStyle.secondaryFont)
            if classicDataMigrationEnabled && MigrationPreferences.isClassicModeSupported {
                WarningBanner(icon: "exclamationmark.triangle.fill", color: .red,
                    text: "经典模式下迁移过容器数据并重签名的应用，升级 macOS 27 前应先还原容器数据，再恢复原始签名或重装。请先处理应用列表中带「签名已替换」标记的应用。".localized)
            }
        }
    }

    private var logsSection: some View {
        AppSettingsSection(title: "日志设置".localized) {
            AppSettingsToggle(title: "启用日志记录".localized,
                detail: "管理应用运行日志和诊断信息".localized, isOn: $isLoggingEnabled)
            if isLoggingEnabled {
                Divider()
                HStack {
                    Text("最大日志大小".localized)
                    Spacer()
                    Picker("最大日志大小".localized, selection: $maxLogSize) {
                        ForEach([1, 2, 5, 10, 50, 100], id: \.self) { size in
                            Text(verbatim: "\(size) MB").tag(size * 1024 * 1024)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                HStack {
                    Button("在 Finder 中查看".localized) { AppLogger.shared.openLogInFinder() }
                    Button("导出诊断包".localized) { AppLogger.shared.exportDiagnosticPackageInteractively() }
                }
                Button("清空日志".localized) { AppLogger.shared.clearLog() }
            }
            if !autoResignPolicyError.isEmpty {
                Divider()
                Text("旧的登录重签任务尚未完全关闭，请重试。".localized).foregroundStyle(.orange)
                Text(verbatim: autoResignPolicyError).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("重试".localized, action: retryAutoResignCleanup)
                    .disabled(operationState.isBusy || isRetryingAutoResignCleanup)
            }
        }
    }

    @MainActor
    private func retryAutoResignCleanup() {
        isRetryingAutoResignCleanup = true
        Task {
            defer { isRetryingAutoResignCleanup = false }
            do {
                try await AutoResignInstaller.refreshInstalledScriptIfNeeded()
            } catch {
                AppLogger.shared.logError("重试关闭开机重签任务失败", error: error)
            }
        }
    }

    private var classicModeAcknowledgementSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.title2)
                Text("开启经典数据迁移模式前请确认".localized)
                    .font(.title3.bold())
            }

            Text("经典模式会恢复 AppPorts 1.8.1 及以前的做法，包括它已知的风险：".localized)
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                Label("容器目录（微信聊天记录等）用符号链接迁移；沙盒应用必须重签名才能读到数据。".localized, systemImage: "link")
                Label("重签名会移除应用的沙盒、应用组和钥匙串授权。新版会先完整备份原应用，以便恢复；旧版仅记录签名身份的备份无法直接恢复。".localized, systemImage: "seal")
                Label("升级到 macOS 27 后，被重签名的沙盒应用可能双击秒退，需要先还原容器数据，再恢复原始签名或重装。".localized, systemImage: "xmark.octagon")
                Label("推荐做法是把外置盘格式化成 APFS 并使用挂载迁移，签名不需要任何改动。".localized, systemImage: "checkmark.shield")
            }
            .font(.callout)
            .foregroundColor(.secondary)

            Link("查看完整说明".localized, destination: DocumentationLink.url(page: "settings", anchor: "classic-data-migration-mode"))
                .font(.callout)

            Toggle("我已了解以上风险".localized, isOn: $classicModeAcknowledged)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("取消".localized) {
                    showClassicModeAcknowledgement = false
                }
                .keyboardShortcut(.cancelAction)
                Button("开启经典模式".localized) {
                    classicDataMigrationEnabled = true
                    showClassicModeAcknowledgement = false
                    AppLogger.shared.log("经典数据迁移模式已开启（用户已确认风险）", level: "WARN")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!classicModeAcknowledged)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

// MARK: - 警告横幅组件

/// 警告信息横幅组件
///
/// 用于显示重要提示和警告信息。
///
/// ## 视觉设计
/// - 左侧：彩色图标
/// - 右侧：提示文本
/// - 背景：和图标颜色相匹配的淡色背景
///
/// ## 使用场景
/// - 橙色警告：重要注意事项
/// - 蓝色提示：一般信息说明
///
/// - Note: 圆角设计，和设置项卡片风格一致
struct WarningBanner: View {
    /// SF Symbols 图标名称
    let icon: String
    
    /// 图标和背景颜色
    let color: Color
    
    /// 提示文本
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct AppStoreSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AppStoreSettingsView()
    }
}
