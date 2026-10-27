//
//  AboutView.swift
//  AppPorts
//
//  Created by shimoko.com on 2025/11/19.
//

import Combine
import SwiftUI

// MARK: - 贡献者数据

/// 项目贡献者信息
struct Contributor: Identifiable, Codable, Equatable {
    let name: String
    let github: String
    let url: String
    let avatarURL: String?

    var id: String { github }
    var profileURL: URL? { URL(string: url) }

    init(name: String, github: String, url: String? = nil, avatarURL: String? = nil) {
        self.name = name
        self.github = github
        self.url = url ?? "https://github.com/\(github)"
        self.avatarURL = avatarURL
    }
}

private let fallbackContributors: [Contributor] = [
    Contributor(name: "wzh4869", github: "wzh4869"),
    Contributor(name: "sulimu2", github: "sulimu2"),
    Contributor(name: "2han9wen71an", github: "2han9wen71an"),
]

private struct GitHubContributorResponse: Decodable {
    let login: String
    let htmlURL: String
    let avatarURL: String

    enum CodingKeys: String, CodingKey {
        case login
        case htmlURL = "html_url"
        case avatarURL = "avatar_url"
    }
}

private struct ContributorsCache: Codable {
    let contributors: [Contributor]
}

private struct ContributorsService {
    private let fileManager = FileManager.default
    private let endpoint = URL(string: "https://api.github.com/repos/wzh4869/AppPorts/contributors?per_page=100")!

    func loadCachedContributors() -> [Contributor]? {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(ContributorsCache.self, from: data),
              !cache.contributors.isEmpty else {
            return nil
        }
        return cache.contributors
    }

    func saveContributorsToCache(_ contributors: [Contributor]) {
        guard let cacheURL, !contributors.isEmpty else { return }

        do {
            let parentURL = cacheURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            let cache = ContributorsCache(contributors: contributors)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            AppLogger.shared.logError(
                "保存贡献者缓存失败",
                error: error,
                errorCode: "ABOUT-CONTRIBUTORS-CACHE-WRITE-FAILED"
            )
        }
    }

    func fetchContributors() async throws -> [Contributor] {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AppPorts", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "AppPorts.AboutView",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub API returned status \(httpResponse.statusCode)"]
            )
        }

        let payload = try JSONDecoder().decode([GitHubContributorResponse].self, from: data)
        return payload.map {
            Contributor(
                name: $0.login,
                github: $0.login,
                url: $0.htmlURL,
                avatarURL: $0.avatarURL
            )
        }
    }

    private var cacheURL: URL? {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportURL
            .appendingPathComponent("AppPorts", isDirectory: true)
            .appendingPathComponent("contributors-cache.json")
    }
}

@MainActor
private final class ContributorsViewModel: ObservableObject {
    @Published private(set) var contributors: [Contributor] = fallbackContributors

    private let service = ContributorsService()
    private var hasLoaded = false

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let cachedContributors = service.loadCachedContributors() {
            contributors = cachedContributors
        }

        Task {
            do {
                let fetchedContributors = try await service.fetchContributors()
                guard !fetchedContributors.isEmpty else { return }
                contributors = fetchedContributors
                service.saveContributorsToCache(fetchedContributors)
            } catch {
                AppLogger.shared.logError(
                    "加载 GitHub 贡献者失败，已回退到缓存或内置列表",
                    error: error,
                    errorCode: "ABOUT-CONTRIBUTORS-FETCH-FAILED"
                )
            }
        }
    }
}

// MARK: - 赞助者数据

/// 项目赞助者信息。
///
/// 数据来源为仓库根目录的 `sponsors.json`（文档站点会提供同一份数据）。
/// `amount` 仅用于排序，不在 App 内展示。
struct Sponsor: Identifiable, Codable, Equatable {
    let name: String
    let link: String
    let amount: Double
    let date: String

    var id: String { link.isEmpty ? name : link }
    var profileURL: URL? {
        let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    init(name: String, link: String, amount: Double = 0, date: String = "") {
        self.name = name
        self.link = link
        self.amount = amount
        self.date = date
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case link
        case amount
        case date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        link = try container.decodeIfPresent(String.self, forKey: .link) ?? ""
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
    }
}

private extension Array where Element == Sponsor {
    /// 赞助金额从高到低；金额相同时按赞助时间从早到晚
    func rankedBySponsorship() -> [Sponsor] {
        sorted { lhs, rhs in
            if lhs.amount != rhs.amount {
                return lhs.amount > rhs.amount
            }
            return lhs.date < rhs.date
        }
    }
}

struct SponsorsPayload: Codable {
    let updatedAt: String?
    let sponsors: [Sponsor]
}

struct SponsorsService {
    private let fileManager = FileManager.default
    private let endpoint = URL(string: "https://docs-appports.shimoko.com/sponsors.json")!
    private let session: URLSession
    private let cacheURL: URL?

    init(session: URLSession = .shared, cacheURL: URL? = SponsorsService.defaultCacheURL) {
        self.session = session
        self.cacheURL = cacheURL
    }

    /// 线上是权威来源（包括空名单）；只有请求或解析失败才依次使用缓存、包内名单。
    func loadSponsors() async -> SponsorsPayload? {
        do {
            let payload = try await fetchSponsors()
            saveSponsorsToCache(payload)
            return payload
        } catch {
            AppLogger.shared.logError(
                "加载赞助者列表失败，已回退到缓存或内置列表",
                error: error,
                errorCode: "ABOUT-SPONSORS-FETCH-FAILED"
            )
            return loadCachedSponsors() ?? loadBundledSponsors()
        }
    }

