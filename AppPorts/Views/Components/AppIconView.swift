//
//  AppIconView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI
import AppKit

// MARK: - 应用图标视图

/// 应用图标异步加载视图
///
/// 使用 Swift 并发模型异步加载应用图标，避免阻塞主线程。
/// 提供流畅的列表滚动体验，即使加载大量应用图标。
///
/// ## 性能优化
/// - ✅ 异步加载：使用 `Task.detached` 在后台线程加载图标
/// - ✅ 延迟加载：只在视图出现时才开始加载（`.task` 修饰符）
/// - ✅ 缓存友好：NSWorkspace 内部缓存图标，重复访问速度快
///
/// ## 使用示例
/// ```swift
/// List(apps) { app in
///     HStack {
///         AppIconView(url: app.path)  // 自动异步加载图标
///         Text(app.name)
///     }
/// }
/// ```
///
/// - Note: 图标大小固定为 40x40 点，使用阴影增强视觉效果
struct AppIconView: View {
    /// 应用包的 URL
    let url: URL
    
    /// 加载的图标（初始为 nil，异步加载后更新）
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
