//
//  AppPorts.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/19.
//

import SwiftUI

@main
struct AppMoverApp: App {
    
    // 引入语言管理器
    @StateObject private var languageManager = LanguageManager.shared
    
    @State private var showWelcome = true
    @State private var showAboutSheet = false
    
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
                Button("关于 AppPorts...") {
                    showAboutSheet = true
                }
            }
            
            CommandMenu("Language") {
                Button("跟随系统 (System)") { languageManager.language = "system" }
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
        }
    }
}