    func loadBundledSponsors(bundle: Bundle = .main) -> SponsorsPayload? {
        guard let url = bundle.url(forResource: "sponsors", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SponsorsPayload.self, from: data)
    }

    func loadCachedSponsors() -> SponsorsPayload? {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(SponsorsPayload.self, from: data) else {
            return nil
        }
        return cache
    }

    func saveSponsorsToCache(_ payload: SponsorsPayload) {
        guard let cacheURL else { return }

        do {
            let parentURL = cacheURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            AppLogger.shared.logError(
                "保存赞助者缓存失败",
                error: error,
                errorCode: "ABOUT-SPONSORS-CACHE-WRITE-FAILED"
            )
        }
    }

    func fetchSponsors() async throws -> SponsorsPayload {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AppPorts", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "AppPorts.AboutView",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Sponsors endpoint returned status \(httpResponse.statusCode)"]
            )
        }

        return try JSONDecoder().decode(SponsorsPayload.self, from: data)
    }

    private static var defaultCacheURL: URL? {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportURL
            .appendingPathComponent("AppPorts", isDirectory: true)
            .appendingPathComponent("sponsors-cache.json")
    }
}

@MainActor
private final class SponsorsViewModel: ObservableObject {
    @Published private(set) var sponsors: [Sponsor] = []
    @Published private(set) var isLoading = true

    private let service = SponsorsService()
    private var hasLoaded = false

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true

        Task {
            let payload = await service.loadSponsors()
            sponsors = payload?.sponsors.rankedBySponsorship() ?? []
            isLoading = false
        }
    }
}

// MARK: - 关于窗口

/// A separate, reusable window also works when the main window is closed (macOS 12+).
@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()
    private var languageObserver: AnyCancellable?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 480)
        window.contentView = NSHostingView(rootView: AboutWindowContent())
        window.title = "关于 AppPorts...".localized.replacingOccurrences(of: "...", with: "")
        window.center()
        languageObserver = LanguageManager.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak window] _ in
                window?.title = "关于 AppPorts...".localized.replacingOccurrences(of: "...", with: "")
            }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutWindowContent: View {
    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some View {
        AboutView()
            .environment(\.locale, languageManager.locale)
    }
}

struct AboutView: View {
    @StateObject private var contributorsViewModel = ContributorsViewModel()
    @StateObject private var sponsorsViewModel = SponsorsViewModel()
    @ObservedObject private var languageManager = LanguageManager.shared

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String(format: "Version %@".localized, "\(version) (\(build))")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 20) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "AppPorts").font(.largeTitle.bold())
                        Text("macOS 应用迁移工具".localized).font(.headline).foregroundStyle(.secondary)
                        Text(version).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 8)

                Divider()
                AboutSection(title: "项目".localized) {
                    Text("将应用和数据迁移到外部存储，保留本地入口，释放磁盘空间。".localized)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 9) {
                        AboutLinkRow(label: "项目地址".localized, title: "GitHub 上的 AppPorts".localized, url: "https://github.com/wzh4869/AppPorts")
                        AboutLinkRow(label: "官方网站".localized, title: "appports.shimoko.com", url: "https://appports.shimoko.com/")
                        AboutLinkRow(label: "用户文档".localized, title: "docs-appports.shimoko.com", url: "https://docs-appports.shimoko.com/")
                        AboutLinkRow(label: "发布".localized, title: "GitHub Releases", url: "https://github.com/wzh4869/AppPorts/releases")
                    }
                }

                Divider()
                AboutSection(title: "项目贡献者".localized) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(contributorsViewModel.contributors) { contributor in
                            if let url = contributor.profileURL {
                                Link(destination: url) { Text(verbatim: contributor.name) }
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Divider()
                AboutSection(title: "赞助者".localized) {
                    if sponsorsViewModel.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(sponsorsViewModel.sponsors) { sponsor in
                            if let url = sponsor.profileURL {
                                Link(destination: url) { Text(verbatim: sponsor.name) }
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(verbatim: sponsor.name)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Link(destination: URL(string: "https://docs-appports.shimoko.com/sponsor.html")!) {
                        Text("赞助 AppPorts".localized)
                    }
                }

                Divider()
                AboutSection(title: "版权与许可".localized) {
                    Text(verbatim: "© 2025–2026 shimoko.com")
                        .foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://github.com/wzh4869/AppPorts/blob/main/LICENSE")!) {
                        Text(verbatim: "Apache License 2.0")
                    }
                    Link(destination: URL(string: "https://docs-appports.shimoko.com/docs/licenses")!) {
                        Text("开放源代码许可证".localized)
                    }
                    Link(destination: URL(string: "https://docs-appports.shimoko.com/docs/privacy")!) {
                        Text("隐私政策".localized)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { contributorsViewModel.loadIfNeeded() }
        .task { sponsorsViewModel.loadIfNeeded() }
    }
}

private struct AboutSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AboutLinkRow: View {
    let label: String
    let title: String
    let url: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Link(destination: URL(string: url)!) { Text(verbatim: title) }
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView().frame(width: 640, height: 760)
    }
}
