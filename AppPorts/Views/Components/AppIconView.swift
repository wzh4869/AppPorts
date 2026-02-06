//
//  AppIconView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI
import AppKit

/// 应用图标视图 - 异步加载优化
struct AppIconView: View {
    let url: URL
    @State private var icon: NSImage? = nil
    
    var body: some View {
        Group {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Placeholder while loading
                Color.clear
            }
        }
        .frame(width: 40, height: 40)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        .accessibilityHidden(true)
        .task {
            // Async icon loading
            if icon == nil {
                let loadedIcon = await Task.detached(priority: .userInitiated) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }.value
                await MainActor.run { self.icon = loadedIcon }
            }
        }
    }
}
