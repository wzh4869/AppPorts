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
                Button("跟随系统 (System)") {
                    languageManager.language = "system"
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                
                Divider()
                
                Button("English") {
                    languageManager.language = "en"
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                
                Button("简体中文") {
                    languageManager.language = "zh-Hans"
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
            }
        }
    }
}
