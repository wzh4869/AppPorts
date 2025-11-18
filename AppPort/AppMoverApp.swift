import SwiftUI

@main
struct AppMoverApp: App {
    
    @State private var showWelcome = true
    @State private var showAboutSheet = false
    
    var body: some Scene {
        WindowGroup {
            // 【已修复】
            // 我们需要把 .sheet (弹窗) 附加到我们的 View (视图)上，
            // 而不是附加到 WindowGroup (窗口)上。
            Group {
                if showWelcome {
                    WelcomeView(showWelcomeScreen: $showWelcome)
                } else {
                    ContentView()
                }
            }
            // 把 .sheet 移到这里
            .sheet(isPresented: $showAboutSheet) {
                AboutView()
            }
        }
        // .commands (菜单栏) 放在这里是正确的
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 AppMover...") {
                    showAboutSheet = true
                }
            }
        }
    }
}
