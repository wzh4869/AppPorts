//
//  AppStoreSettingsView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI

// MARK: - 设置界面

/// 应用设置配置界面
///
/// 提供应用迁移行为和日志管理的配置选项：
/// - 🏪 **App Store 应用迁移**：默认禁止，启用后无法通过 App Store 更新
/// - 📱 **iOS 应用迁移**：默认禁止，启用后 Finder 图标会显示箭头
/// - 📝 **日志设置**：启用/禁用日志、配置最大大小、查看/清空日志
///
/// ## 设置项说明
///
/// ### 1. Mac App Store 应用迁移
/// - 默认禁止迁移来自 Mac App Store 的应用
/// - 迁移后应用将无法通过 App Store 自动更新
/// - 需要手动还原到 `/Applications` 后才能更新
///
/// ### 2. iOS/iPad 应用迁移
/// - 默认禁止迁移 iOS/iPadOS 应用（在 Apple Silicon Mac 上运行）
/// - iOS 应用使用整体链接方式迁移
/// - 迁移后 Finder 中会显示箭头图标（macOS 系统行为）
///
/// ### 3. 日志设置
/// - 启用/禁用日志记录
/// - 配置最大日志文件大小（1MB - 100MB）
/// - 在 Finder 中查看日志文件
/// - 清空日志文件
///
/// - Note: 设置使用 `@AppStorage` 自动持久化到 UserDefaults
struct AppStoreSettingsView: View {
    @AppStorage(MigrationTaskHistoryStore.clearCompletedOnExitKey) private var clearCompletedTasksOnExit = true
    /// 是否允许迁移 Mac App Store 应用
    @AppStorage("allowAppStoreMigration") private var allowAppStoreMigration = false
    
    /// 是否允许迁移 iOS/iPad 应用
    @AppStorage("allowIOSAppMigration") private var allowIOSAppMigration = false
    
    /// 是否启用日志记录
    @AppStorage("LogEnabled") private var isLoggingEnabled = true
    
    /// 最大日志文件大小（字节）
    @AppStorage("MaxLogSizeBytes") private var maxLogSize = 2 * 1024 * 1024
    
    /// Only a failed retirement needs a settings action; login signing is no longer a feature.
    @AppStorage(AutoResignInstaller.policyErrorDefaultsKey) private var autoResignPolicyError = ""
    @State private var isRetryingAutoResignCleanup = false

    /// 经典数据迁移模式：容器目录允许符号链接迁移、沙盒应用允许重签名。默认关闭。
    @AppStorage(MigrationPreferences.classicDataMigrationKey) private var classicDataMigrationEnabled = false
    @State private var showClassicModeAcknowledgement = false
    @State private var classicModeAcknowledged = false

    /// 准备情况检查面板
    @State private var showReadinessCheck = false

    /// 环境变量：用于关闭弹窗
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var operationState = AppOperationState.shared

    private var isMASExternalSupported: Bool { AppMigrationService.isMASExternalInstallSupported }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsHeader

            Divider()

