//
//  StatusBadge.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI

/// 状态胶囊
struct StatusBadge: View {
    let app: AppItem
    
    var config: (text: String, icon: String, color: Color) {
        if app.status == "已链接" {
            return ("已链接", "link", .green)
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
            
            Text(LocalizedStringKey(config.text))
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
        .accessibilityLabel(LocalizedStringKey(config.text))
        .accessibilityAddTraits(.isStaticText)
    }
}
