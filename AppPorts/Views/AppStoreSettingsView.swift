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
    
    /// 环境变量：用于关闭弹窗
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // 标题栏
            HStack {
                Image(systemName: "app.badge.checkmark")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("设置")
                    .font(.title2.bold())
                
                Spacer()
                
                // 关闭按钮
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.bottom, 8)
            
            // 说明
            Text("默认情况下，来自 App Store 的应用不允许迁移，因为迁移后将无法通过 App Store 更新。")
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
                            Text("允许迁移 Mac App Store 应用")
                                .font(.headline)
                        }
                        Text("启用后可以迁移来自 Mac App Store 的原生 Mac 应用")
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
                        text: "迁移后的 App Store 应用将无法自动更新，需要手动还原后才能更新"
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
                            Text("允许迁移非原生应用")
                                .font(.headline)
                        }
                        Text("启用后可以迁移来自 iPhone/iPad 的非原生 Mac 应用（使用整体链接）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $allowIOSAppMigration)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                if allowIOSAppMigration {
                    WarningBanner(
                        icon: "info.circle.fill",
                        color: .blue,
                        text: "由于 iOS 应用结构限制，迁移后 Finder 图标会显示箭头（macOS 系统行为）"
                    )
                }
            }
            .padding()
            .frame(minHeight: 110)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(12)
            
            // 日志设置
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(.gray)
                            Text("日志设置")
                                .font(.headline)
                        }
                        Text("管理应用运行日志和诊断信息")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $isLoggingEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("启用/禁用日志记录")
                }
                
                if isLoggingEnabled {
                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack {
                        Text("最大日志大小:")
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
                        Button("在 Finder 中查看") {
                            AppLogger.shared.openLogInFinder()
                        }
                        
                        Spacer()
                        
                        Button("清空日志") {
                            AppLogger.shared.clearLog()
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
                Text("更改设置后，请刷新应用列表以查看效果")
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

#Preview {
    AppStoreSettingsView()
}
