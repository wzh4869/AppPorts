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
    /// 是否允许迁移 Mac App Store 应用
    @AppStorage("allowAppStoreMigration") private var allowAppStoreMigration = false
    
    /// 是否允许迁移 iOS/iPad 应用
    @AppStorage("allowIOSAppMigration") private var allowIOSAppMigration = false
    
    /// 是否启用日志记录
    @AppStorage("LogEnabled") private var isLoggingEnabled = true
    
    /// 最大日志文件大小（字节）
    @AppStorage("MaxLogSizeBytes") private var maxLogSize = 2 * 1024 * 1024
    
    /// 是否启用开机自动重签名（默认开启）
    @AppStorage("autoResignAtLogin") private var autoResignAtLogin = true

    /// 环境变量：用于关闭弹窗
    @Environment(\.dismiss) private var dismiss

    private var isMASExternalSupported: Bool { AppMigrationService.isMASExternalInstallSupported }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // 标题栏
            HStack {
                Image(systemName: "app.badge.checkmark")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("设置".localized)
                    .font(.title2.bold())

                Spacer()

                // 关闭按钮
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭".localized)
            }
            .padding(.bottom, 8)

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

                        Toggle("", isOn: $allowAppStoreMigration)
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
                .frame(minHeight: 110)
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

                        Toggle("", isOn: $allowIOSAppMigration)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                .padding()
                .frame(minHeight: 110)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
            }
            
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
                    
                    Toggle("", isOn: $isLoggingEnabled)
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
                        Picker("", selection: $maxLogSize) {
                            Text("1 MB").tag(1 * 1024 * 1024)
                            Text("5 MB").tag(5 * 1024 * 1024)
                            Text("10 MB").tag(10 * 1024 * 1024)
                            Text("50 MB").tag(50 * 1024 * 1024)
                            Text("100 MB").tag(100 * 1024 * 1024)
                        }
                        .frame(width: 100)
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
            .background(Color.primary.opacity(0.03))
            .cornerRadius(12)

            // 开机自动重签名
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.orange)
                            Text("开机自动重签名".localized)
                                .font(.headline)
                        }
                        Text("macOS 重启后 Gatekeeper 可能使 Ad-hoc 签名失效。开启后每次登录自动对已迁移应用重新签名。".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Toggle("", isOn: $autoResignAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: autoResignAtLogin) { enabled in
                            if enabled {
                                do {
                                    try AutoResignInstaller.install()
                                } catch {
                                    AppLogger.shared.logError(
                                        "安装自动重签名失败",
                                        error: error,
                                        errorCode: "AUTO-RESIGN-INSTALL-FAILED"
                                    )
                                    autoResignAtLogin = false
                                }
                            } else {
                                AutoResignInstaller.uninstall()
                            }
                        }
                }
            }
            .padding()
            .background(Color.primary.opacity(0.03))
            .cornerRadius(12)

            Spacer()

            // 底部说明
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("更改设置后，请刷新应用列表以查看效果".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 550)
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
