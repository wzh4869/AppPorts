//
//  UpdateChecker.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation

// MARK: - Data Models

/// GitHub Release 信息。
struct ReleaseInfo: Codable, Equatable {
    let tagName: String
    let htmlUrl: String
    let body: String
    var assets: [GitHubUpdateAsset]? = nil

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
        case assets
    }
}

/// 官网 latest.json 信息。
struct OfficialReleaseInfo: Codable, Equatable {
    let version: String
    let tag: String
    let build: Int
    let publishedAt: String
    let minimumSupportedVersion: String
    let releaseNotes: [String: String]
    let links: OfficialReleaseLinks
    let sha256: String
}

struct OfficialReleaseLinks: Codable, Equatable {
    let github: String
    let primaryDownload: String
    let mirrorDownload: String
}

/// 更新弹窗使用的统一模型。
struct AppUpdateInfo: Equatable, Identifiable {
    enum Source: String {
        case github
        case official
    }

    let version: String
    let source: Source
    let releaseNotesMarkdown: String
    let githubURL: URL?
    let chinaDownloadURL: URL
    let sha256: String?
    var githubAsset: GitHubUpdateAsset? = nil
    var domesticAsset: AppUpdatePackageAsset? = nil

    var id: String { source.rawValue + ":" + version }
}

enum UpdateCheckResult: Equatable {
    case available(AppUpdateInfo)
    case upToDate
    case failed
}

enum UpdateChannel: String {
    case github
    case official

    static let defaultsKey = "UpdateChannel"

    static var preferred: UpdateChannel {
        UpdateChannel(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .official
    }
}

// MARK: - Update Checker

/// 应用更新检查工具。
///
/// 默认通过文档站 latest.json 检查版本；选择 GitHub 更新后再获取对应版本的安装附件。
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let defaultOfficialFeedURL = URL(string: "https://docs-appports.shimoko.com/latest.json")!
    private static let defaultChinaDownloadURL = URL(string: "https://file.shimoko.com/AppPorts")!

    private let repoOwner = "wzh4869"
    private let repoName = "AppPorts"
    private let session: URLSession
    private let officialFeedURL: URL
    private let chinaDownloadURL: URL
    private let currentVersionProvider: () -> String?
    private let languageProvider: () -> String
    private let preferredLanguagesProvider: () -> [String]
    private let githubUpdatesDisabledProvider: () -> Bool

