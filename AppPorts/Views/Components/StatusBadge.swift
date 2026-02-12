//
//  StatusBadge.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI

// MARK: - 状态徽章组件

/// 应用状态徽章视图
///
/// 以胶囊形状的徽章显示应用的当前状态，包括：
/// - ✅ 已链接（绿色）：应用已迁移到外部存储并创建了符号链接
/// - ▶️ 运行中（紫色）：应用当前正在运行
/// - 🔒 系统（灰色）：macOS 系统应用
/// - 📱 非原生（粉色）：iOS/iPadOS 应用（通过 Apple Silicon 运行）
/// - 🏪 商店（蓝色）：Mac App Store 应用
/// - 📀 未链接（橙色）：应用在外部存储但未链接回本地
/// - 💻 本地（次要色）：普通本地应用
///
/// ## 设计特点
/// - 使用 SF Symbols 图标增强视觉识别
/// - 颜色编码快速传达状态信息
/// - 圆角胶囊形状现代简洁
/// - 半透明背景和边框提升层次感
///
/// - Note: 自动支持无障碍功能（Accessibility）
struct StatusBadge: View {
    /// 应用项目数据
    let app: AppItem
    
    /// 根据应用状态计算徽章配置
    ///
    /// 优先级顺序：
    /// 1. 已链接状态（最高优先级）
    /// 2. 运行状态
    /// 3. 系统应用
    /// 4. iOS 应用
    /// 5. App Store 应用
    /// 6. 未链接/外部/本地
    ///
    /// - Returns: (文本, 图标名称, 颜色) 元组
    var config: (text: String, icon: String, color: Color) {
        if app.status == "已链接" {
            return ("已链接", "link", .green)
        } else if app.status == "部分链接" {
            return ("部分链接", "link.badge.plus", .yellow)
        } else if app.isRunning {
            return ("运行中", "play.fill", .purple)
        } else if app.isSystemApp {
            return ("系统", "lock.fill", .gray)
        } else if app.isIOSApp {
            // iOS/iPad 应用（非原生 Mac 应用）
            return ("非原生", "iphone", .pink)
        } else if app.isAppStoreApp {
            return ("商店", "applelogo", .blue)
        } else if app.status == "外部" { // Legacy fallback
            return ("外部", "externaldrive", .orange)
        } else if app.status == "未链接" {
            return ("未链接", "externaldrive.badge.xmark", .orange)
        } else {
            return ("本地", "macmini", .secondary)
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: config.icon)
                .font(.system(size: 9, weight: .bold))
            
            Text(config.text.localized)
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(config.color)
        .background(config.color.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(config.color.opacity(0.2), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(config.text.localized)
        .accessibilityAddTraits(.isStaticText)
    }
}
