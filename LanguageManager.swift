//
//  LanguageManager.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/19.
//

import SwiftUI
import Combine

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    

    @Published var language: String {
        didSet {

            UserDefaults.standard.set(language, forKey: "selectedLanguage")
        }
    }
    

    init() {
        self.language = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "system"
    }
    

    var locale: Locale {
        if language == "system" {
            return Locale.current
        } else {
            return Locale(identifier: language)
        }
    }
}


extension String {
    var localized: String {
        let selectedLang = LanguageManager.shared.language
        if selectedLang == "system" {
            return NSLocalizedString(self, comment: "")
        } else {
            guard let path = Bundle.main.path(forResource: selectedLang, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return NSLocalizedString(self, comment: "")
            }
            return NSLocalizedString(self, tableName: nil, bundle: bundle, value: "", comment: "")
        }
    }
}
