//
//  AppPorts.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/19.
//

import SwiftUI

// MARK: - 应用入口

/// AppPorts 应用的主入口点
///
/// 负责应用的初始化和主窗口配置。主要功能：
/// - 🚀 应用启动时记录系统诊断信息
/// - 🌐 全局语言管理（20+ 语言支持）
/// - 📝 自定义菜单栏（关于、语言、日志）
/// - 👋 首次启动欢迎界面
///
/// ## 应用流程
/// 1. 启动 -> 记录系统信息
/// 2. 显示欢迎界面（首次启动）
/// 3. 用户确认权限 -> 进入主界面
///
/// - Note: 使用 `@main` 标记为 SwiftUI 应用的入口点
@main
struct AppMoverApp: App {
    /// 全局语言管理器
    @StateObject private var languageManager = LanguageManager.shared
    
    /// 控制欢迎界面显示（首次启动为 true）
    @State private var showWelcome = true
    @State private var showAboutSheet = false
    
    init() {
        // 应用启动时记录系统诊断信息
        AppLogger.shared.log("========== AppPorts 启动 ==========")
        AppLogger.shared.logSystemInfo()
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if showWelcome {
                    WelcomeView(showWelcomeScreen: $showWelcome)
                } else {
                    ContentView()
                }
            }

            .environment(\.locale, languageManager.locale)

            .id(languageManager.language)
            
            // 关于页面弹窗
            .sheet(isPresented: $showAboutSheet) {
                AboutView()
                    // 确保弹出的 Sheet 也能收到语言更新
                    .environment(\.locale, languageManager.locale)
                    .id(languageManager.language)
            }
        }
        .commands {
            // 原有的关于菜单
            CommandGroup(replacing: .appInfo) {
                Button("关于 AppPorts...".localized) {
                    showAboutSheet = true
                }
            }
            
            CommandMenu("语言".localized) {
                Button("跟随系统 (System)".localized) { languageManager.language = "system" }
                .keyboardShortcut("0", modifiers: [.command, .option])
                
                Divider()
                
                Group {
                    Button("🇺🇸 English") { languageManager.language = "en" }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                    Button("🇨🇳 简体中文") { languageManager.language = "zh-Hans" }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    Button("🇭🇰 繁體中文") { languageManager.language = "zh-Hant" }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                }

                Divider()
                Text("AI Translated").font(.caption).foregroundColor(.secondary)
                
                Group {
                    Button("🇪🇸 Español (AI)") { languageManager.language = "es" }
                    Button("🇫🇷 Français (AI)") { languageManager.language = "fr" }
                    Button("🇵🇹 Português (AI)") { languageManager.language = "pt" }
                    Button("🇮🇹 Italiano (AI)") { languageManager.language = "it" }
                    Button("🇩🇪 Deutsch (AI)") { languageManager.language = "de" }
                    Button("🇯🇵 日本語 (AI)") { languageManager.language = "ja" }
                    Button("🇰🇷 한국어 (AI)") { languageManager.language = "ko" }
                    Button("🇷🇺 Русский (AI)") { languageManager.language = "ru" }
                }
                Group {
                    Button("🇸🇦 العربية (AI)") { languageManager.language = "ar" }
                    Button("🇮🇳 हिन्दी (AI)") { languageManager.language = "hi" }
                    Button("🇻🇳 Tiếng Việt (AI)") { languageManager.language = "vi" }
                    Button("🇹🇭 ไทย (AI)") { languageManager.language = "th" }
                    Button("🇹🇷 Türkçe (AI)") { languageManager.language = "tr" }
                    Button("🇳🇱 Nederlands (AI)") { languageManager.language = "nl" }
                    Button("🇵🇱 Polski (AI)") { languageManager.language = "pl" }
                    Button("🇮🇩 Indonesia (AI)") { languageManager.language = "id" }
                    Button("🏁 Esperanto (AI)") { languageManager.language = "eo" }
                    Button("⠃⠗ Braille") { languageManager.language = "br" }
                }
            }
            
            // 日志管理菜单
            CommandMenu("日志".localized) {
                Button("在 Finder 中查看日志".localized) {
                    AppLogger.shared.openLogInFinder()
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
                
                Button("设置日志位置...".localized) {
                    let panel = NSOpenPanel()
                    panel.prompt = "选择日志保存位置".localized
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        let logFile = url.appendingPathComponent("AppPorts_Log.txt")
                        AppLogger.shared.setLogPath(logFile)
                    }
                }
                
                Divider()
                
                // 日志开关
                Button(AppLogger.shared.isLoggingEnabled ? "✅ 启用日志记录" : "启用日志记录") {
                    AppLogger.shared.isLoggingEnabled.toggle()
                }
                
                // 日志大小设置
                Menu("最大日志大小") {
                    let currentSize = AppLogger.shared.maxLogSize
                    
                    Button(currentSize == 1 * 1024 * 1024 ? "✅ 1 MB" : "1 MB") {
                        AppLogger.shared.maxLogSize = 1 * 1024 * 1024
                    }
                    Button(currentSize == 5 * 1024 * 1024 ? "✅ 5 MB" : "5 MB") {
                        AppLogger.shared.maxLogSize = 5 * 1024 * 1024
                    }
                    Button(currentSize == 10 * 1024 * 1024 ? "✅ 10 MB" : "10 MB") {
                        AppLogger.shared.maxLogSize = 10 * 1024 * 1024
                    }
                    Button(currentSize == 50 * 1024 * 1024 ? "✅ 50 MB" : "50 MB") {
                        AppLogger.shared.maxLogSize = 50 * 1024 * 1024
                    }
                    Button(currentSize == 100 * 1024 * 1024 ? "✅ 100 MB" : "100 MB") {
                        AppLogger.shared.maxLogSize = 100 * 1024 * 1024
                    }
                }
                
                Divider()
                
                Text("当前大小: \(AppLogger.shared.getLogSizeString())")
                    .font(.caption)
                
                Button("清空日志".localized) {
                    AppLogger.shared.clearLog()
                }
            }
        }
    }
}
