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
    var resolvedAvatarURL: URL? { avatarURL.flatMap(URL.init(string:)) }
    var showsSeparateNameLine: Bool { name != github }

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

// MARK: - 关于界面

/// 应用的"关于"弹窗界面
///
/// 展示应用的基本信息和相关链接：
/// - 🖼 应用图标和名称
/// - 📌 当前版本号
/// - 💬 感谢文案
/// - 👥 项目贡献者列表
/// - 🔗 官方网站与 GitHub 项目链接
///
/// ## 界面尺寸
/// 固定尺寸：440 x 660 点
///
/// ## 使用方式
/// 通过应用菜单栏的"关于"选项打开此弹窗
///
/// - Note: 使用 SwiftUI Environment 的 dismiss 关闭弹窗
struct AboutView: View {
    /// 环境变量：用于关闭弹窗
    @Environment(\.dismiss) var dismiss
    @StateObject private var contributorsViewModel = ContributorsViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            
            // 1. LOGO 区域
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
            .padding(.top, 32)
            .padding(.bottom, 10)
            
            // 2. 文字信息
            VStack(spacing: 6) {
                Text("AppPorts".localized)
                    .font(.system(size: 22, weight: .bold))
                    .fontWeight(.bold)
                
                Text(String(format: "Version %@".localized, Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)
            
            // 3. 描述文案
            Text("感谢你使用本工具，外置硬盘拯救世界！".localized)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary.opacity(0.9))
                .padding(.horizontal, 12)
            
            // 4. 贡献者区域
            VStack(alignment: .leading, spacing: 12) {
                Text("项目贡献者".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(contributorsViewModel.contributors) { contributor in
                            ContributorButton(contributor: contributor)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 150, maxHeight: 220)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.primary.opacity(0.04))
            )
            .padding(.horizontal, 24)
            .padding(.top, 4)
            
            // 5. 官方链接
            VStack(spacing: 10) {
                LinkButton(
                    title: "官方网站".localized,
                    icon: "globe",
                    url: "https://appports.shimoko.com/"
                )

                LinkButton(
                    title: "项目地址".localized,
                    icon: "terminal.fill",
                    url: "https://github.com/wzh4869/AppPorts"
                )
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            // 6. 关闭按钮
            Button("关闭".localized) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 30)
            
        }
        .padding(30)
        .frame(width: 440, height: 660)
        .task {
            contributorsViewModel.loadIfNeeded()
        }
    }
}

// MARK: - 贡献者按钮组件

/// 贡献者链接按钮
struct ContributorButton: View {
    let contributor: Contributor
    @State private var isHovering = false
    
    var body: some View {
        if let profileURL = contributor.profileURL {
            Link(destination: profileURL) {
                contributorContent
            }
            .buttonStyle(.plain)
            .onHover { hover in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovering = hover
                }
            }
        }
    }

    private var contributorContent: some View {
        HStack(spacing: 12) {
            avatarView

            VStack(alignment: .leading, spacing: 2) {
                Text(contributor.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if contributor.showsSeparateNameLine {
                    Text("@\(contributor.github)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Image(systemName: "arrow.up.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .foregroundColor(.primary)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.10 : 0.04), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var avatarView: some View {
        AsyncImage(url: contributor.resolvedAvatarURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.accentColor)
                    .padding(3)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }
}

// MARK: - 链接按钮组件

/// 外部链接按钮组件
///
/// 带有图标和悬停效果的链接按钮，用于跳转到外部网页。
///
/// ## 设计特点
/// - 左侧：图标
/// - 中间：链接文本
/// - 右侧：外部链接箭头
/// - 悬停时：背景颜色加深
///
/// - Note: 使用 SwiftUI Link 组件，点击自动在浏览器打开
struct LinkButton: View {
    /// 按钮显示文本（本地化字符串键）
    let title: String
    
    /// SF Symbols 图标名称
    let icon: String
    
    /// 跳转的目标 URL
    let url: String
    
    /// 是否处于悬停状态
    @State private var isHovering = false
    
    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                
                Text(title)
                    .font(.body.weight(.medium))
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .opacity(0.5)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .foregroundColor(.primary)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.10 : 0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hover
            }
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
