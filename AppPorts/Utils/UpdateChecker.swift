//
//  UpdateChecker.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation
import AppKit

// MARK: - 数据模型

/// GitHub Release 信息
///
/// 从 GitHub API 获取的发布版本信息
struct ReleaseInfo: Codable {
    /// 版本标签（如 "v1.0.0"）
    let tagName: String
    
    /// Release 页面的 URL
    let htmlUrl: String
    
    /// Release 说明（Markdown 格式）
    let body: String
    
    /// 自定义 JSON 键映射
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
    }
}

// MARK: - 更新检查器

/// 应用更新检查工具
///
/// 通过 GitHub API 检查应用是否有新版本发布。
/// 比较当前应用版本和 GitHub 最新 Release 版本，提示用户更新。
///
/// ## 使用示例
/// ```swift
/// Task {
///     if let release = try? await UpdateChecker.shared.checkForUpdates() {
///         print("发现新版本: \(release.tagName)")
///         print("下载地址: \(release.htmlUrl)")
///     } else {
///         print("已是最新版本")
///     }
/// }
/// ```
///
/// - Note: 使用异步 API，不会阻塞主线程
class UpdateChecker {
    /// 单例实例
    static let shared = UpdateChecker()
    
    // MARK: - 配置
    
    /// GitHub 仓库所有者
    private let repoOwner = "wzh4869"
    
    /// GitHub 仓库名称
    private let repoName = "AppPorts"
    
    // MARK: - 初始化
    
    /// 私有初始化（单例模式）
    private init() {}
    
    // MARK: - 公共 API
    
    /// 检查是否有应用更新
    ///
    /// 向 GitHub API 发起请求，获取最新的 Release 信息，
    /// 并与当前应用版本进行比较。
    ///
    /// - Returns: 
    ///   - 如果有新版本：返回 `ReleaseInfo` 对象
    ///   - 如果已是最新版本：返回 `nil`
    ///
    /// - Throws: 网络错误或 JSON 解析错误
    ///
    /// - Note: 请求超时设置为 10 秒
    func checkForUpdates() async throws -> ReleaseInfo? {
        // 构建 GitHub API URL
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }
        
        // 配置请求
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // 设置 User-Agent（GitHub API 最佳实践）
        request.addValue("AppPorts-UpdateChecker", forHTTPHeaderField: "User-Agent")
        
        // 发起网络请求
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // 验证 HTTP 响应
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "UpdateChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: "GitHub API 响应无效"])
        }
        
        // 解析 JSON
        let release = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        
        // 版本比较
        if isNewer(tagName: release.tagName) {
            return release
        }
        
        return nil
    }
    
    // MARK: - 私有辅助方法
    
    /// 判断远程版本是否比当前版本新
    ///
    /// - Parameter tagName: GitHub Release 的标签名（如 "v1.2.3" 或 "1.2.3"）
    /// - Returns: 如果远程版本更新则返回 true
    private func isNewer(tagName: String) -> Bool {
        // 去除版本号前缀 "v"
        let versionString = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        
        // 获取当前应用版本
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return false }
        
        // 比较版本号
        return compareVersions(versionString, currentVersion) == .orderedDescending
    }
    
    /// 比较两个版本号字符串
    ///
    /// 版本号格式：`major.minor.patch`（如 "1.2.3"）
    ///
    /// - Parameters:
    ///   - v1: 第一个版本号
    ///   - v2: 第二个版本号
    /// - Returns: 
    ///   - `.orderedAscending`: v1 < v2
    ///   - `.orderedSame`: v1 == v2  
    ///   - `.orderedDescending`: v1 > v2
    ///
    /// ## 比较逻辑
    /// 逐段比较版本号（major、minor、patch）：
    /// - 如果任一段数字不同，直接返回结果
    /// - 缺失的段视为 0（如 "1.2" 等同于 "1.2.0"）
    ///
    /// - Example:
    ///   ```swift
    ///   compareVersions("1.2.3", "1.2.0")  // .orderedDescending
    ///   compareVersions("1.2", "1.2.0")    // .orderedSame
    ///   ```
    private func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        // 分割版本号为数字数组
        let components1 = v1.split(separator: ".").compactMap { Int($0) }
        let components2 = v2.split(separator: ".").compactMap { Int($0) }
        
        // 取两者中较长的段数
        let count = max(components1.count, components2.count)
        
        // 逐段比较
        for i in 0..<count {
            let num1 = i < components1.count ? components1[i] : 0
            let num2 = i < components2.count ? components2[i] : 0
            
            if num1 > num2 { return .orderedDescending }
            if num1 < num2 { return .orderedAscending }
        }
        
        return .orderedSame
    }
}
