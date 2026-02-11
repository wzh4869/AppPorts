//
//  LanguageManager.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/19.
//

import SwiftUI
import Combine

// MARK: - 语言管理器

/// 全局语言切换管理器
///
/// 管理应用的多语言设置，支持系统语言跟随和手动语言选择。
/// 使用 `@Published` 属性自动触发 UI 更新。
///
/// ## 使用示例
/// ```swift
/// // 在 App 中注入
/// @StateObject private var languageManager = LanguageManager.shared
/// 
/// // 切换语言
/// LanguageManager.shared.language = "zh-Hans"
/// 
/// // 字符串本地化
/// "Hello".localized // 返回当前语言的翻译
/// ```
///
/// - Note: 语言设置自动保存到 UserDefaults，应用重启后保持
class LanguageManager: ObservableObject {
    /// 单例实例
    static let shared = LanguageManager()
    
    /// 当前选择的语言代码
    ///
    /// 可能的值：
    /// - "system": 跟随系统语言
    /// - "en": 英语
    /// - "zh-Hans": 简体中文
    /// - "zh-Hant": 繁体中文
    /// - ...以及其他支持的语言代码
    ///
    /// - Note: 变更时自动保存到 UserDefaults 并触发 UI 更新
    @Published var language: String {
        didSet {
            // 保存到用户偏好设置
            UserDefaults.standard.set(language, forKey: "selectedLanguage")
        }
    }
    
    // MARK: - 初始化
    
    /// 私有初始化（单例模式）
    ///
    /// 从 UserDefaults 加载上次保存的语言设置，默认为 "system"
    private init() {
        self.language = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "system"
    }
    
    // MARK: - 计算属性
    
    /// 当前语言的 Locale 对象
    ///
    /// 用于 SwiftUI 的 `.environment(\.locale, ...)` 修饰符
    ///
    /// - Returns: 
    ///   - 如果设置为 "system"，返回 `Locale.current`
    ///   - 否则返回对应语言代码的 Locale
    var locale: Locale {
        if language == "system" {
            return Locale.current
        } else {
            return Locale(identifier: language)
        }
    }
}

// MARK: - String 扩展

/// String 的本地化扩展
extension String {
    /// 获取字符串的本地化版本
    ///
    /// 根据 LanguageManager 的当前语言设置返回对应的翻译文本。
    ///
    /// ## 工作原理
    /// 1. 如果设置为 "system"：使用系统默认的本地化
    /// 2. 如果设置为特定语言：从对应的 .lproj 文件中加载翻译
    ///
    /// - Returns: 本地化后的字符串，如果找不到翻译则返回原字符串
    ///
    /// - Example:
    ///   ```swift
    ///   "Welcome".localized  // 返回 "欢迎"（如果当前语言是中文）
    ///   ```
    var localized: String {
        let selectedLang = LanguageManager.shared.language
        if selectedLang == "system" {
            // 使用系统默认本地化
            return NSLocalizedString(self, comment: "")
        } else {
            // 从指定语言的 .lproj 文件中加载
            guard let path = Bundle.main.path(forResource: selectedLang, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                // 如果找不到对应语言包，使用默认本地化
                return NSLocalizedString(self, comment: "")
            }
            return NSLocalizedString(self, tableName: nil, bundle: bundle, value: "", comment: "")
        }
    }
}
