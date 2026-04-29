//
//  AppLanguageOption.swift
//  AppPorts
//
//  Created by Codex on 2026/3/12.
//

import SwiftUI

/// 应用内支持的语言选项。
///
/// 语言名称使用各自语言的自称（autonym），这是刻意设计：
/// - 用户切换语言时更容易识别目标语言
/// - 避免在多个界面重复硬编码同一组语言文案
/// - 让本地化审计只关注真正需要翻译的 UI 文案
struct AppLanguageOption: Identifiable, Hashable {
    let code: String
    let nativeName: String
    let flag: String
    let isAITranslated: Bool
    let keyboardShortcut: KeyEquivalent?

    var id: String { code }

    var menuTitle: String {
        let baseTitle = "\(flag) \(nativeName)"
        return isAITranslated ? "\(baseTitle) (AI)" : baseTitle
    }

    var selectionTitle: String {
        isAITranslated ? "\(nativeName) (AI)" : nativeName
    }
}

enum AppLanguageCatalog {
    static let primaryLanguages: [AppLanguageOption] = [
        AppLanguageOption(code: "en", nativeName: "English", flag: "🇺🇸", isAITranslated: false, keyboardShortcut: "1"),
        AppLanguageOption(code: "zh-Hans", nativeName: "简体中文", flag: "🇨🇳", isAITranslated: false, keyboardShortcut: "2"),
        AppLanguageOption(code: "zh-Hant", nativeName: "繁體中文", flag: "🇭🇰", isAITranslated: false, keyboardShortcut: "3"),
    ]

    static let aiTranslatedLanguages: [AppLanguageOption] = [
        AppLanguageOption(code: "es", nativeName: "Español", flag: "🇪🇸", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "fr", nativeName: "Français", flag: "🇫🇷", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "pt", nativeName: "Português", flag: "🇵🇹", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "it", nativeName: "Italiano", flag: "🇮🇹", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "de", nativeName: "Deutsch", flag: "🇩🇪", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "ja", nativeName: "日本語", flag: "🇯🇵", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "ko", nativeName: "한국어", flag: "🇰🇷", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "ru", nativeName: "Русский", flag: "🇷🇺", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "ar", nativeName: "العربية", flag: "🇸🇦", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "hi", nativeName: "हिन्दी", flag: "🇮🇳", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "vi", nativeName: "Tiếng Việt", flag: "🇻🇳", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "th", nativeName: "ไทย", flag: "🇹🇭", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "tr", nativeName: "Türkçe", flag: "🇹🇷", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "nl", nativeName: "Nederlands", flag: "🇳🇱", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "pl", nativeName: "Polski", flag: "🇵🇱", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "id", nativeName: "Indonesia", flag: "🇮🇩", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "eo", nativeName: "Esperanto", flag: "🏁", isAITranslated: true, keyboardShortcut: nil),
        AppLanguageOption(code: "br", nativeName: "Braille", flag: "⠃⠗", isAITranslated: false, keyboardShortcut: nil),
        AppLanguageOption(code: "zh-martian", nativeName: "煋仌呅", flag: "👽", isAITranslated: false, keyboardShortcut: nil),
    ]

    static let selectableLanguages = primaryLanguages + aiTranslatedLanguages

    static var systemOptionTitle: String {
        "跟随系统 (System)".localized
    }

    static var aiSectionTitle: String {
        "AI Translated".localized
    }

    static var automaticSelectionTitle: String {
        "Auto".localized
    }

    static func option(for code: String) -> AppLanguageOption? {
        selectableLanguages.first { $0.code == code }
    }
}
