//
//  AppStoreSettingsView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI

/// 设置页面
struct AppStoreSettingsView: View {
    @AppStorage("allowAppStoreMigration") private var allowAppStoreMigration = false
    @AppStorage("allowIOSAppMigration") private var allowIOSAppMigration = false
    
    // 日志设置绑定
    @AppStorage("LogEnabled") private var isLoggingEnabled = true
    @AppStorage("MaxLogSizeBytes") private var maxLogSize = 2 * 1024 * 1024
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

/// 警告横幅组件
struct WarningBanner: View {
    let icon: String
    let color: Color
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
