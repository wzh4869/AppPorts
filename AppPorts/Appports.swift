//
//  AppPorts.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/19.
//

import SwiftUI
import Combine

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
/// App 生命周期代理
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var aboutWindowController = AboutWindowController.shared
    fileprivate static weak var mainWindow: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let window = Self.mainWindow else { return true }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppUpdateController.shared.allowsTermination { return .terminateNow }
        if AppOperationState.shared.isBusy {
            let alert = NSAlert()
            alert.messageText = "还有任务尚未结束".localized
            alert.informativeText = "请先等待任务完成，或在任务列表中取消任务并等待安全收尾，再退出 AppPorts。暂停和等待中的任务也需要先结束。".localized
            alert.addButton(withTitle: "查看任务".localized)
            alert.addButton(withTitle: "返回".localized)
            sender.activate(ignoringOtherApps: true)
            Self.mainWindow?.makeKeyAndOrderFront(nil)
            if alert.runModal() == .alertFirstButtonReturn {
                MigrationTaskCenter.shared.detailID = nil
                MigrationTaskCenter.shared.showsList = true
            }
            return .terminateCancel
        }
        if AppUpdateController.shared.finishBeforeTerminating({
            sender.reply(toApplicationShouldTerminate: !AppOperationState.shared.isBusy)
        }) { return .terminateLater }
        return AppOperationState.shared.finishBeforeTerminating {
            sender.reply(toApplicationShouldTerminate: true)
        } ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MigrationTaskCenter.shared.saveHistoryForExit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdateInstaller.acknowledgeLaunch()
        // 应用可能被移动过：校准登录代理指向的程序，免得它指向一个已经不存在的路径。
        Task.detached(priority: .utility) {
            do { try await AutoResignInstaller.refreshInstalledScriptIfNeeded() }
            catch {
                AppLogger.shared.logError(
                    "更新开机重签设置失败",
                    error: error,
                    errorCode: "AUTO-RESIGN-POLICY-FAILED"
                )
            }
            await ContainerMountAgentInstaller.refreshAtLaunch()
        }
    }
}

struct AppMoverApp: App {
    /// 全局语言管理器
    @StateObject private var languageManager = LanguageManager.shared

    /// 控制欢迎界面显示。走完一次后不再自动出现，需要重看请到「设置 › 准备情况」。
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: WelcomeView.completionDefaultsKey)
    @ObservedObject private var operationState = AppOperationState.shared
    @StateObject private var logMenuState = LogMenuState()
    @AppStorage("LogEnabled") private var loggingEnabled = true
    @AppStorage("MaxLogSizeBytes") private var maximumLogSize = 2 * 1024 * 1024

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        do { try WriterAdmission.registerCurrentWriter() }
        catch {
            AppLogger.shared.logError("当前 AppPorts 未取得写入资格", error: error,
                errorCode: "WRITER-ADMISSION-FAILED")
        }
        // 以后台挂载代理身份启动时不创建任何窗口，重挂载完成后直接退出。
        if ContainerMountAgentInstaller.isRunningAsAgent {
            ContainerMountAgentInstaller.runAgentAndExit()
        }
        // 应用启动时记录系统诊断信息
        AppLogger.shared.logLaunchSession()
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
            .background(MainWindowAppearance())
            

        }
        .commands {
            // 原有的关于菜单
            CommandGroup(replacing: .appInfo) {
                Button("关于 AppPorts...".localized) {
                    appDelegate.aboutWindowController.present()
                }
            }
            
            CommandMenu("语言".localized) {
                Group {
                Button(AppLanguageCatalog.systemOptionTitle) { languageManager.language = "system" }
                .keyboardShortcut("0", modifiers: [.command, .option])
                
                Divider()
                
                ForEach(AppLanguageCatalog.primaryLanguages) { option in
                    if let shortcut = option.keyboardShortcut {
                        Button(option.menuTitle) { languageManager.language = option.code }
                            .keyboardShortcut(shortcut, modifiers: [.command, .option])
                    } else {
                        Button(option.menuTitle) { languageManager.language = option.code }
                    }
                }

                Divider()
                Text(AppLanguageCatalog.aiSectionTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(AppLanguageCatalog.aiTranslatedLanguages) { option in
                    Button(option.menuTitle) { languageManager.language = option.code }
                }
                }
                .disabled(operationState.isBusy)
            }
            
            // 日志管理菜单
            CommandMenu("日志".localized) {
                Button("在 Finder 中查看日志".localized) {
                    AppLogger.shared.openLogInFinder()
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])

                Button("导出诊断包（菜单）".localized) {
                    AppLogger.shared.exportDiagnosticPackageInteractively()
                }
                
                Button("设置日志位置...".localized) {
                    let panel = NSOpenPanel()
                    panel.prompt = "选择日志保存位置".localized
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        let logFile = url.appendingPathComponent("AppPorts_Log.txt")
                        AppLogger.shared.setLogPath(logFile)
                        logMenuState.refresh()
                    }
                }
                
                Divider()
                
                // 日志开关
                Toggle("启用日志记录".localized, isOn: Binding(
                    get: { loggingEnabled },
                    set: { AppLogger.shared.isLoggingEnabled = $0 }
                ))
                
                // 日志大小设置
                Picker("最大日志大小".localized, selection: Binding(
                    get: { maximumLogSize },
                    set: { AppLogger.shared.maxLogSize = Int64($0) }
                )) {
                    ForEach([1, 2, 5, 10, 50, 100], id: \.self) { megabytes in
                        Text(verbatim: "\(megabytes) MB").tag(megabytes * 1024 * 1024)
                    }
                }
                
                Divider()
                
                Text(String(format: "当前大小: %@".localized, logMenuState.size))
                    .font(.caption)
                
                Button("清空日志".localized) {
                    AppLogger.shared.clearLog()
                    logMenuState.refresh()
                }
            }
            
            // 赞助菜单
            CommandMenu("赞助".localized) {
                Button("赞助 AppPorts".localized) {
                    if let url = URL(string: "https://docs-appports.shimoko.com/sponsor.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            // 帮助菜单 — 添加文档入口
            CommandGroup(after: .help) {
                Button("用户文档".localized) {
                    if let url = URL(string: "https://docs-appports.shimoko.com/") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

private struct MainWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarSeparatorStyle = .none
            AppDelegate.mainWindow = window
            // Preserve the hosting view and its in-memory state when clicking ×.
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.target = self
                closeButton.action = #selector(hideMainWindow)
            }
        }

        @objc private func hideMainWindow() {
            window?.orderOut(nil)
        }
    }
}

/// Commands 的标签不会安装普通视图生命周期，在应用层持有菜单观察者。
@MainActor
private final class LogMenuState: ObservableObject {
    @Published private(set) var size = AppLogger.shared.getLogSizeString()
    private var menuObserver: AnyCancellable?

    init() {
        menuObserver = NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        size = AppLogger.shared.getLogSizeString()
    }
}