            // 正文放进 ScrollView：设置项比窗口高时不再把表头（含关闭按钮）顶出可视区域。
            ScrollView(.vertical, showsIndicators: false) {
                settingsContent
            }
            .frame(minHeight: 320)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(minWidth: 560, idealWidth: 560, maxWidth: 560)
        .sheet(isPresented: $showReadinessCheck) {
            ReadinessCheckSheet()
        }
        .sheet(isPresented: $showClassicModeAcknowledgement) {
            classicModeAcknowledgementSheet
        }
    }

    /// 固定表头：不随正文滚动，关闭按钮任何时候都点得到。
    private var settingsHeader: some View {
        HStack {
            Image(systemName: "app.badge.checkmark")
                .font(.title2)
                .foregroundColor(.blue)
            Text("设置".localized)
                .font(.title2.bold())

            Spacer()

            // 关闭按钮，Esc 也能关
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭".localized)
        }
        .padding(.bottom, 12)
    }

    /// 可滚动的设置正文。
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            UpdateSettingsSection()

            Divider()

            readinessSection

            if isMASExternalSupported {
                // macOS 15.1+：自动启用，显示说明
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("macOS 15.1+ 已原生支持 App Store 应用外部安装".localized)
                            .font(.headline)
                    }
                    Text("App Store 应用和非原生应用可直接迁移，无需手动开启。App Store 会自动管理外部磁盘上的应用更新。".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.06))
                .cornerRadius(12)
                .onAppear {
                    // 自动启用
                    allowAppStoreMigration = true
                    allowIOSAppMigration = true
                }
            } else {
                // macOS < 15.1：显示原有开关
                Text("默认情况下，来自 App Store 的应用不允许迁移，因为迁移后将无法通过 App Store 更新。".localized)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // Mac App Store 应用设置
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "applelogo")
                                    .foregroundColor(.blue)
                                Text("允许迁移 Mac App Store 应用".localized)
                                    .font(.headline)
                            }
                            Text("启用后可以迁移来自 Mac App Store 的原生 Mac 应用".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("允许迁移 Mac App Store 应用".localized, isOn: $allowAppStoreMigration)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if allowAppStoreMigration {
                        WarningBanner(
                            icon: "exclamationmark.triangle.fill",
                            color: .orange,
                            text: "迁移后的 App Store 应用将无法自动更新，需要手动还原后才能更新".localized
                        )
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)

                // iOS/iPad 应用设置
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "iphone")
                                    .foregroundColor(.pink)
                                Text("允许迁移非原生应用".localized)
                                    .font(.headline)
                            }
                            Text("启用后可以迁移来自 iPhone/iPad 的非原生 Mac 应用".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("允许迁移非原生应用".localized, isOn: $allowIOSAppMigration)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
            }
            
            Toggle("退出后清理已完成的任务列表".localized, isOn: $clearCompletedTasksOnExit)
                .toggleStyle(.checkbox)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)

            // 日志设置
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(.gray)
                            Text("日志设置".localized)
                                .font(.headline)
                        }
                        Text("管理应用运行日志和诊断信息".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("启用日志记录".localized, isOn: $isLoggingEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("启用/禁用日志记录".localized)
                }
                
                if isLoggingEnabled {
                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack {
                        Text("最大日志大小".localized + ":")
                        Spacer()
                        Picker("最大日志大小".localized, selection: $maxLogSize) {
                            Text("1 MB").tag(1 * 1024 * 1024)
                            Text("2 MB").tag(2 * 1024 * 1024)
                            Text("5 MB").tag(5 * 1024 * 1024)
                            Text("10 MB").tag(10 * 1024 * 1024)
                            Text("50 MB").tag(50 * 1024 * 1024)
                            Text("100 MB").tag(100 * 1024 * 1024)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .frame(minWidth: 112, alignment: .trailing)
                    }
                    
                    HStack {
                        Button("在 Finder 中查看".localized) {
                            AppLogger.shared.openLogInFinder()
                        }

                        Button("导出诊断包".localized) {
                            AppLogger.shared.exportDiagnosticPackageInteractively()
                        }
                        
                        Spacer()
                        
                        Button("清空日志".localized) {
                            AppLogger.shared.clearLog()
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(12)

            if !autoResignPolicyError.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("旧的登录重签任务尚未完全关闭，请重试。".localized)
                        .foregroundColor(.orange)
                    Text(verbatim: autoResignPolicyError)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试".localized, action: retryAutoResignCleanup)
                        .disabled(operationState.isBusy || isRetryingAutoResignCleanup)
                }
                .font(.caption)
            }

            classicModeSection

            // 底部说明
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("更改设置后，请刷新应用列表以查看效果".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 20)
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

    // MARK: - 准备情况

    /// 权限与外部存储格式的检查入口。欢迎屏只在首次走一遍，之后都从这里进。
    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .foregroundColor(.blue)
                        Text("准备情况".localized)
                            .font(.headline)
                    }
                    Text("检查迁移所需的权限与外部存储格式".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("检查".localized) {
                    showReadinessCheck = true
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(12)
    }

    // MARK: - 经典数据迁移模式

    private var classicModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.red)
                        Text("经典数据迁移模式（不推荐）".localized)
                            .font(.headline)
                    }
                    Text(!MigrationPreferences.isMacOS27OrLater
                         ? "容器数据改回符号链接迁移，并允许对沙盒应用重签名。只适合暂不升级 macOS 27 且外置盘不是 APFS 的用户。".localized
                         : "在 macOS 27 上，被重签名的沙盒应用可能无法打开。仍可开启，但推荐挂载迁移。".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("查看完整说明".localized, destination: DocumentationLink.url(page: "settings", anchor: "classic-data-migration-mode"))
                        .font(.caption)
                        .padding(.top, 4)
                }

                Spacer()

                Toggle("经典数据迁移模式（不推荐）".localized, isOn: Binding(
                    get: { classicDataMigrationEnabled && MigrationPreferences.isClassicModeSupported },
                    set: { enabled in
                        if enabled {
                            classicModeAcknowledged = false
                            showClassicModeAcknowledgement = true
                        } else {
                            classicDataMigrationEnabled = false
                            AppLogger.shared.log("经典数据迁移模式已关闭")
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!MigrationPreferences.isClassicModeSupported)
            }

            if classicDataMigrationEnabled && MigrationPreferences.isClassicModeSupported {
                WarningBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    text: "经典模式下迁移过容器数据并重签名的应用，升级 macOS 27 前应先还原容器数据，再恢复原始签名或重装。请先处理应用列表中带「签名已替换」标记的应用。".localized
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(12)
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
