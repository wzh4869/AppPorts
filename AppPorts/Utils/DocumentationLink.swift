//
//  DocumentationLink.swift
//  AppPorts
//

import Foundation

/// 文档站链接：按当前界面语言打开对应语言的页面。
///
/// 文档站只发布简体中文（根目录）、繁体中文（`zh-Hant/`）和英语（`en/`）三种语言。
/// 其余界面语言一律打开英文站——不存在的语言目录会返回 404，不能靠拼前缀碰运气。
/// 锚点使用文档里显式声明的 `{#id}`，三种语言的页面保持一致。
enum DocumentationLink {
    static let baseURL = URL(string: "https://docs-appports.shimoko.com/")!

    /// 语言代码 → 文档站目录前缀。只包含实际发布的语言。
    private static let sitePrefixes: [String: String] = [
        "zh-Hans": "",
        "zh-Hant": "zh-Hant/",
        "en": "en/"
    ]

    /// - Parameters:
    ///   - page: 不带扩展名的页面路径，如 `why-apfs`、`datamigrae/mount-migration`
    ///   - anchor: 页面内的显式锚点
    ///   - language: 界面语言代码；默认取当前设置
    static func url(page: String, anchor: String? = nil, language: String = currentLanguage) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/" + sitePrefix(for: language) + page + ".html"
        components.fragment = anchor
        return components.url ?? baseURL
    }

    /// 当前界面语言；跟随系统时取应用实际使用的本地化。
    static var currentLanguage: String {
        let selected = LanguageManager.shared.language
        guard selected == "system" else { return selected }
        return Bundle.main.preferredLocalizations.first ?? "en"
    }

    static func sitePrefix(for language: String) -> String {
        if let prefix = sitePrefixes[language] { return prefix }
        let lowered = language.lowercased()
        if lowered.hasPrefix("zh-hant") || lowered.hasPrefix("zh-tw") || lowered.hasPrefix("zh-hk") || lowered.hasPrefix("zh-mo") {
            return "zh-Hant/"
        }
        // 简体中文及其变体（包括火星文）都用中文站。
        if lowered.hasPrefix("zh") { return "" }
        let base = String(lowered.prefix { $0 != "-" && $0 != "_" })
        return sitePrefixes[base] ?? "en/"
    }
}
