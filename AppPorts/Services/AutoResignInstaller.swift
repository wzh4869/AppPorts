//
//  AutoResignInstaller.swift
//  AppPorts
//

import Foundation

/// 管理“开机自动重签名” LaunchAgent 的安装与卸载
///
/// 安装后在 ~/Library/LaunchAgents/ 创建一个 plist，
/// 用户每次登录时自动对签名已失效的已迁移应用执行 ad-hoc 重签名。
enum AutoResignInstaller {

    private static let label = "com.shimoko.AppPorts.re-sign"
    private static let scriptName = "AppPorts-ReSign.sh"

    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AppPorts")
    }

    private static var scriptURL: URL {
        appSupportDir.appendingPathComponent(scriptName)
    }

    // MARK: - Install

    static func install() throws {
        let fm = FileManager.default
        let appSupportDirURL = appSupportDir

        // 1. 确保 Application Support 目录存在
        if !fm.fileExists(atPath: appSupportDirURL.path) {
            try fm.createDirectory(at: appSupportDirURL, withIntermediateDirectories: true)
        }

        // 2. 复制脚本
        guard let bundledScript = Bundle.main.url(forResource: scriptName, withExtension: nil) else {
            throw InstallError.scriptNotFound
        }
        if fm.fileExists(atPath: scriptURL.path) {
            try fm.removeItem(at: scriptURL)
        }
        try fm.copyItem(at: bundledScript, to: scriptURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // 3. 创建 LaunchAgent plist
        let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/bin/bash</string>
                    <string>\(scriptURL.path)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>EnvironmentVariables</key>
                <dict>
                    <key>PATH</key>
                    <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
                </dict>
            </dict>
            </plist>
            """

        try plistContent.write(to: agentPlistURL, atomically: true, encoding: .utf8)

        // 4. 加载 LaunchAgent
        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["bootstrap", "gui/\(getuid())", agentPlistURL.path]
        try load.run()
        load.waitUntilExit()

        if load.terminationStatus != 0 {
            // 降级：尝试旧版 load
            let legacy = Process()
            legacy.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            legacy.arguments = ["load", agentPlistURL.path]
            try legacy.run()
            legacy.waitUntilExit()

            if legacy.terminationStatus != 0 {
                throw InstallError.launchAgentLoadFailed
            }
        }

        AppLogger.shared.log("开机自动重签名已安装")
    }

    // MARK: - Uninstall

    static func uninstall() {
        let fm = FileManager.default

        // 1. 卸载 LaunchAgent
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["bootout", "gui/\(getuid())", agentPlistURL.path]
        try? unload.run()
        unload.waitUntilExit()

        // 降级
        let legacy = Process()
        legacy.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        legacy.arguments = ["unload", agentPlistURL.path]
        try? legacy.run()
        legacy.waitUntilExit()

        // 2. 删除文件
        try? fm.removeItem(at: agentPlistURL)
        try? fm.removeItem(at: scriptURL)

        AppLogger.shared.log("开机自动重签名已卸载")
    }

    // MARK: - Status

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    enum InstallError: LocalizedError {
        case scriptNotFound
        case launchAgentLoadFailed

        var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                return "找不到重签名脚本，安装失败".localized
            case .launchAgentLoadFailed:
                return "LaunchAgent 加载失败".localized
            }
        }
    }
}
