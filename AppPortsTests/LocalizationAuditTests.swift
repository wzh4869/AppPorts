import Darwin
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

    private var originalLanguage = "system"
    private var originalLanguagePreference: Any?

    override func setUp() {
        super.setUp()
        originalLanguage = LanguageManager.shared.language
        originalLanguagePreference = UserDefaults.standard.object(forKey: "selectedLanguage")
    }

    override func tearDown() {
        LanguageManager.shared.language = originalLanguage
        if let originalLanguagePreference {
            UserDefaults.standard.set(originalLanguagePreference, forKey: "selectedLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        }
        super.tearDown()
    }

    func testSupportedLanguageCodesAreUnique() {
        let codes = AppLanguageCatalog.selectableLanguages.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count, "语言注册表存在重复语言代码")
    }

    func testStandalonePortalTranslationsMatchTheCatalog() throws {
        let strings = try stringCatalog()
        let supportedLocales = Set(AppLanguageCatalog.selectableLanguages.map(\.code))
        XCTAssertEqual(Set(PortalLocalizedStrings.translations.keys), [
            "外部存储未连接，请连接后重试。", "好", ApplicationLaunchGate.busyMessage,
            ApplicationLaunchGate.unavailableMessage, "无法打开应用", "系统未能完成启动，请重试。",
        ])
        for (key, translations) in PortalLocalizedStrings.translations {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let locales = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertEqual(Set(translations.keys), supportedLocales, key)
            for locale in supportedLocales {
                XCTAssertEqual(translations[locale], localizedStringValue(locales[locale]), "[\(locale)] \(key)")
            }
        }
    }

    func testStandalonePortalUsesRegionalAndFallbackLanguagePreferences() {
        let key = ApplicationLaunchGate.busyMessage
        let translations = PortalLocalizedStrings.translations[key]!
        XCTAssertEqual(ApplicationLaunchGate.message(busy: true, languages: ["fr-CA"]), translations["fr"])
        XCTAssertEqual(ApplicationLaunchGate.message(busy: true, languages: ["zh-Hant-TW"]), translations["zh-Hant"])
        XCTAssertEqual(ApplicationLaunchGate.message(busy: true, languages: ["zh-HK"]), translations["zh-Hant"])
        XCTAssertEqual(ApplicationLaunchGate.message(busy: true, languages: ["zh_CN"]), translations["zh-Hans"])
        XCTAssertEqual(ApplicationLaunchGate.message(busy: true, languages: ["xx", "ja-JP"]), translations["ja"])
        XCTAssertEqual(ApplicationLaunchGate.message(busy: true, languages: []), translations["en"])
        XCTAssertEqual(ApplicationLaunchGate.message(busy: false, languages: ["de-DE"]),
                       PortalLocalizedStrings.translations[ApplicationLaunchGate.unavailableMessage]?["de"])
    }

    func testCompletedDiskEjectionTranslationsUseTheSelectedLanguage() {
        LanguageManager.shared.language = "fr"
        XCTAssertEqual("弹出外置硬盘".localized, "Éjecter le disque externe")
        LanguageManager.shared.language = "zh-Hant"
        XCTAssertEqual("弹出外置硬盘".localized, "退出外接磁碟")
    }

    func testSourceLanguageTranslationsEqualToTheirKeysArePresent() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual("弹出外置硬盘".localizedValue(in: bundle), "弹出外置硬盘")
        XCTAssertEqual("好".localizedValue(in: bundle), "好")
        XCTAssertNil(("missing-localization-" + UUID().uuidString).localizedValue(in: bundle))
        LanguageManager.shared.language = "zh-Hans"
        XCTAssertEqual("弹出外置硬盘".localized, "弹出外置硬盘")
    }

    func testDurabilityErrorKeepsItsPOSIXCodeAndUsesTheSelectedLanguage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missingRecord = root.appendingPathComponent("record.plist")
        for locale in ["en", "zh-Hant", "fr"] {
            LanguageManager.shared.language = locale
            do {
                try DurableFileIO.write(Data(), to: missingRecord)
                XCTFail("A nonexistent parent must fail")
            } catch let error as NSError {
                XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
                XCTAssertEqual(error.code, Int(ENOENT))
                XCTAssertEqual(error.userInfo[NSFilePathErrorKey] as? String, root.path)
                XCTAssertTrue(error.localizedDescription.contains("打开同步对象".localized))
                XCTAssertTrue(error.localizedDescription.contains(String(cString: strerror(ENOENT))))
            }
        }
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
            let requiredLocales = supportedLocales
            for locale in requiredLocales.sorted() {
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

    func testStringCatalogKeysAndLocalesAreClean() throws {
        let supportedLocales = Set(AppLanguageCatalog.selectableLanguages.map(\.code))
        let strings = try stringCatalog()

        var findings: [String] = []
        if strings.keys.contains("") {
            findings.append("字符串目录包含空 key")
        }

        for key in strings.keys.sorted() {
            guard let entry = strings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                continue
            }

            let unsupportedLocales = Set(localizations.keys).subtracting(supportedLocales)
            for locale in unsupportedLocales.sorted() {
                findings.append("不支持的 locale: [\(locale)] \(key)")
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "字符串目录存在不干净的 key 或 locale:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testStringCatalogDoesNotContainStaleEntries() throws {
        let strings = try stringCatalog()

        let staleKeys = strings.keys.sorted().filter { key in
            guard let entry = strings[key] as? [String: Any] else { return false }
            return entry["extractionState"] as? String == "stale"
        }

        XCTAssertTrue(
            staleKeys.isEmpty,
            "字符串目录仍包含 stale key:\n" + staleKeys.prefix(40).joined(separator: "\n")
        )
    }

    func testStringCatalogPlaceholdersStayConsistentAcrossLocales() throws {
        let supportedLocales = AppLanguageCatalog.selectableLanguages.map(\.code)
        let strings = try stringCatalog()

        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard !key.isEmpty,
                  let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any],
                  let sourceNode = localizations["zh-Hans"] ?? localizations["en"],
                  let expectedSignature = placeholderArgumentSignature(in: sourceNode) else {
                continue
            }

            for locale in supportedLocales {
                guard let node = localizations[locale] else { continue }
                let signatures = allPlaceholderArgumentSignatures(in: node)
                if signatures.isEmpty {
                    findings.append("占位符结构异常: [\(locale)] \(key)")
                    continue
                }
                for actualSignature in signatures where actualSignature != expectedSignature {
                    findings.append(
                        "占位符位置或类型不一致: [\(locale)] \(key) expected \(expectedSignature), got \(actualSignature)"
                    )
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "字符串目录存在占位符不一致:\n" + findings.prefix(40).joined(separator: "\n")
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
            pattern: #"(?<!")"((?:[^"\\]|\\.)*)"\.localized(?:Format)?\b"#
        )
        let multilineLocalizedPattern = try NSRegularExpression(
            pattern: #"\"\"\"\n(.*?)\n([ \t]*)\"\"\"\.localized(?:Format)?\b"#,
            options: [.dotMatchesLineSeparators]
        )
        let nsLocalizedPattern = try NSRegularExpression(
            pattern: #"NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)""#
        )

        var findings: [String] = []

        for fileURL in sourceFiles.sorted(by: { $0.path < $1.path }) {
            let relativePath = try relativeSourcePath(for: fileURL)
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
                        let key = decodeSwiftStringLiteralContent(rawKey)
                        guard strings[key] == nil else { return }
                        findings.append("\(relativePath):\(lineIndex + 1) 缺少 string catalog key -> \(key)")
                    }
                }
            }

            let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
            multilineLocalizedPattern.enumerateMatches(in: content, range: fullRange) { match, _, _ in
                guard let match,
                      match.numberOfRanges > 2,
                      let bodyRange = Range(match.range(at: 1), in: content),
                      let indentRange = Range(match.range(at: 2), in: content),
                      let matchStartRange = Range(match.range, in: content) else {
                    return
                }
                let lineNumber = content[..<matchStartRange.lowerBound].filter { $0 == "\n" }.count + 1
                let rawBody = String(content[bodyRange])
                if rawBody.contains("\\(") {
                    findings.append("\(relativePath):\(lineNumber) 禁止对插值后的字符串直接做本地化 -> \(rawBody)")
                    return
                }
                let key = decodeSwiftMultilineStringLiteralContent(
                    rawBody,
                    closingIndent: String(content[indentRange])
                )
                guard !key.isEmpty, strings[key] == nil else { return }
                findings.append("\(relativePath):\(lineNumber) 缺少 string catalog key -> \(key)")
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
            "继续迁移",
            "以下应用来自 App Store 或归属系统（root），受 macOS 保护：\n\n%@\n\n迁移时 AppPorts 会先把应用完整复制到外部存储，再删除本地副本。\n\n删除本地副本时系统会要求输入管理员密码，你也会听到垃圾桶的声音 —— 这都是正常的，点允许即可，AppPorts 会自动完成后续步骤。",
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

    /// Keys whose text is deliberately identical in every language: brand names,
    /// real `~/Library` folder names that users must recognise on disk, size units,
    /// and strings that consist only of placeholders or punctuation.
    private let identicalInEveryLanguage: Set<String> = [
        "%lld", "%lld / %lld",
        "1 MB", "2 MB", "5 MB", "10 MB", "50 MB", "100 MB",
        "App Store", "AppPorts", "GitHub", "Mac", "WebKit",
        "Application Scripts", "Application Support", "Caches", "Containers",
        "Group Containers", "HTTPStorages", "Logs", "Preferences", "Saved State",
        ", ", ", %@",
    ]

    /// Native cognates: the target language spells this word exactly like English,
    /// so an identical value is correct rather than a missing translation.
    private let allowedEnglishLookalikes: Set<String> = [
        "%@ (%lld 个应用)|de", "%@ (%lld 个应用)|es", "%@ (%lld 个应用)|fr",
        "%@ (%lld 个应用)|nl", "%@ (%lld 个应用)|pt",
        "%lld 个应用|de", "%lld 个应用|it",
        "%@/秒|es", "%@/秒|fr", "%@/秒|pt", "%@/秒|it", "%@/秒|de",
        "%@/秒|nl", "%@/秒|pl", "%@/秒|eo",
        "Auto|fr",
        "Version %@|fr", "Version %@|de",
        "版本 %@（构建 %@）|de",
        "文件系统|it",
        "• 资源叉|nl",
        "以后再说|nl", "稍后|nl", "更新|nl", "项目|nl",
        "可选|de", "名称|de", "应用|de", "应用|nl", "应用: %@|de", "应用: %@|nl",
        "状态|de", "状态|nl", "状态|id",
        "筛选|de", "筛选|nl", "筛选|id",
        "系统|de", "系统|pl", "日志|pt", "日志|nl",
        "否|es", "否|it", "错误|es", "密码|it",
        "好|ja", "好的|ja",
        "操作|fr", "注意|fr", "用户文档|fr",
        "本地|es", "本地|fr", "本地|pt",
    ]

    /// Language self-names the picker must always show in their own script, keyed by
    /// catalog key, then by the locale that has to keep that exact spelling.
    ///
    /// These entries are the only place where a value may equal both the English value
    /// and the Chinese key. The exemption is bound to the expected string: if one of
    /// them is reworded, translated, or replaces the name with another script, the two
    /// placeholder guards no longer recognise it, and
    /// `testLanguageSelfNamesKeepTheirNativeSpelling` fails directly.
    private let protectedSelfNames: [String: [String: String]] = [
        "日本語": [
            "en": "日本語", "zh-Hans": "日本語", "zh-Hant": "日本語", "ja": "日本語",
        ],
        "日本語 (AI)": [
            "en": "日本語 (AI)", "zh-Hans": "日本語 (AI)", "zh-Hant": "日本語 (AI)", "ja": "日本語 (AI)",
        ],
        "繁體中文": [
            "en": "繁體中文", "zh-Hans": "繁體中文", "zh-Hant": "繁體中文",
            "ja": "繁體中文", "ko": "繁體中文",
        ],
        "煋仌呅": [
            "en": "煋仌呅", "zh-Hans": "煋仌呅", "zh-Hant": "煋仌呅", "zh-martian": "煋仌呅",
        ],
    ]

    private func protectedSelfName(key: String, locale: String, value: String) -> Bool {
        protectedSelfNames[key]?[locale] == value
    }

    /// Guards against regressing to English placeholders. `br` and `zh-martian` are
    /// excluded: Braille is derived from the English text by design, and Martian
    /// Chinese shares symbols with English.
    func testTranslationsAreNotEnglishPlaceholders() throws {
        let strings = try stringCatalog()
        let auditedLocales = Set(AppLanguageCatalog.selectableLanguages.map(\.code))
            .subtracting(["en", "br", "zh-martian"])

        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard !key.isEmpty,
                  let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any] else {
                continue
            }
            let englishValues = translatableValuesForPlaceholderCheck(localizations["en"])
            let normalizedEnglish = Set(englishValues.map(normalizedComparisonText))
            guard englishValues.contains(where: { strippingPlaceholders($0).unicodeScalars.contains(where: CharacterSet.letters.contains) }) else {
                continue
            }

            for locale in auditedLocales.sorted() {
                let values = translatableValuesForPlaceholderCheck(localizations[locale])
                guard !values.isEmpty else { continue }
                if identicalInEveryLanguage.contains(key) { continue }
                if allowedEnglishLookalikes.contains("\(key)|\(locale)") { continue }
                for value in values {
                    if protectedSelfName(key: key, locale: locale, value: value) { continue }
                    if englishValues.contains(value) || normalizedEnglish.contains(normalizedComparisonText(value)) {
                        findings.append("英文占位: [\(locale)] \(key) -> \(value)")
                        break
                    }
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "发现与英文相同或仅大小写不同的译文:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testNoSharedUntranslatedEnglishPhraseAcrossManyLocales() throws {
        let strings = try stringCatalog()
        let auditedLocales = ["es", "fr", "pt", "it", "de", "ru", "ar", "hi", "vi", "th", "tr", "nl", "pl", "id", "eo"]
        let allowedSharedWords: Set<String> = ["Autor", "App Store"]
        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard !key.isEmpty,
                  !identicalInEveryLanguage.contains(key),
                  protectedSelfNames[key] == nil,
                  let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any] else {
                continue
            }
            var asciiBuckets: [String: [String]] = [:]
            for locale in auditedLocales {
                if allowedEnglishLookalikes.contains("\(key)|\(locale)") { continue }
                for value in translatableValuesForPlaceholderCheck(localizations[locale]) {
                    let cleaned = strippingPlaceholders(value)
                    guard cleaned.unicodeScalars.allSatisfy({ $0.value < 128 }),
                          cleaned.unicodeScalars.contains(where: CharacterSet.letters.contains),
                          !allowedSharedWords.contains(value) else {
                        continue
                    }
                    asciiBuckets[value, default: []].append(locale)
                }
            }
            for (value, locales) in asciiBuckets where Set(locales).count >= 4 {
                findings.append("多语共享疑似未译英文 (\(Set(locales).sorted().joined(separator: ","))): \(key) -> \(value)")
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "发现多个非英语语种共享相同 ASCII 文案:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    /// Latin-script locales must not leak Chinese characters; Japanese and
    /// Traditional Chinese legitimately share Han characters with the source.
    func testLatinLocalesDoNotContainHanCharacters() throws {
        let strings = try stringCatalog()
        let latinLocales = ["en", "es", "fr", "pt", "it", "de", "ru", "ar", "hi", "vi", "th", "tr", "nl", "pl", "id", "eo"]

        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard !key.isEmpty,
                  let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any] else {
                continue
            }

            for locale in latinLocales {
                for value in allLocalizedStringValues(localizations[locale]) where containsHanCharacters(value) {
                    if protectedSelfName(key: key, locale: locale, value: value) { continue }
                    findings.append("非中文译文含汉字: [\(locale)] \(key)")
                    break
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "拉丁语系译文仍含汉字:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    /// Short strings where Japanese legitimately uses the same characters as the
    /// Simplified Chinese source. Language self-names are handled by
    /// `protectedSelfNames` instead of being listed here.
    private let sharedHanKeys: Set<String> = [
        "作者", "外部", "操作", "注意", "重要", "速度: %@ MB/s", "%@/秒",
    ]

    /// Catches a translation that was left as the Chinese key (the failure mode that
    /// hid 187 Japanese strings: they were neither empty nor equal to English).
    func testNonChineseTranslationsDoNotReuseTheSourceKey() throws {
        let strings = try stringCatalog()
        let auditedLocales = ["en", "ja", "ko"] + ["es", "fr", "pt", "it", "de", "ru",
                                                  "ar", "hi", "vi", "th", "tr", "nl",
                                                  "pl", "id", "eo"]

        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard !key.isEmpty, containsHanCharacters(key),
                  let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any] else {
                continue
            }
            if sharedHanKeys.contains(key) { continue }

            for locale in auditedLocales {
                guard let value = localizedStringValue(localizations[locale]),
                      value == key else {
                    continue
                }
                if protectedSelfName(key: key, locale: locale, value: value) { continue }
                findings.append("译文仍为中文 key: [\(locale)] \(key)")
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "发现直接沿用中文 key 的译文:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    /// The language picker shows every language in its own script. Rewording one of
    /// those names, translating it, or replacing it with another script has to fail
    /// here even though the three placeholder guards intentionally let it pass.
    func testLanguageSelfNamesKeepTheirNativeSpelling() throws {
        let strings = try stringCatalog()
        var findings: [String] = []

        for (key, locales) in protectedSelfNames {
            guard let entry = strings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                findings.append("语言自称缺少条目: \(key)")
                continue
            }
            for (locale, expected) in locales {
                let actual = localizedStringValue(localizations[locale])
                if actual != expected {
                    findings.append("[\(locale)] \(key): 期望「\(expected)」实际「\(actual ?? "nil")」")
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "语言自称的原名被改动:\n" + findings.prefix(40).joined(separator: "\n")
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

        // Braille uses `br`, which ISO 639-1 assigns to Breton; formatting must fall back to English.
        LanguageManager.shared.language = "br"
        XCTAssertEqual(
            LocalizedByteCountFormatter.string(fromByteCount: 623),
            "623 bytes"
        )
    }

    func testInfoPlistCatalogContainsTranslationsForAllSupportedLanguages() throws {
        let supportedLocales = Set(AppLanguageCatalog.selectableLanguages.map(\.code))
        let strings = try stringCatalog(named: "InfoPlist.xcstrings")
        let key = "NSAppleEventsUsageDescription"
        let entry = try XCTUnwrap(strings[key] as? [String: Any], "InfoPlist.xcstrings 缺少 \(key)")
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])

        XCTAssertEqual(Set(localizations.keys), supportedLocales)
        for locale in supportedLocales.sorted() {
            XCTAssertTrue(
                localizationHasTranslatedValue(localizations[locale] as Any),
                "InfoPlist.xcstrings 缺少翻译: [\(locale)] \(key)"
            )
        }
    }

    func testBrailleTranslationsContainBrailleCharactersAndNoBretonText() throws {
        let strings = try stringCatalog()
        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard !key.isEmpty,
                  !identicalInEveryLanguage.contains(key),
                  protectedSelfNames[key] == nil,
                  key != "English",
                  let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any] else {
                continue
            }
            let enValues = allLocalizedStringValues(localizations["en"])
            guard enValues.contains(where: { strippingPlaceholders($0).unicodeScalars.contains(where: CharacterSet.letters.contains) }) else {
                continue
            }
            for value in allLocalizedStringValues(localizations["br"]) {
                let cleaned = strippingPlaceholders(value)
                let hasBraille = cleaned.unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) }
                let hasUnexpectedAlpha = cleaned.unicodeScalars.contains { CharacterSet.letters.contains($0) && !(0x2800...0x28FF).contains($0.value) }
                if !hasBraille || hasUnexpectedAlpha {
                    findings.append("盲文异常: \(key) -> \(value)")
                    break
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "盲文 (br) 存在非盲文或布列塔尼语混入:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testNonLatinLocalesContainNativeScript() throws {
        let strings = try stringCatalog()
        let scriptChecks: [(String, (UInt32) -> Bool)] = [
            ("ar", { (0x0600...0x06FF).contains($0) || (0x0750...0x077F).contains($0) }),
            ("hi", { (0x0900...0x097F).contains($0) }),
            ("th", { (0x0E00...0x0E7F).contains($0) }),
            ("ru", { (0x0400...0x04FF).contains($0) }),
            ("ko", { (0xAC00...0xD7AF).contains($0) || (0x1100...0x11FF).contains($0) }),
            ("ja", { (0x3040...0x30FF).contains($0) || (0x4E00...0x9FFF).contains($0) }),
        ]
        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard !key.isEmpty,
                  !identicalInEveryLanguage.contains(key),
                  protectedSelfNames[key] == nil,
                  key != "English",
                  let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any] else {
                continue
            }
            let enValues = allLocalizedStringValues(localizations["en"])
            guard enValues.contains(where: { strippingPlaceholders($0).unicodeScalars.contains(where: CharacterSet.letters.contains) }) else {
                continue
            }

            for (locale, isNativeScalar) in scriptChecks {
                if allowedEnglishLookalikes.contains("\(key)|\(locale)") { continue }
                let values = translatableValuesForPlaceholderCheck(localizations[locale])
                guard !values.isEmpty else { continue }
                for value in values {
                    let hasNative = value.unicodeScalars.contains { isNativeScalar($0.value) }
                    if !hasNative {
                        findings.append("缺少目标文字脚本: [\(locale)] \(key) -> \(value)")
                        break
                    }
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "非拉丁语系存在罗马音或未译英文:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testTraditionalChineseDoesNotLeakSimplifiedCharacters() throws {
        let strings = try stringCatalog()
        // Characters that are valid Traditional Chinese orthography or legitimate contextual variants
        // even when CFStringTransform("Hans-Hant") prefers an alternate glyph.
        let allowedDoublets = Set(
            "台裡著啟為眾群線衛峰污才並游匯占制准乾復覆餘藉穀麵鬆鐘範劃歷曆繫徵採託隻捲佈誌讚昇週註釐嚐牠姊兇禦剋僱迴夥曬祕鏽樑摺桿檯夠卻捨舖恆況淨涼減決憑于后發了解"
        )
        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard !key.isEmpty,
                  protectedSelfNames[key] == nil,
                  let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any] else {
                continue
            }
            for value in allLocalizedStringValues(localizations["zh-Hant"]) {
                let mutable = NSMutableString(string: value)
                CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
                let transformed = mutable as String
                guard transformed != value else { continue }
                let leaked = zip(value, transformed).compactMap { original, expected -> String? in
                    guard original != expected,
                          !allowedDoublets.contains(original),
                          !allowedDoublets.contains(expected) else { return nil }
                    return "\(original)->\(expected)"
                }
                if !leaked.isEmpty {
                    findings.append("繁體中文含簡體字 [\(leaked.joined(separator: ", "))]: \(key) -> \(value)")
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "zh-Hant 存在簡體字洩漏:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testDistinctLongKeysDoNotShareIdenticalTranslations() throws {
        let strings = try stringCatalog()
        let allowedSynonymousPairs: Set<Set<String>> = [
            ["外置盘未连接", "外部存储未连接"],
            ["显示不可迁移目录", "显示不支持迁移目录"],
            ["部分数据操作尚未完成，副本已保留。", "部分数据操作尚未完成，已保留副本。"],
            ["挂载迁移「%@」", "正在挂载迁移「%@」"],
        ]
        let auditedLocales = Set(AppLanguageCatalog.selectableLanguages.map(\.code))
            .subtracting(["en", "zh-Hans", "br", "zh-martian"])
        var findings: [String] = []

        for locale in auditedLocales.sorted() {
            var valueToKeys: [String: [String]] = [:]
            for key in strings.keys.sorted() {
                guard let entry = strings[key] as? [String: Any],
                      entry["shouldTranslate"] as? Bool != false,
                      let localizations = entry["localizations"] as? [String: Any],
                      let value = localizedStringValue(localizations[locale]),
                      value.count >= 25 else {
                    continue
                }
                valueToKeys[value, default: []].append(key)
            }
            for (value, keys) in valueToKeys where keys.count > 1 {
                if allowedSynonymousPairs.contains(Set(keys)) { continue }
                let englishSet = Set(keys.compactMap { key -> String? in
                    guard let entry = strings[key] as? [String: Any],
                          let localizations = entry["localizations"] as? [String: Any] else { return nil }
                    return localizedStringValue(localizations["en"])
                })
                if englishSet.count > 1 {
                    findings.append("[\(locale)] 不同文案共用同一译文 (\(keys.joined(separator: " | "))) -> \(value)")
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "发现疑似复制错位的重复译文:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testBrandNameAppPortsIsNotMisspelledAsAppPort() throws {
        let strings = try stringCatalog()
        let auditedLocales = Set(AppLanguageCatalog.selectableLanguages.map(\.code))
            .subtracting(["br", "zh-martian"])
        let regex = try NSRegularExpression(pattern: #"\bAppPort(?!s)\b"#)
        var findings: [String] = []

        for key in strings.keys.sorted() {
            guard let entry = strings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let zh = localizedStringValue(localizations["zh-Hans"]),
                  zh.contains("AppPorts") else {
                continue
            }
            for locale in auditedLocales.sorted() {
                for value in allLocalizedStringValues(localizations[locale]) {
                    let range = NSRange(value.startIndex..<value.endIndex, in: value)
                    if regex.firstMatch(in: value, range: range) != nil {
                        findings.append("品牌名漏写 s: [\(locale)] \(key) -> \(value)")
                        break
                    }
                }
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "译文中存在 AppPort 拼写错误:\n" + findings.prefix(40).joined(separator: "\n")
        )
    }

    func testLayoutDirectionAndFormattingLocaleFollowSelectedLanguage() {
        XCTAssertEqual(LanguageManager.layoutDirection(for: "ar"), .rightToLeft)
        XCTAssertEqual(LanguageManager.layoutDirection(for: "en"), .leftToRight)
        XCTAssertEqual(LanguageManager.layoutDirection(for: "zh-Hans"), .leftToRight)
        XCTAssertEqual(LanguageManager.layoutDirection(for: "br"), .leftToRight)
        XCTAssertEqual(LanguageManager.formattingLocale(for: "br").identifier, "en")
        XCTAssertEqual(LanguageManager.formattingLocale(for: "zh-martian").identifier, "zh-Hans")

        LanguageManager.shared.language = "br"
        XCTAssertFalse(AboutWindowController.windowTitle().contains("⠲⠲⠲"))
        LanguageManager.shared.language = "en"
        XCTAssertFalse(AboutWindowController.windowTitle().contains("..."))
    }

    func testPluralFormatResolvesSelectedAppLanguageRules() {
        LanguageManager.shared.language = "en"
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(1)), "1 app")
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(2)), "2 apps")
        XCTAssertEqual("%lld 个目录".localizedFormat(Int64(1)), "1 Directory")
        XCTAssertEqual("%lld 个目录".localizedFormat(Int64(3)), "3 Directories")
        XCTAssertEqual("%@ (%lld 个应用)".localizedFormat("Tools", Int64(1)), "Tools (1 App)")
        XCTAssertEqual("%@ (%lld 个应用)".localizedFormat("Tools", Int64(4)), "Tools (4 Apps)")
        XCTAssertEqual("共 %d 个应用".localizedFormat(1), "Total: 1 app")
        XCTAssertEqual("共 %d 个应用".localizedFormat(5), "Total: 5 apps")

        LanguageManager.shared.language = "ru"
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(1)), "1 приложение")
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(2)), "2 приложения")
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(5)), "5 приложений")

        LanguageManager.shared.language = "pl"
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(1)), "1 aplikacja")
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(2)), "2 aplikacje")
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(5)), "5 aplikacji")

        LanguageManager.shared.language = "ar"
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(1)), "تطبيق واحد (1)")
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(2)), "تطبيقان (2)")
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(3)), "3 تطبيقات")
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(11)), "11 تطبيقًا")

        LanguageManager.shared.language = "br"
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(1)), "1 ⠁⠏⠏")
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(2)), "2 ⠁⠏⠏⠎")

        LanguageManager.shared.language = "zh-Hans"
        XCTAssertEqual("%lld 个应用".localizedFormat(Int64(1)), "1 个应用")
    }

    func testLocalizedListJoinedMatchesSelectedLanguage() {
        LanguageManager.shared.language = "zh-Hans"
        XCTAssertEqual(["Safari", "Xcode"].localizedListJoined, "Safari、Xcode")
        LanguageManager.shared.language = "en"
        XCTAssertEqual(["Safari", "Xcode"].localizedListJoined, "Safari, Xcode")
        LanguageManager.shared.language = "ar"
        XCTAssertEqual(["Safari", "Xcode"].localizedListJoined, "Safari، Xcode")
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

    private func stringCatalog(named fileName: String = "Localizable.xcstrings") throws -> [String: Any] {
        let catalogURL = try repositoryRootURL()
            .appendingPathComponent("AppPorts")
            .appendingPathComponent(fileName)
        let data = try Data(contentsOf: catalogURL)
        let rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(rawObject["strings"] as? [String: Any])
    }

    private func localizedStringUsages(in sourceFiles: [URL]) throws -> [LocalizedStringUsage] {
        let localizedPattern = try NSRegularExpression(
            pattern: #"(?<!")"((?:[^"\\]|\\.)*)"\.localized(?:Format)?\b"#
        )
        let multilineLocalizedPattern = try NSRegularExpression(
            pattern: #"\"\"\"\n(.*?)\n([ \t]*)\"\"\"\.localized(?:Format)?\b"#,
            options: [.dotMatchesLineSeparators]
        )
        let nsLocalizedPattern = try NSRegularExpression(
            pattern: #"NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)""#
        )
        var usages: [LocalizedStringUsage] = []

        for fileURL in sourceFiles.sorted(by: { $0.path < $1.path }) {
            let relativePath = try relativeSourcePath(for: fileURL)
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

            let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
            multilineLocalizedPattern.enumerateMatches(in: content, range: fullRange) { match, _, _ in
                guard let match,
                      match.numberOfRanges > 2,
                      let bodyRange = Range(match.range(at: 1), in: content),
                      let indentRange = Range(match.range(at: 2), in: content),
                      let matchStartRange = Range(match.range, in: content) else {
                    return
                }
                let rawBody = String(content[bodyRange])
                guard !rawBody.isEmpty, !rawBody.contains("\\(") else { return }
                let lineNumber = content[..<matchStartRange.lowerBound].filter { $0 == "\n" }.count + 1
                let key = decodeSwiftMultilineStringLiteralContent(
                    rawBody,
                    closingIndent: String(content[indentRange])
                )
                usages.append(
                    LocalizedStringUsage(
                        relativePath: relativePath,
                        line: lineNumber,
                        key: key
                    )
                )
            }
        }

        return usages
    }

    private func localizationHasTranslatedValue(_ node: Any) -> Bool {
        if let dictionary = node as? [String: Any] {
            var checkedBranch = false
            if let stringUnit = dictionary["stringUnit"] as? [String: Any] {
                guard let value = stringUnit["value"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      stringUnit["state"] as? String == "translated" else {
                    return false
                }
                checkedBranch = true
            }

            if let variations = dictionary["variations"] as? [String: Any] {
                guard !variations.isEmpty else { return false }
                for variationGroup in variations.values {
                    guard let branches = variationGroup as? [String: Any], !branches.isEmpty,
                          branches.values.allSatisfy(localizationHasTranslatedValue) else {
                        return false
                    }
                }
                checkedBranch = true
            }

            if let substitutions = dictionary["substitutions"] as? [String: Any] {
                guard !substitutions.isEmpty,
                      substitutions.values.allSatisfy(localizationHasTranslatedValue) else {
                    return false
                }
                checkedBranch = true
            }

            return checkedBranch
        }

        if let array = node as? [Any] {
            return !array.isEmpty && array.allSatisfy(localizationHasTranslatedValue)
        }

        return false
    }

    private func localizedStringValue(_ node: Any?) -> String? {
        allLocalizedStringValues(node).first
    }

    private func allLocalizedStringValues(_ node: Any?) -> [String] {
        guard let dictionary = node as? [String: Any] else { return [] }
        var values: [String] = []
        if let stringUnit = dictionary["stringUnit"] as? [String: Any],
           let value = stringUnit["value"] as? String {
            values.append(value)
        }
        if let variations = dictionary["variations"] as? [String: Any] {
            for key in variations.keys.sorted() {
                if let group = variations[key] as? [String: Any] {
                    for branchKey in group.keys.sorted() {
                        values.append(contentsOf: allLocalizedStringValues(group[branchKey]))
                    }
                }
            }
        }
        if let substitutions = dictionary["substitutions"] as? [String: Any] {
            for key in substitutions.keys.sorted() {
                values.append(contentsOf: allLocalizedStringValues(substitutions[key]))
            }
        }
        return values
    }

    /// Returns the human-readable text units for placeholder/script checks.
    /// For substitution templates whose outer string carries prose (e.g. multi-line notices),
    /// inspect the outer template; for placeholder-only shells like `%1$@ (%2$#@apps@)`,
    /// inspect the substitution plural branches instead.
    private func translatableValuesForPlaceholderCheck(_ node: Any?) -> [String] {
        guard let dictionary = node as? [String: Any] else { return [] }
        if let substitutions = dictionary["substitutions"] as? [String: Any],
           let stringUnit = dictionary["stringUnit"] as? [String: Any],
           let outer = stringUnit["value"] as? String {
            if strippingPlaceholders(outer).unicodeScalars.contains(where: CharacterSet.letters.contains) {
                return [outer]
            }
            var branchValues: [String] = []
            for key in substitutions.keys.sorted() {
                branchValues.append(contentsOf: allLocalizedStringValues(substitutions[key]))
            }
            return branchValues
        }
        return allLocalizedStringValues(node).filter {
            strippingPlaceholders($0).unicodeScalars.contains(where: CharacterSet.letters.contains)
        }
    }

    private func decodeSwiftStringLiteralContent(_ rawKey: String) -> String {
        rawKey
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func decodeSwiftMultilineStringLiteralContent(_ rawBody: String, closingIndent: String) -> String {
        let strippedLines = rawBody.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix(closingIndent) {
                return String(line.dropFirst(closingIndent.count))
            }
            return line
        }
        let joined = strippedLines.joined(separator: "\n")
            .replacingOccurrences(of: #"\\\n[ \t]*"#, with: "", options: .regularExpression)
        return decodeSwiftStringLiteralContent(joined)
    }

    private func placeholderArgumentSignature(in node: Any) -> [Int: [String]]? {
        allPlaceholderArgumentSignatures(in: node).first
    }

    private func allPlaceholderArgumentSignatures(in node: Any) -> [[Int: [String]]] {
        guard let dictionary = node as? [String: Any] else { return [] }

        if let substitutions = dictionary["substitutions"] as? [String: Any],
           let stringUnit = dictionary["stringUnit"] as? [String: Any],
           let template = stringUnit["value"] as? String {
            guard var base = argumentSignature(in: template, substitutions: substitutions) else {
                return []
            }
            // Verify every substitution plural branch uses %arg or matching specifier cleanly.
            for (name, rawSub) in substitutions {
                guard let sub = rawSub as? [String: Any],
                      let argNum = sub["argNum"] as? Int,
                      let spec = sub["formatSpecifier"] as? String else {
                    return []
                }
                let branchValues = allLocalizedStringValues(sub)
                guard !branchValues.isEmpty else { return [] }
                for branch in branchValues {
                    if !branch.contains("%arg") && !branch.contains("%\(argNum)$\(spec)") && !branch.contains("%\(spec)") {
                        return []
                    }
                }
                if base[argNum] == nil {
                    base[argNum] = ["%" + spec]
                }
                _ = name
            }
            return [base]
        }

        if let variations = dictionary["variations"] as? [String: Any] {
            var results: [[Int: [String]]] = []
            for groupKey in variations.keys.sorted() {
                guard let group = variations[groupKey] as? [String: Any] else { continue }
                for branchKey in group.keys.sorted() {
                    results.append(contentsOf: allPlaceholderArgumentSignatures(in: group[branchKey] as Any))
                }
            }
            return results
        }

        if let stringUnit = dictionary["stringUnit"] as? [String: Any],
           let value = stringUnit["value"] as? String {
            guard let sig = argumentSignature(in: value, substitutions: nil) else { return [] }
            return [sig]
        }

        return []
    }

    private func argumentSignature(in value: String, substitutions: [String: Any]?) -> [Int: [String]]? {
        let pattern = #"%(?:(\d+)\$)?(?:#@([A-Za-z0-9_]+)@|[-+#0 ]*(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:hh|h|ll|l|L|z|t|j)?([@diuoxXfFeEgGaAcCsSp]))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let cleaned = value.replacingOccurrences(of: "%%", with: "")
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        var result: [Int: [String]] = [:]
        var sequentialIndex = 1
        var sawPositional = false
        var sawSequential = false

        for match in regex.matches(in: cleaned, range: range) {
            let argIndex: Int
            if match.range(at: 1).location != NSNotFound,
               let posRange = Range(match.range(at: 1), in: cleaned),
               let parsed = Int(cleaned[posRange]) {
                argIndex = parsed
                sawPositional = true
            } else {
                argIndex = sequentialIndex
                sequentialIndex += 1
                sawSequential = true
            }

            if match.range(at: 2).location != NSNotFound,
               let subNameRange = Range(match.range(at: 2), in: cleaned) {
                let subName = String(cleaned[subNameRange])
                guard let sub = substitutions?[subName] as? [String: Any],
                      let expectedArgNum = sub["argNum"] as? Int,
                      expectedArgNum == argIndex,
                      let spec = sub["formatSpecifier"] as? String else {
                    return nil
                }
                result[argIndex, default: []].append("%" + spec)
            } else if match.range(at: 3).location != NSNotFound,
                      let fullRange = Range(match.range, in: cleaned) {
                let normalized = String(cleaned[fullRange]).replacingOccurrences(
                    of: #"^%\d+\$"#,
                    with: "%",
                    options: .regularExpression
                )
                result[argIndex, default: []].append(normalized)
            }
        }

        if sawPositional && sawSequential {
            return nil
        }
        return result
    }

    private func strippingPlaceholders(_ value: String) -> String {
        let pattern = #"%(?:\d+\$)?(?:#@[A-Za-z0-9_]+@|arg|[-+#0 ]*(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp])"#
        return value
            .replacingOccurrences(of: "%%", with: "")
            .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private func normalizedComparisonText(_ value: String) -> String {
        let folded = value.lowercased()
            .replacingOccurrences(of: #"[\s.,!?:;…\"'“”‘’()（）\[\]【】]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folded
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

    private func containsHanCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
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
