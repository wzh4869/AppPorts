import Cocoa

/// AppPorts Stub Portal Native Launcher
///
/// Replaces the bash launcher script in macOS Stub Portals.
/// Receives `kAEOpenDocuments` Apple Events and forwards them
/// to the real app on external storage.
///
/// Companion file at Contents/Resources/real_app_path.txt contains
/// the path to the real .app bundle.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var realAppPath: String?

    func readRealAppPath() -> String {
        guard let resURL = Bundle.main.resourceURL else {
            return ""
        }
        let pathFile = resURL.appendingPathComponent("real_app_path.txt")
        if let str = try? String(contentsOf: pathFile, encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        realAppPath = readRealAppPath()
        guard let path = realAppPath, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            showExternalDiskMissing()
            NSApp.terminate(nil)
            return
        }
        launchApp(at: path)
        NSApp.terminate(nil)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        realAppPath = readRealAppPath()
        guard let realPath = realAppPath, !realPath.isEmpty,
              FileManager.default.fileExists(atPath: realPath) else {
            showExternalDiskMissing()
            NSApp.reply(toOpenOrPrint: .failure)
            NSApp.terminate(nil)
            return
        }
        for file in filenames {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", realPath, file]
            try? proc.run()
        }
        NSApp.reply(toOpenOrPrint: .success)
        NSApp.terminate(nil)
    }

    private func launchApp(at path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [path]
        try? proc.run()
    }

    private func showExternalDiskMissing() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = [
            "-e",
            "display dialog \"外部存储未连接，请连接后重试。\" buttons {\"好\"} default button 1 with icon caution"
        ]
        try? proc.run()
        proc.waitUntilExit()
    }
}

// Manual NSApplication setup — no MainMenu.xib
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
