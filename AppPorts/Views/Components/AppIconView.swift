//
//  AppIconView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI
import AppKit

/// 应用图标异步加载视图
struct AppIconView: View {
    let url: URL
    var size: CGFloat = 40

    @State private var icon: NSImage? = nil

    var body: some View {
        Group {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .appPortalPresentationDidChange)
            .receive(on: DispatchQueue.main)) { notification in
            guard let changedURL = notification.object as? URL,
                  changedURL.standardizedFileURL.path == url.standardizedFileURL.path else { return }
            icon = Self.loadIcon(from: url)
        }
        .task(id: url) {
            let loaded = Self.loadIcon(from: url)
            icon = loaded
            if loaded == nil {
                AppLogger.shared.logContext(
                    "AppIconView 图标加载失败",
                    details: [
                        ("url", url.path),
                        ("exists", FileManager.default.fileExists(atPath: url.path) ? "YES" : "NO"),
                        ("resolved", url.resolvingSymlinksInPath().path)
                    ],
                    level: "WARN"
                )
            }
        }
    }

    private static func loadIcon(from appURL: URL) -> NSImage? {
        let fm = FileManager.default
        let path = appURL.path

        // 方式 1: NSWorkspace
        if fm.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            // 检查是否为 iOS app（有 Wrapper/WrappedBundle），尝试提取真实图标
            if let iosIcon = loadIOSAppIcon(from: appURL) {
                return iosIcon
            }
            return icon
        }

        // 方式 2: 解析符号链接后重试
        let resolved = appURL.resolvingSymlinksInPath()
        if resolved.path != path, fm.fileExists(atPath: resolved.path) {
            return NSWorkspace.shared.icon(forFile: resolved.path)
        }

        // 方式 3: 从 bundle .icns 直接读取
        for tryPath in [path, resolved.path] {
            guard fm.fileExists(atPath: tryPath) else { continue }
            guard let plist = NSDictionary(contentsOfFile: tryPath + "/Contents/Info.plist"),
                  let iconFile = plist["CFBundleIconFile"] as? String else { continue }
            let icnsName = iconFile.hasSuffix(".icns") ? iconFile : iconFile + ".icns"
            let icnsPath = tryPath + "/Contents/Resources/" + icnsName
            if let data = try? Data(contentsOf: URL(fileURLWithPath: icnsPath)),
               let img = NSImage(data: data) {
                return img
            }
        }

        // 最终回退
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// 从 iOS app 的 Wrapper/ 目录提取 AppIcon PNG
    private static func loadIOSAppIcon(from appURL: URL) -> NSImage? {
        let fm = FileManager.default
        let wrapperDir: URL
        if fm.fileExists(atPath: appURL.appendingPathComponent("Wrapper").path) {
            wrapperDir = appURL.appendingPathComponent("Wrapper")
        } else if fm.fileExists(atPath: appURL.appendingPathComponent("WrappedBundle").path) {
            wrapperDir = appURL.appendingPathComponent("WrappedBundle")
        } else {
            return nil
        }

        // 查找内部 .app
        guard let innerApps = try? fm.contentsOfDirectory(at: wrapperDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
              let innerApp = innerApps.first(where: { $0.pathExtension == "app" }) else {
            return nil
        }

        // 查找最大的 AppIcon PNG
        guard let iconFiles = try? fm.contentsOfDirectory(at: innerApp, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
              let largestIcon = iconFiles
                .filter({ $0.lastPathComponent.hasPrefix("AppIcon") && $0.pathExtension == "png" })
                .max(by: { a, b in
                    (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 <
                    (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
                }) else {
            return nil
        }

        return NSImage(contentsOf: largestIcon)
    }
}
