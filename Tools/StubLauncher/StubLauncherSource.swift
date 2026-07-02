import Cocoa

/// AppPorts Stub Portal Native Launcher
///
/// Replaces the bash launcher script in macOS Stub Portals.
/// Receives `kAEOpenDocuments` Apple Events and forwards them
/// to the real app on external storage.
///
/// Companion file at Contents/Resources/real_app_path.txt contains
/// the path to the real .app bundle.

/// Localization for the "external storage missing" system dialog.
///
/// This launcher runs as its own process, separate from the AppPorts app,
/// so it cannot use the app's `.localized` helper. Instead it picks the
/// message in the Mac's system language and falls back to English.
///
/// The translations mirror the `外部存储未连接，请连接后重试。` and `好`
/// entries in `Localizable.xcstrings` — keep both in sync.
enum DiskMissingStrings {
    /// (message, OK button title) keyed by xcstrings language code.
    static let table: [String: (message: String, button: String)] = [
        "en":          ("External storage is not connected. Connect it and try again.", "OK"),
        "ar":          ("وحدة التخزين الخارجية غير متصلة. صِلها ثم حاول مرة أخرى.", "موافق"),
        "de":          ("Externer Speicher ist nicht verbunden. Verbinden Sie ihn und versuchen Sie es erneut.", "OK"),
        "eo":          ("Ekstera konservejo ne estas konektita. Konektu ĝin kaj reprovu.", "Bone"),
        "es":          ("El almacenamiento externo no está conectado. Conéctalo e inténtalo de nuevo.", "Aceptar"),
        "fr":          ("Le stockage externe n'est pas connecté. Connectez-le, puis réessayez.", "OK"),
        "hi":          ("बाहरी स्टोरेज कनेक्ट नहीं है। उसे कनेक्ट करके फिर कोशिश करें।", "ठीक है"),
        "id":          ("Penyimpanan eksternal belum tersambung. Sambungkan lalu coba lagi.", "Oke"),
        "it":          ("L'archiviazione esterna non è collegata. Collegala e riprova.", "OK"),
        "ja":          ("外部ストレージが接続されていません。接続してからもう一度お試しください。", "OK"),
        "ko":          ("외부 저장소가 연결되어 있지 않습니다. 연결한 뒤 다시 시도하세요.", "확인"),
        "nl":          ("Externe opslag is niet aangesloten. Sluit deze aan en probeer het opnieuw.", "OK"),
        "pl":          ("Pamięć zewnętrzna nie jest podłączona. Podłącz ją i spróbuj ponownie.", "OK"),
        "pt":          ("O armazenamento externo não está conectado. Conecte-o e tente novamente.", "OK"),
        "ru":          ("Внешний накопитель не подключен. Подключите его и повторите попытку.", "ОК"),
        "th":          ("ยังไม่ได้เชื่อมต่อที่จัดเก็บข้อมูลภายนอก โปรดเชื่อมต่อแล้วลองอีกครั้ง", "ตกลง"),
        "tr":          ("Harici depolama bağlı değil. Bağlayıp yeniden deneyin.", "Tamam"),
        "vi":          ("Bộ nhớ ngoài chưa được kết nối. Hãy kết nối rồi thử lại.", "OK"),
        "zh-Hans":     ("外部存储未连接，请连接后重试。", "好"),
        "zh-Hant":     ("外部儲存裝置未連接，請連接後再試。", "好"),
    ]

    /// Picks the best entry for the user's preferred languages, defaulting to English.
    static var current: (message: String, button: String) {
        for preferred in Locale.preferredLanguages {
            // Try progressively shorter prefixes, e.g.
            // "zh-Hant-TW" → "zh-Hant" → "zh", "en-US" → "en".
            let components = preferred.split(separator: "-").map(String.init)
            var count = components.count
            while count > 0 {
                let candidate = components[0..<count].joined(separator: "-")
                if let entry = table[candidate] { return entry }
                count -= 1
            }
            // Generic Chinese with no script subtag → Simplified.
            if components.first == "zh" { return table["zh-Hans"] ?? ("外部存储未连接，请连接后重试。", "好") }
        }
        return table["en"] ?? ("External storage is not connected. Connect it and try again.", "OK")
    }
}

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

    /// Wraps a string as an AppleScript double-quoted literal, escaping `\` and `"`.
    private func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func showExternalDiskMissing() {
        let strings = DiskMissingStrings.current
        let script = "display dialog \(appleScriptLiteral(strings.message)) "
            + "buttons {\(appleScriptLiteral(strings.button))} default button 1 with icon caution"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
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
