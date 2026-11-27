//
//  LocalizedByteCountFormatter.swift
//  AppPorts
//
//  Created by Codex on 2026/3/12.
//

import Foundation

enum LocalizedByteCountFormatter {
    static func string(
        fromByteCount bytes: Int64,
        allowedUnits: ByteCountFormatStyle.Units = .all
    ) -> String {
        let style = ByteCountFormatStyle(
            style: .file,
            allowedUnits: allowedUnits,
            spellsOutZero: false,
            includesActualByteCount: false
        )

        return bytes.formatted(style.locale(LanguageManager.shared.formattingLocale))
    }
}
