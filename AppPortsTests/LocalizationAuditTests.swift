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

    // Image-library copy currently ships in Chinese and English; other locales use fallback.
    private let imageTranslationFallbackKeys: Set<String> = [
        "重试所有待处理项",
        "侧边栏宽度",
        "已节省 %@ 堪比黄金的存储空间",

        "外观",
        "跟随系统",
        "浅色",
        "深色",
        "已迁出（估算）",
        "橙色表示已确认在外部存储的数据大小估算；不等于实际释放空间。未连接、未完成或保留本地副本的数据不计入，色段最多占用当前空余部分。",

        "本机磁盘",
        "所在磁盘",
        "映像内空间",
        "使用率",
        "已用",
        "空余",
        "目标存储",
        "更换位置",
        "请输入有效的磁盘名称和 1–65536 GiB 的最大容量。",
        "请选择已挂载的外部存储或 SMB 共享目录。",
        "该位置已有同名文件，请更换名称或打开已有映像。",
        "映像记录无效，请重新打开映像。",
        "映像挂载位置已被占用，请在 Finder 中检查后重试。",
        "无法核对映像对应的磁盘，请在 Finder 中检查后重试。",
        "无法访问所选目录或映像，请先在 Finder 中连接共享。",
        "无法确认映像中的唯一可写 APFS 磁盘，未更改迁移目标。",
        "映像操作未完成，已有文件会保留。",
        "打开已有映像…",
        "重新挂载映像",
        "磁盘映像",
        "创建 APFS 映像",
        "存放位置",
        "磁盘名称",
        "最大容量（GiB）",
        "映像按实际写入占用空间，可存放在已挂载的 SMB 共享中。同一映像请只在一台 Mac 上写入。",
        "以后使用映像中的应用前，请先打开 AppPorts 挂载映像。退出 AppPorts 不会卸载映像。",
        "创建并使用",
    ]

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
            let requiredLocales = imageTranslationFallbackKeys.contains(key)
                ? supportedLocales.intersection(["en", "zh-Hans"]) : supportedLocales
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
                  let sourceValue = localizedStringValue(localizations["zh-Hans"]) ?? localizedStringValue(localizations["en"]) else {
                continue
            }

            let expectedPlaceholders = placeholderSignature(in: sourceValue)
            for locale in supportedLocales {
                guard let value = localizedStringValue(localizations[locale]) else { continue }
                let actualPlaceholders = placeholderSignature(in: value)
                if actualPlaceholders != expectedPlaceholders {
                    findings.append(
                        "占位符不一致: [\(locale)] \(key) expected \(expectedPlaceholders), got \(actualPlaceholders)"
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
            pattern: #""((?:[^"\\]|\\.)*)"\.localized"#
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
        "%@ (%lld 个应用)|de",
        "%@/秒|es", "%@/秒|fr", "%@/秒|pt", "%@/秒|it", "%@/秒|de",
        "%@/秒|nl", "%@/秒|pl", "%@/秒|eo",
        "Auto|fr",
        "Version %@|fr", "Version %@|de",
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
                  let localizations = entry["localizations"] as? [String: Any],
                  let english = localizedStringValue(localizations["en"]),
                  english.unicodeScalars.contains(where: CharacterSet.letters.contains) else {
                continue
            }

            for locale in auditedLocales.sorted() {
                guard let value = localizedStringValue(localizations[locale]),
                      value == english else {
                    continue
                }
                if identicalInEveryLanguage.contains(key) { continue }
                if allowedEnglishLookalikes.contains("\(key)|\(locale)") { continue }
                if protectedSelfName(key: key, locale: locale, value: value) { continue }
                findings.append("英文占位: [\(locale)] \(key)")
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "发现与英文完全相同的译文:\n" + findings.prefix(40).joined(separator: "\n")
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
                guard let value = localizedStringValue(localizations[locale]),
                      containsHanCharacters(value) else {
                    continue
                }
                if protectedSelfName(key: key, locale: locale, value: value) { continue }
                findings.append("非中文译文含汉字: [\(locale)] \(key)")
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
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               stringUnit["state"] as? String == "translated" {
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

    private func placeholderSignature(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[-+#0 ]*(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let escapedPercentPattern = #"%%"#
        let valueWithoutEscapedPercents = value.replacingOccurrences(
            of: escapedPercentPattern,
            with: "",
            options: .regularExpression
        )
        let range = NSRange(valueWithoutEscapedPercents.startIndex..<valueWithoutEscapedPercents.endIndex, in: valueWithoutEscapedPercents)

        return regex.matches(in: valueWithoutEscapedPercents, range: range)
            .compactMap { match -> String? in
                guard let matchRange = Range(match.range, in: valueWithoutEscapedPercents) else {
                    return nil
                }
                let placeholder = String(valueWithoutEscapedPercents[matchRange])
                return placeholder.replacingOccurrences(
                    of: #"^%\d+\$"#,
                    with: "%",
                    options: .regularExpression
                )
            }
            .sorted()
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