    init(
        session: URLSession = .shared,
        officialFeedURL: URL = UpdateChecker.defaultOfficialFeedURL,
        chinaDownloadURL: URL = UpdateChecker.defaultChinaDownloadURL,
        currentVersionProvider: @escaping () -> String? = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        },
        languageProvider: @escaping () -> String = {
            LanguageManager.shared.language
        },
        preferredLanguagesProvider: @escaping () -> [String] = {
            Locale.preferredLanguages
        },
        githubUpdatesDisabledProvider: @escaping () -> Bool = {
            ProcessInfo.processInfo.environment["APPPORTS_DISABLE_GITHUB_UPDATE_SOURCE"] == "1"
                || UserDefaults.standard.bool(forKey: "DisableGitHubUpdateSource")
        }
    ) {
        self.session = session
        self.officialFeedURL = officialFeedURL
        self.chinaDownloadURL = chinaDownloadURL
        self.currentVersionProvider = currentVersionProvider
        self.languageProvider = languageProvider
        self.preferredLanguagesProvider = preferredLanguagesProvider
        self.githubUpdatesDisabledProvider = githubUpdatesDisabledProvider
    }

    /// Background checks stay silent when no update can be offered.
    func checkForUpdates(channel: UpdateChannel = .official) async -> AppUpdateInfo? {
        if case let .available(update) = await checkForUpdatesResult(channel: channel) { return update }
        return nil
    }

    /// Manual checks distinguish a successful check from unavailable sources.
    func checkForUpdatesResult(channel: UpdateChannel = .official) async -> UpdateCheckResult {
        guard let currentVersion = normalizedVersion(currentVersionProvider() ?? "") else {
            return .failed
        }
        let outcome: SourceFetchOutcome
        switch channel {
        case .github:
            guard !githubUpdatesDisabledProvider() else { return .failed }
            outcome = await fetchGitHubUpdate(currentVersion: currentVersion)
        case .official:
            outcome = await fetchOfficialUpdate(currentVersion: currentVersion)
        }
        if let update = outcome.update { return .available(update) }
        return outcome.error == nil ? .upToDate : .failed
    }

    /// Resolve the version shown in the update sheet, rather than a possibly newer latest release.
    func githubUpdate(for update: AppUpdateInfo) async throws -> AppUpdateInfo {
        guard !githubUpdatesDisabledProvider() else { throw AppUpdateError.package }
        let tag = update.githubURL?.lastPathComponent ?? update.version
        let release = try await fetchGitHubAPIRelease(tag: tag, timeout: 30)
        guard normalizedVersion(release.tagName) == normalizedVersion(update.version),
              let asset = GitHubUpdateAsset.select(from: release.assets ?? []) else {
            throw AppUpdateError.package
        }
        return AppUpdateInfo(
            version: update.version, source: .github,
            releaseNotesMarkdown: update.releaseNotesMarkdown,
            githubURL: update.githubURL, chinaDownloadURL: update.chinaDownloadURL,
            sha256: asset.sha256, githubAsset: asset
        )
    }

    // MARK: - Source Fetching

    /// OpenList resolves a version-specific DMG to its current storage URL. Trust the
    /// checksum from the official feed, never OpenList's link signature or a filename alone.
    func domesticUpdate(for update: AppUpdateInfo) async throws -> AppUpdateInfo {
        guard let version = normalizedVersion(update.version), version == update.version else {
            throw AppUpdateError.domesticPackage
        }
        guard let hash = update.sha256?.lowercased(), hash.count == 64,
              hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw AppUpdateError.missingChecksum }
        let name = "AppPorts\(version).dmg"
        var request = URLRequest(url: URL(string: "https://file.shimoko.com/api/fs/get")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["path": "/AppPorts/" + name, "password": ""])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AppPorts-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let response: DomesticPackageResponse
        do {
            response = try await fetchJSON(DomesticPackageResponse.self, request: request, sourceName: "OpenList")
        } catch {
            if error is URLError || error is CancellationError { throw error }
            AppLogger.shared.logError("国内更新包查询失败", error: error)
            throw AppUpdateError.domesticPackage
        }
        guard response.code == 200, let file = response.data, file.name == name, !file.isDir,
              let url = URL(string: file.rawURL) else { throw AppUpdateError.domesticPackage }
        let asset = AppUpdatePackageAsset(name: name, size: file.size, downloadURL: url, sha256: hash)
        guard asset.isSupported else { throw AppUpdateError.domesticPackage }
        // Preserve the displayed notes and version; never install an implicitly newer package.
        return AppUpdateInfo(version: update.version, source: .official,
            releaseNotesMarkdown: update.releaseNotesMarkdown, githubURL: update.githubURL,
            chinaDownloadURL: update.chinaDownloadURL, sha256: hash, domesticAsset: asset)
    }

    private func fetchGitHubUpdate(currentVersion: String) async -> SourceFetchOutcome {
        do {
            let release = try await fetchGitHubRelease()
            guard let version = normalizedVersion(release.tagName) else {
                throw UpdateCheckerError.invalidResponse(source: "GitHub")
            }
            guard compareVersions(version, currentVersion) == .orderedDescending else {
                return SourceFetchOutcome(update: nil, error: nil)
            }

            let update = AppUpdateInfo(
                version: version,
                source: .github,
                releaseNotesMarkdown: release.body,
                githubURL: URL(string: release.htmlUrl),
                chinaDownloadURL: chinaDownloadURL,
                sha256: nil,
                githubAsset: GitHubUpdateAsset.select(from: release.assets ?? [])
            )
            return SourceFetchOutcome(update: update, error: nil)
        } catch {
            AppLogger.shared.logError("GitHub 更新源检查失败", error: error)
            return SourceFetchOutcome(update: nil, error: error)
        }
    }

    private func fetchOfficialUpdate(currentVersion: String) async -> SourceFetchOutcome {
        do {
            let release = try await fetchOfficialRelease()
            let versionCandidate = release.version.isEmpty ? release.tag : release.version
            guard let version = normalizedVersion(versionCandidate) else {
                throw UpdateCheckerError.invalidResponse(source: "Official")
            }
            guard compareVersions(version, currentVersion) == .orderedDescending else {
                return SourceFetchOutcome(update: nil, error: nil)
            }

            let update = AppUpdateInfo(
                version: version,
                source: .official,
                releaseNotesMarkdown: localizedReleaseNotes(from: release.releaseNotes),
                githubURL: officialGitHubURL(for: release),
                chinaDownloadURL: chinaDownloadURL,
                sha256: release.sha256.isEmpty ? nil : release.sha256
            )
            return SourceFetchOutcome(update: update, error: nil)
        } catch {
            AppLogger.shared.logError("官网更新源检查失败", error: error)
            return SourceFetchOutcome(update: nil, error: error)
        }
    }

    private func fetchGitHubRelease() async throws -> ReleaseInfo {
        do {
            return try await fetchGitHubAPIRelease()
        } catch {
            AppLogger.shared.logContext(
                "GitHub API 更新源不可用，尝试 Atom 更新源",
                details: [("error", error.localizedDescription)],
                level: "WARN"
            )
            return try await fetchGitHubAtomRelease()
        }
    }

    private func fetchGitHubAPIRelease(tag: String? = nil, timeout: TimeInterval = 3) async throws -> ReleaseInfo {
        let baseURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases")!
        let url = tag.map { baseURL.appendingPathComponent("tags").appendingPathComponent($0) }
            ?? baseURL.appendingPathComponent("latest")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.addValue("AppPorts-UpdateChecker", forHTTPHeaderField: "User-Agent")
        return try await fetchJSON(ReleaseInfo.self, request: request, sourceName: "GitHub")
    }

    private func fetchGitHubAtomRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases.atom")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.addValue("AppPorts-UpdateChecker", forHTTPHeaderField: "User-Agent")

        let data = try await fetchData(request: request, sourceName: "GitHub Atom")
        return try parseGitHubAtomRelease(data)
    }

    private func fetchOfficialRelease() async throws -> OfficialReleaseInfo {
        var request = URLRequest(url: officialFeedURL)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.addValue("AppPorts-UpdateChecker", forHTTPHeaderField: "User-Agent")
        return try await fetchJSON(OfficialReleaseInfo.self, request: request, sourceName: "Official")
    }

    private func fetchJSON<T: Decodable>(_ type: T.Type, request: URLRequest, sourceName: String) async throws -> T {
        let data = try await fetchData(request: request, sourceName: sourceName)
        return try JSONDecoder().decode(type, from: data)
    }

    private func fetchData(request: URLRequest, sourceName: String) async throws -> Data {
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await self.session.data(for: request) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(request.timeoutInterval * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw URLError(.cancelled) }
            return response
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckerError.invalidResponse(source: sourceName)
        }
        guard httpResponse.statusCode == 200 else {
            throw UpdateCheckerError.invalidStatusCode(source: sourceName, statusCode: httpResponse.statusCode)
        }
        return data
    }

    private func parseGitHubAtomRelease(_ data: Data) throws -> ReleaseInfo {
        let parser = XMLParser(data: data)
        let delegate = GitHubAtomReleaseParser()
        parser.delegate = delegate

        guard parser.parse(), let entry = delegate.firstEntry else {
            throw UpdateCheckerError.invalidResponse(source: "GitHub Atom")
        }

        return ReleaseInfo(
            tagName: entry.title,
            htmlUrl: entry.link,
            body: markdownFromGitHubHTML(entry.content)
        )
    }

    // MARK: - Selection

    private func officialGitHubURL(for release: OfficialReleaseInfo) -> URL? {
        if let url = URL(string: release.links.github), !release.links.github.isEmpty {
            return url
        }

        let rawTag = release.tag.isEmpty ? release.version : release.tag
        guard let tag = normalizedVersion(rawTag) else { return nil }
        return URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/tag/\(tag)")
    }

    // MARK: - Release Notes Language

    private func localizedReleaseNotes(from releaseNotes: [String: String]) -> String {
        let candidates = releaseNoteLanguageCandidates()
        for candidate in candidates {
            if let notes = releaseNotes[candidate], !notes.isEmpty {
                return notes
            }
        }

        if let fallback = releaseNotes["zh-Hans"], !fallback.isEmpty {
            return fallback
        }
        if let fallback = releaseNotes["en"], !fallback.isEmpty {
            return fallback
        }
        return releaseNotes.values.first(where: { !$0.isEmpty }) ?? ""
    }

    private func releaseNoteLanguageCandidates() -> [String] {
        let selectedLanguage = languageProvider()
        let rawLanguages: [String]
        if selectedLanguage == "system" {
            rawLanguages = preferredLanguagesProvider()
        } else {
            rawLanguages = [selectedLanguage]
        }

        var result: [String] = []
        for rawLanguage in rawLanguages {
            for candidate in normalizedLanguageCandidates(for: rawLanguage) where !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    private func normalizedLanguageCandidates(for rawLanguage: String) -> [String] {
        let normalized = rawLanguage.replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return [] }

        var candidates = [normalized]
        let lowercased = normalized.lowercased()
        if lowercased.hasPrefix("zh-hant")
            || lowercased.hasPrefix("zh-tw")
            || lowercased.hasPrefix("zh-hk")
            || lowercased.hasPrefix("zh-mo") {
            candidates.append("zh-Hant")
        } else if lowercased.hasPrefix("zh") {
            candidates.append("zh-Hans")
        }

        if let languageCode = normalized.split(separator: "-").first.map(String.init),
           languageCode != normalized {
            candidates.append(languageCode)
        }
        return candidates
    }

    // MARK: - Version Comparison

    private func normalizedVersion(_ value: String) -> String? {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasPrefix("v") {
            result.removeFirst()
        }
        guard !result.isEmpty, parseVersion(result) != nil else { return nil }
        return result
    }

    private func compareVersions(_ firstVersion: String, _ secondVersion: String) -> ComparisonResult {
        guard let firstComponents = parseVersion(firstVersion),
              let secondComponents = parseVersion(secondVersion) else {
            return firstVersion.compare(secondVersion, options: .numeric)
        }

        let count = max(firstComponents.count, secondComponents.count)
        for index in 0..<count {
            let first = index < firstComponents.count ? firstComponents[index] : 0
            let second = index < secondComponents.count ? secondComponents[index] : 0

            if first > second { return .orderedDescending }
            if first < second { return .orderedAscending }
        }
        return .orderedSame
    }

    private func parseVersion(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    private func markdownFromGitHubHTML(_ html: String) -> String {
        var text = replaceHTMLLinks(in: html)
        let replacements: [(pattern: String, value: String)] = [
            (#"(?i)<h1[^>]*>"#, "\n# "),
            (#"(?i)</h1>"#, "\n\n"),
            (#"(?i)<h2[^>]*>"#, "\n## "),
            (#"(?i)</h2>"#, "\n\n"),
            (#"(?i)<h3[^>]*>"#, "\n### "),
            (#"(?i)</h3>"#, "\n\n"),
            (#"(?i)<p[^>]*>"#, ""),
            (#"(?i)</p>"#, "\n\n"),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)<li[^>]*>"#, "- "),
            (#"(?i)</li>"#, "\n"),
            (#"(?i)<strong[^>]*>"#, "**"),
            (#"(?i)</strong>"#, "**"),
            (#"(?i)<b[^>]*>"#, "**"),
            (#"(?i)</b>"#, "**"),
            (#"(?i)<em[^>]*>"#, "*"),
            (#"(?i)</em>"#, "*"),
            (#"(?i)<i[^>]*>"#, "*"),
            (#"(?i)</i>"#, "*"),
            (#"(?i)<code[^>]*>"#, "`"),
            (#"(?i)</code>"#, "`"),
            (#"(?i)<pre[^>]*>"#, "\n```text\n"),
            (#"(?i)</pre>"#, "\n```\n\n"),
            (#"(?i)<div[^>]*>"#, "\n"),
            (#"(?i)</div>"#, "\n")
        ]

        for replacement in replacements {
            text = text.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.value,
                options: .regularExpression
            )
        }

        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replaceHTMLLinks(in html: String) -> String {
        let pattern = #"<a\s+[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return html
        }

        var result = html
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, range: range)

        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let hrefRange = Range(match.range(at: 1), in: result),
                  let textRange = Range(match.range(at: 2), in: result) else {
                continue
            }

            let href = String(result[hrefRange])
            let linkText = String(result[textRange])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            result.replaceSubrange(fullRange, with: "[\(linkText)](\(href))")
        }

        return result
    }
}

private struct DomesticPackageResponse: Decodable {
    let code: Int
    let data: File?

    struct File: Decodable {
        let name: String
        let size: Int64
        let isDir: Bool
        let rawURL: String

        enum CodingKeys: String, CodingKey {
            case name, size
            case isDir = "is_dir"
            case rawURL = "raw_url"
        }
    }
}

private struct SourceFetchOutcome {
    let update: AppUpdateInfo?
    let error: Error?
}

private struct GitHubAtomEntry {
    var title = ""
    var link = ""
    var content = ""
}

private final class GitHubAtomReleaseParser: NSObject, XMLParserDelegate {
    private(set) var firstEntry: GitHubAtomEntry?
    private var currentEntry: GitHubAtomEntry?
    private var currentElement: String?
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard firstEntry == nil else { return }

        switch elementName {
        case "entry":
            currentEntry = GitHubAtomEntry()
        case "title", "content":
            guard currentEntry != nil else { return }
            currentElement = elementName
            currentText = ""
        case "link":
            guard currentEntry != nil,
                  attributeDict["rel"] == "alternate",
                  let href = attributeDict["href"] else { return }
            currentEntry?.link = href
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard firstEntry == nil else { return }

        if elementName == currentElement {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if elementName == "title" {
                currentEntry?.title = value
            } else if elementName == "content" {
                currentEntry?.content = value
            }
            currentElement = nil
            currentText = ""
            return
        }

        if elementName == "entry", let entry = currentEntry {
            firstEntry = entry
            currentEntry = nil
        }
    }
}

private enum UpdateCheckerError: LocalizedError {
    case invalidResponse(source: String)
    case invalidStatusCode(source: String, statusCode: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(source):
            return "\(source) update source returned an invalid response"
        case let .invalidStatusCode(source, statusCode):
            return "\(source) update source returned HTTP \(statusCode)"
        }
    }
}
