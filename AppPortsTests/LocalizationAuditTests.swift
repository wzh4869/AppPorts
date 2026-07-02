import XCTest
@testable import AppPorts

final class LocalizationAuditTests: XCTestCase {
    private let intentionallyNonLocalizedFiles = Set([
        "Models/AppLanguageOption.swift",
    ])

    private struct LocalizedStringUsage {
        let relativePath: String
        let line: Int
        let key: String
    }

    override func tearDown() {
        super.tearDown()
        LanguageManager.shared.language = "system"
    }

    func testSupportedLanguageCodesAreUnique() {
        let codes = AppLanguageCatalog.selectableLanguages.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count, "语言注册表存在重复语言代码")
    }

    func testStringCatalogContainsTranslationsForAllSupportedLanguages() throws {
        let supportedLocales = Set(AppLanguageCatalog.selectableLanguages.map(\.code))
        let catalogURL = try repositoryRootURL()
            .appendingPathComponent("AppPorts")
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(rawObject["strings"] as? [String: Any])

        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard !key.isEmpty else { continue }
            guard let entry = strings[key] as? [String: Any] else {
                findings.append("键结构无法解析: \(key)")
                continue
            }
            if entry["shouldTranslate"] as? Bool == false {
                continue
            }

            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for locale in supportedLocales.sorted() {
                guard let localization = localizations[locale],
                      localizationHasTranslatedValue(localization) else {
                    findings.append("缺少翻译: [\(locale)] \(key)")
                    continue
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "字符串目录存在缺失翻译:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testImperativeUserFacingStringsAreLocalized() throws {
        let sourceRootURL = try repositoryRootURL().appendingPathComponent("AppPorts")
        let sourceFiles = try swiftSourceFiles(in: sourceRootURL)

        let propertyPattern = try NSRegularExpression(
            pattern: #"\.(prompt|message|informativeText|title|toolTip|placeholderString)\s*=\s*"((?:[^"\\]|\\.)*)""#
        )
        let returnPattern = try NSRegularExpression(
            pattern: #"return\s+"((?:[^"\\]|\\.)*)""#
        )

        var findings: [String] = []

        for fileURL in sourceFiles.sorted(by: { $0.path < $1.path }) {
            let relativePath = try relativeSourcePath(for: fileURL)
            if intentionallyNonLocalizedFiles.contains(relativePath) {
                continue
            }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let isUIFile = relativePath == "ContentView.swift"
                || relativePath == "WelcomeView.swift"
                || relativePath == "Appports.swift"
                || relativePath.hasPrefix("Views/")

            for (lineIndex, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.isEmpty {
                    continue
                }
                if isExplicitlyLocalized(line) {
                    continue
                }

                if let literal = firstMatch(in: line, using: propertyPattern, captureGroup: 2),
                   looksUserFacingText(literal) {
                    findings.append("\(relativePath):\(lineIndex + 1) 非本地化属性赋值 -> \(literal)")
                }

                if isUIFile,
                   let literal = firstMatch(in: line, using: returnPattern, captureGroup: 1),
                   looksUserFacingText(literal) {
                    findings.append("\(relativePath):\(lineIndex + 1) UI 返回值未本地化 -> \(literal)")
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "发现潜在未本地化文案:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testLocalizedStringKeysExistInStringCatalog() throws {
        let sourceRootURL = try repositoryRootURL().appendingPathComponent("AppPorts")
        let sourceFiles = try swiftSourceFiles(in: sourceRootURL)
        let catalogURL = sourceRootURL.appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(rawObject["strings"] as? [String: Any])

        let localizedPattern = try NSRegularExpression(
            pattern: #""((?:[^"\\]|\\.)*)"\.localized"#
        )
        let nsLocalizedPattern = try NSRegularExpression(
            pattern: #"NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)""#
        )

        var findings: [String] = []

        for fileURL in sourceFiles.sorted(by: { $0.path < $1.path }) {
            let relativePath = try relativeSourcePath(for: fileURL)
            if intentionallyNonLocalizedFiles.contains(relativePath) {
                continue
            }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for (lineIndex, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.isEmpty {
                    continue
                }

                for regex in [localizedPattern, nsLocalizedPattern] {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    regex.enumerateMatches(in: line, range: range) { match, _, _ in
                        guard let match,
                              match.numberOfRanges > 1,
                              let literalRange = Range(match.range(at: 1), in: line) else {
                            return
                        }

                        let rawKey = String(line[literalRange])
                        guard !rawKey.isEmpty else { return }
                        if rawKey.contains("\\(") {
                            findings.append("\(relativePath):\(lineIndex + 1) 禁止对插值后的字符串直接做本地化 -> \(rawKey)")
                            return
                        }
                        // Convert Swift escape sequences in the captured literal
                        // to actual characters, matching how they are stored in the xcstrings JSON.
                        let key = rawKey
                            .replacingOccurrences(of: "\\n", with: "\n")
                            .replacingOccurrences(of: "\\t", with: "\t")
                            .replacingOccurrences(of: "\\\"", with: "\"")
                            .replacingOccurrences(of: "\\\\", with: "\\")
                        guard strings[key] == nil else { return }
                        findings.append("\(relativePath):\(lineIndex + 1) 缺少 string catalog key -> \(key)")
                    }
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "发现 .localized / NSLocalizedString 使用问题:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testLocalizedStringKeysAreNotMarkedStale() throws {
        let sourceRootURL = try repositoryRootURL().appendingPathComponent("AppPorts")
        let sourceFiles = try swiftSourceFiles(in: sourceRootURL)
        let strings = try stringCatalog()
        let usages = try localizedStringUsages(in: sourceFiles)

        let findings = usages.compactMap { usage -> String? in
            guard let entry = strings[usage.key] as? [String: Any],
                  entry["extractionState"] as? String == "stale" else {
                return nil
            }
            return "\(usage.relativePath):\(usage.line) string catalog key is stale -> \(usage.key)"
        }

        XCTAssertTrue(
            findings.isEmpty,
            "发现仍在使用但被标记为 stale 的本地化 key:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testProtectedAppWarningTranslationsAreNotEnglishFallbacks() throws {
        let strings = try stringCatalog()
        let nonEnglishLocales = Set(AppLanguageCatalog.selectableLanguages.map(\.code)).subtracting(["en"])
        let protectedAppWarningKeys = [
            "受保护的应用",
            "仍然迁移",
            "以下应用来自 App Store 或归属系统（root），受系统保护：\n\n%@\n\n它们的本地副本通常无法被直接删除或替换，自动迁移可能以「权限不足」失败。\n\n建议：先在访达中手动把应用拖到外部存储（系统会要求输入管理员密码），再回到 AppPorts 为它创建链接。\n\n仍要尝试自动迁移吗？",
            "%@：权限不足，无法删除或替换本地副本。该应用可能来自 App Store 或归属系统（root）。建议在访达中手动迁移后，再用 AppPorts 创建链接。"
        ]

        var findings: [String] = []

        for key in protectedAppWarningKeys {
            guard let entry = strings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let english = localizedStringValue(localizations["en"]) else {
                findings.append("受保护应用提示 key 缺少英文基准 -> \(key)")
                continue
            }

            for locale in nonEnglishLocales.sorted() {
                guard let value = localizedStringValue(localizations[locale]) else {
                    findings.append("受保护应用提示 key 缺少翻译: [\(locale)] \(key)")
                    continue
                }
                if value == english {
                    findings.append("受保护应用提示 key 使用英文占位: [\(locale)] \(key)")
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "受保护应用提示存在英文占位翻译:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testByteCountFormattingFollowsSelectedAppLanguage() {
        LanguageManager.shared.language = "en"
        XCTAssertEqual(
            LocalizedByteCountFormatter.string(fromByteCount: 623),
            "623 bytes"
        )

        LanguageManager.shared.language = "zh-Hans"
        XCTAssertEqual(
            LocalizedByteCountFormatter.string(fromByteCount: 623),
            "623字节"
        )
    }

    private func repositoryRootURL() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func relativeSourcePath(for fileURL: URL) throws -> String {
        let sourceRootURL = try repositoryRootURL().appendingPathComponent("AppPorts")
        let sourceRootPath = sourceRootURL.standardizedFileURL.path + "/"
        return fileURL.standardizedFileURL.path.replacingOccurrences(of: sourceRootPath, with: "")
    }

    private func swiftSourceFiles(in rootURL: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var result: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension == "swift" else { continue }
            result.append(item)
        }
        return result
    }

    private func stringCatalog() throws -> [String: Any] {
        let catalogURL = try repositoryRootURL()
            .appendingPathComponent("AppPorts")
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(rawObject["strings"] as? [String: Any])
    }

    private func localizedStringUsages(in sourceFiles: [URL]) throws -> [LocalizedStringUsage] {
        let localizedPattern = try NSRegularExpression(
            pattern: #""((?:[^"\\]|\\.)*)"\.localized"#
        )
        let nsLocalizedPattern = try NSRegularExpression(
            pattern: #"NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)""#
        )
        var usages: [LocalizedStringUsage] = []

        for fileURL in sourceFiles.sorted(by: { $0.path < $1.path }) {
            let relativePath = try relativeSourcePath(for: fileURL)
            if intentionallyNonLocalizedFiles.contains(relativePath) {
                continue
            }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for (lineIndex, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.isEmpty {
                    continue
                }

                for regex in [localizedPattern, nsLocalizedPattern] {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    regex.enumerateMatches(in: line, range: range) { match, _, _ in
                        guard let match,
                              match.numberOfRanges > 1,
                              let literalRange = Range(match.range(at: 1), in: line) else {
                            return
                        }

                        let rawKey = String(line[literalRange])
                        guard !rawKey.isEmpty, !rawKey.contains("\\(") else { return }
                        let key = decodeSwiftStringLiteralContent(rawKey)
                        usages.append(
                            LocalizedStringUsage(
                                relativePath: relativePath,
                                line: lineIndex + 1,
                                key: key
                            )
                        )
                    }
                }
            }
        }

        return usages
    }

    private func localizationHasTranslatedValue(_ node: Any) -> Bool {
        if let dictionary = node as? [String: Any] {
            if let stringUnit = dictionary["stringUnit"] as? [String: Any],
               let value = stringUnit["value"] as? String,
               !value.isEmpty {
                return true
            }

            if let variations = dictionary["variations"] as? [String: Any],
               variations.values.contains(where: localizationHasTranslatedValue) {
                return true
            }

            if let substitutions = dictionary["substitutions"] as? [String: Any],
               substitutions.values.contains(where: localizationHasTranslatedValue) {
                return true
            }
        }

        if let array = node as? [Any] {
            return array.contains(where: localizationHasTranslatedValue)
        }

        return false
    }

    private func localizedStringValue(_ node: Any?) -> String? {
        if let dictionary = node as? [String: Any] {
            if let stringUnit = dictionary["stringUnit"] as? [String: Any],
               let value = stringUnit["value"] as? String {
                return value
            }

            if let variations = dictionary["variations"] as? [String: Any] {
                return variations.values.compactMap(localizedStringValue).first
            }

            if let substitutions = dictionary["substitutions"] as? [String: Any] {
                return substitutions.values.compactMap(localizedStringValue).first
            }
        }

        if let array = node as? [Any] {
            return array.compactMap(localizedStringValue).first
        }

        return nil
    }

    private func decodeSwiftStringLiteralContent(_ rawKey: String) -> String {
        rawKey
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func firstMatch(in line: String, using regex: NSRegularExpression, captureGroup: Int) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > captureGroup,
              let literalRange = Range(match.range(at: captureGroup), in: line) else {
            return nil
        }
        return String(line[literalRange])
    }

    private func isExplicitlyLocalized(_ line: String) -> Bool {
        line.contains(".localized")
            || line.contains("NSLocalizedString(")
            || line.contains("LocalizedStringKey(")
    }

    private func looksUserFacingText(_ literal: String) -> Bool {
        guard !literal.isEmpty else { return false }
        if literal.contains("\\(") {
            return false
        }
        guard literal.range(of: #"[[:alnum:]]"#, options: .regularExpression) != nil || containsCJK(in: literal) else {
            return false
        }
        if literal.hasPrefix("/") || literal.contains("://") {
            return false
        }
        if literal.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil {
            return false
        }

        return containsCJK(in: literal)
            || literal.contains(" ")
            || literal.contains("\n")
            || literal.contains("...")
            || literal.contains("…")
            || !literal.canBeConverted(to: .ascii)
    }

    private func containsCJK(in literal: String) -> Bool {
        literal.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}
