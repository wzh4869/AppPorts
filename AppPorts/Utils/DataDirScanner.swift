//
//  DataDirScanner.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/3/4.
//

import Foundation

// MARK: - 已知 dotFolder 描述结构

/// 内置已知工具目录的描述信息
private struct KnownDotFolder {
    let name: String
    let relativePath: String       // 相对于 ~ 的路径，如 ".npm" 或 ".cache/torch"
    let priority: DataDirPriority
    let description: String
    let isMigratable: Bool
    let nonMigratableReason: String?

    init(name: String, relativePath: String,
         priority: DataDirPriority = .recommended,
         description: String,
         isMigratable: Bool = true,
         nonMigratableReason: String? = nil) {
        self.name = name
        self.relativePath = relativePath
        self.priority = priority
        self.description = description
        self.isMigratable = isMigratable
        self.nonMigratableReason = nonMigratableReason
    }
}

// MARK: - 数据目录扫描器

/// 扫描应用关联数据目录和已知工具 dotFolder
///
/// 使用 Actor 模型在后台线程安全地执行扫描，不阻塞 UI。
///
/// ## 功能
/// 1. 根据 AppItem（BundleID + AppName）扫描 ~/Library/ 关联目录
/// 2. 扫描内置已知 dotFolder 列表（~/.npm、~/.m2 等）
/// 3. 检测每个目录当前状态（本地 / 已链接 / 现有软链 / 未找到）
///
/// ## 使用示例
/// ```swift
/// let scanner = DataDirScanner()
/// // 扫描工具目录
/// let dotItems = await scanner.scanKnownDotFolders()
/// // 扫描应用关联目录
/// let libItems = await scanner.scanLibraryDirs(for: someApp)
/// ```
actor DataDirScanner {

    private let fileManager = FileManager.default
    private let homeDir = URL(fileURLWithPath: NSHomeDirectory())
    private var historicalManagedLinksCache: Set<String>? = nil
    private let managedLinkMarkerFileName = ".appports-link-metadata.plist"
    private let managedLinkIdentifier = "com.shimoko.AppPorts"
    private let managedLinkSchemaVersion = 1

    private struct ManagedLinkMetadata: Codable, Sendable {
        let schemaVersion: Int
        let managedBy: String
        let sourcePath: String
        let destinationPath: String
        let dataDirType: String
    }

    // MARK: - 内置已知 dotFolder 列表

    private let knownDotFolders: [KnownDotFolder] = [
        // ── 开发工具 / 包管理 ────────────────────────────────────
        KnownDotFolder(
            name: "npm 缓存",
            relativePath: ".npm",
            priority: .recommended,
            description: "Node.js 包管理器本地缓存"
        ),
        KnownDotFolder(
            name: "Maven 仓库",
            relativePath: ".m2",
            priority: .recommended,
            description: "Java Maven 依赖仓库"
        ),
        KnownDotFolder(
            name: "Bun 运行时",
            relativePath: ".bun",
            priority: .recommended,
            description: "Bun JavaScript 运行时及缓存"
        ),
        KnownDotFolder(
            name: "Conda 环境",
            relativePath: ".conda",
            priority: .recommended,
            description: "Anaconda/Miniconda 环境数据"
        ),
        KnownDotFolder(
            name: "Nexus 数据",
            relativePath: ".nexus",
            priority: .optional,
            description: "Nexus 代理缓存"
        ),
        KnownDotFolder(
            name: "Composer 包",
            relativePath: ".composer",
            priority: .optional,
            description: "PHP Composer 全局包"
        ),

        // ── AI / ML 工具 ─────────────────────────────────────────
        KnownDotFolder(
            name: "Ollama 模型",
            relativePath: ".ollama",
            priority: .recommended,
            description: "Ollama 本地大语言模型存储"
        ),
        KnownDotFolder(
            name: "PyTorch 模型缓存",
            relativePath: ".cache/torch",
            priority: .recommended,
            description: "PyTorch 预训练模型权重缓存"
        ),
        KnownDotFolder(
            name: "Whisper 语音模型",
            relativePath: ".cache/whisper",
            priority: .recommended,
            description: "OpenAI Whisper 语音识别模型"
        ),
        KnownDotFolder(
            name: "Keras 数据",
            relativePath: ".keras",
            priority: .optional,
            description: "Keras 模型和数据集"
        ),

        // ── AI 编程助手 ──────────────────────────────────────────
        KnownDotFolder(
            name: "灵码（Lingma）数据",
            relativePath: ".lingma",
            priority: .optional,
            description: "阿里云灵码 AI 编程助手数据"
        ),
        KnownDotFolder(
            name: "Trae IDE 数据",
            relativePath: ".trae",
            priority: .optional,
            description: "字节跳动 Trae IDE 运行数据"
        ),
        KnownDotFolder(
            name: "Trae CN 数据",
            relativePath: ".trae-cn",
            priority: .optional,
            description: "字节跳动 Trae IDE 国内版数据"
        ),
        KnownDotFolder(
            name: "Trae AICC 数据",
            relativePath: ".trae-aicc",
            priority: .optional,
            description: "字节跳动 Trae AICC 数据"
        ),
        KnownDotFolder(
            name: "MarsCode 数据",
            relativePath: ".marscode",
            priority: .optional,
            description: "字节跳动 MarsCode IDE 数据"
        ),
        KnownDotFolder(
            name: "CodeBuddy 数据",
            relativePath: ".codebuddy",
            priority: .optional,
            description: "腾讯 CodeBuddy AI 助手数据"
        ),
        KnownDotFolder(
            name: "CodeBuddy CN 数据",
            relativePath: ".codebuddycn",
            priority: .optional,
            description: "腾讯 CodeBuddy 国内版数据"
        ),
        KnownDotFolder(
            name: "Qwen 数据",
            relativePath: ".qwen",
            priority: .optional,
            description: "阿里通义千问相关数据"
        ),
        KnownDotFolder(
            name: "ClawBOT 数据",
            relativePath: ".clawdbot",
            priority: .optional,
            description: "ClawdBOT AI 工具数据"
        ),

        // ── 浏览器 / 测试自动化 ───────────────────────────────────
        KnownDotFolder(
            name: "Selenium 浏览器",
            relativePath: ".cache/selenium",
            priority: .optional,
            description: "Selenium 自动下载的浏览器驱动"
        ),
        KnownDotFolder(
            name: "Chromium 快照",
            relativePath: ".chromium-browser-snapshots",
            priority: .optional,
            description: "Playwright/Selenium 使用的 Chromium 浏览器快照"
        ),
        KnownDotFolder(
            name: "WDM 浏览器驱动",
            relativePath: ".wdm",
            priority: .optional,
            description: "WebDriver Manager 下载的驱动程序"
        ),

        // ── 编辑器 / IDE ─────────────────────────────────────────
        KnownDotFolder(
            name: "VSCode 数据",
            relativePath: ".vscode",
            priority: .optional,
            description: "Visual Studio Code 扩展及配置"
        ),
        KnownDotFolder(
            name: "Cursor 数据",
            relativePath: ".cursor",
            priority: .optional,
            description: "Cursor AI 编辑器数据"
        ),
        KnownDotFolder(
            name: "STS4 数据",
            relativePath: ".sts4",
            priority: .optional,
            description: "Spring Tool Suite 4 数据"
        ),

        // ── 运行时环境 ────────────────────────────────────────────
        KnownDotFolder(
            name: "Docker CLI 配置",
            relativePath: ".docker",
            priority: .optional,
            description: "Docker Desktop CLI 配置和上下文"
        ),
        KnownDotFolder(
            name: "OpenClaw 数据",
            relativePath: ".openclaw",
            priority: .optional,
            description: "OpenClaw 工具数据"
        ),
        KnownDotFolder(
            name: "Python NLTK 数据",
            relativePath: "nltk_data",
            priority: .optional,
            description: "自然语言处理 NLTK 语料库"
        ),

        // ── 不可整体迁移（危险目录，只展示）────────────────────────
        KnownDotFolder(
            name: ".local（系统工具）",
            relativePath: ".local",
            priority: .critical,
            description: "Python pip 等工具的用户级安装目录，内部结构复杂",
            isMigratable: false,
            nonMigratableReason: "该目录包含可执行文件路径引用，整体迁移可能导致命令行工具失效"
        ),
        KnownDotFolder(
            name: ".config（工具配置）",
            relativePath: ".config",
            priority: .critical,
            description: "多个命令行工具的配置目录，包含硬编码路径",
            isMigratable: false,
            nonMigratableReason: "该目录包含绝对路径配置，整体迁移可能导致工具配置失效"
        ),
    ]

    // MARK: - 公共 API

    /// 扫描所有内置已知 dotFolder
    ///
    /// 过滤掉不存在的目录，检测每个目录的链接状态。
    ///
    /// - Returns: 存在于磁盘上的已知 dotFolder 列表（未计算大小）
    func scanKnownDotFolders() -> [DataDirItem] {
        var results: [DataDirItem] = []

        for known in knownDotFolders {
            let fullPath = homeDir.appendingPathComponent(known.relativePath)

            // 跳过不存在的目录
            guard fileManager.fileExists(atPath: fullPath.path) else { continue }

            let inspection = inspectItem(at: fullPath, type: .dotFolder)

            var item = DataDirItem(
                name: known.name.localized,
                path: fullPath,
                type: .dotFolder,
                priority: known.priority,
                description: known.description.localized,
                isMigratable: known.isMigratable,
                nonMigratableReason: known.nonMigratableReason?.localized
            )
            item.status = inspection.status
            item.linkedDestination = inspection.linkedDestination

            results.append(item)
        }

        return results.sorted { $0.priority < $1.priority }
    }

    /// 扫描指定应用的关联数据目录
    ///
    /// 默认会在 `~/Library/` 标准子目录中查找，同时为少数特殊安装方式补充额外目录。
    ///
    /// - Parameter app: 要查找关联数据的应用
    /// - Returns: 找到的关联数据目录列表（未计算大小）
    func scanLibraryDirs(for app: AppItem) -> [DataDirItem] {
        guard !app.isFolder else { return [] }

        // 从 Info.plist 读取 BundleID
        let bundleID = readBundleID(from: app.path)
        let appName = app.name.replacingOccurrences(of: ".app", with: "")

        var results: [DataDirItem] = []

        // 需要搜索的目录配置
        let searchConfigs: [(baseRelative: String, type: DataDirType, priority: DataDirPriority, desc: String)] = [
            ("Library/Application Support", .applicationSupport, .critical,    "应用核心数据（设置、数据库等）"),
            ("Library/Containers",          .containers,         .critical,    "沙盒容器数据（App Store 应用）"),
            ("Library/Group Containers",    .groupContainers,    .recommended, "应用组共享数据"),
            ("Library/Caches",              .caches,             .optional,    "应用缓存（可重建）"),
            ("Library/Saved Application State", .savedState,     .optional,    "窗口状态恢复数据"),
        ]

        for config in searchConfigs {
            let baseURL = homeDir.appendingPathComponent(config.baseRelative)
            let candidates = findMatchingDirs(in: baseURL, bundleID: bundleID, appName: appName)

            for candidateURL in candidates {
                let inspection = inspectItem(at: candidateURL, type: config.type)

                var item = DataDirItem(
                    name: "\(config.type.rawValue.localized): \(candidateURL.lastPathComponent)",
                    path: candidateURL,
                    type: config.type,
                    priority: config.priority,
                    description: config.desc.localized,
                    isMigratable: true
                )
                item.associatedAppName = appName
                item.status = inspection.status
                item.linkedDestination = inspection.linkedDestination

                results.append(item)
            }
        }

        results.append(contentsOf: scanSpecialAssociatedDirs(for: app, bundleID: bundleID, appName: appName))

        return deduplicate(items: results).sorted { $0.priority < $1.priority }
    }

    /// 异步计算单个目录大小
    ///
    /// - Parameter item: 要计算大小的目录项
    /// - Returns: 大小（字节）
    func calculateSize(for item: DataDirItem) -> Int64 {
        // 如果是已链接状态，我们需要计算链接目标（外部存储）的大小
        let scanURL = item.linkedDestination ?? item.path
        
        guard fileManager.fileExists(atPath: scanURL.path) else { return 0 }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        
        // 如果起始路径本身就是符号链接（且没被 linkedDestination 覆盖），enumerator 会自动处理
        guard let enumerator = fileManager.enumerator(
            at: scanURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: nil
        ) else { return 0 }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == managedLinkMarkerFileName {
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true, let fileSize = values.fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }

    // MARK: - 私有辅助方法

    /// 补充少数“入口 app 与真实安装根目录分离”的应用目录。
    ///
    /// 当前主要覆盖 Conda 发行版：
    /// `/Applications/Anaconda-Navigator.app -> /opt/anaconda3/Anaconda-Navigator.app`
    private func scanSpecialAssociatedDirs(for app: AppItem, bundleID: String?, appName: String) -> [DataDirItem] {
        guard isCondaDistribution(bundleID: bundleID, appName: appName) else { return [] }

        var results: [DataDirItem] = []
        let installRootCandidates = condaInstallRootCandidates(for: app)

        for candidateURL in installRootCandidates {
            guard fileManager.fileExists(atPath: candidateURL.path) else { continue }

            let inspection = inspectItem(at: candidateURL, type: .custom)

            var item = DataDirItem(
                name: "Conda 安装目录: \(candidateURL.lastPathComponent)",
                path: candidateURL,
                type: .custom,
                priority: .critical,
                description: "Conda Python 发行版根目录（包含解释器、包、环境和 Navigator 相关文件）",
                isMigratable: true
            )
            item.associatedAppName = appName
            item.status = inspection.status
            item.linkedDestination = inspection.linkedDestination

            results.append(item)
        }

        return deduplicate(items: results)
    }

    private func isCondaDistribution(bundleID: String?, appName: String) -> Bool {
        let normalizedBundleID = (bundleID ?? "").lowercased()
        let normalizedName = appName.lowercased()

        return normalizedBundleID.contains("anaconda")
            || normalizedBundleID.contains("conda")
            || normalizedName.contains("anaconda")
            || normalizedName.contains("miniconda")
            || normalizedName.contains("conda")
    }

    private func condaInstallRootCandidates(for app: AppItem) -> [URL] {
        var candidates: [URL] = []

        if let resolvedBundleURL = resolveRealAppBundleURL(for: app.path) {
            let installRoot = resolvedBundleURL.deletingLastPathComponent()
            if installRoot.path != app.path.deletingLastPathComponent().path {
                candidates.append(installRoot)
            }
        }

        let staticCandidatePaths = [
            "/opt/anaconda3",
            "/opt/miniconda3",
            "/usr/local/anaconda3",
            "/usr/local/miniconda3",
            homeDir.appendingPathComponent("anaconda3").path,
            homeDir.appendingPathComponent("miniconda3").path
        ]

        for path in staticCandidatePaths {
            candidates.append(URL(fileURLWithPath: path))
        }

        return deduplicate(urls: candidates)
    }

    private func resolveRealAppBundleURL(for appURL: URL) -> URL? {
        guard let values = try? appURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let rawPath = try? fileManager.destinationOfSymbolicLink(atPath: appURL.path) else {
            return nil
        }

        let resolvedURL = URL(fileURLWithPath: rawPath, relativeTo: appURL.deletingLastPathComponent()).standardizedFileURL
        return resolvedURL.pathExtension == "app" ? resolvedURL : nil
    }

    private func deduplicate(items: [DataDirItem]) -> [DataDirItem] {
        var seen = Set<String>()
        var deduplicated: [DataDirItem] = []

        for item in items {
            let key = item.path.standardizedFileURL.path
            if seen.insert(key).inserted {
                deduplicated.append(item)
            }
        }

        return deduplicated
    }

    private func deduplicate(urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var deduplicated: [URL] = []

        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                deduplicated.append(url.standardizedFileURL)
            }
        }

        return deduplicated
    }

    /// 在指定目录中查找与应用匹配的子目录
    ///
    /// 匹配规则（按优先级）：
    /// 1. 目录名 == BundleID（如 `com.apple.logic10`）
    /// 2. 目录名 == AppName（如 `Logic Pro`）
    /// 3. 目录名包含 BundleID 前缀（用于 Group Containers）
    private func findMatchingDirs(in baseURL: URL, bundleID: String?, appName: String) -> [URL] {
        guard fileManager.fileExists(atPath: baseURL.path) else { return [] }

        let contents = (try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: .skipsHiddenFiles
        )) ?? []

        var matched: [URL] = []

        for itemURL in contents {
            let dirName = itemURL.lastPathComponent
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDir = resourceValues?.isDirectory ?? false
            let isSymlink = resourceValues?.isSymbolicLink ?? false
            
            // 只要是目录或者指向目录的符号链接都接受
            guard isDir || isSymlink else { continue }

            // 规则1：精确匹配 BundleID
            if let bid = bundleID, dirName == bid {
                matched.append(itemURL)
                continue
            }

            // 规则2：精确匹配 AppName（忽略大小写）
            if dirName.localizedCaseInsensitiveCompare(appName) == .orderedSame {
                matched.append(itemURL)
                continue
            }

            // 规则3：BundleID 前缀匹配（用于 Group Containers，如 group.com.apple.logic）
            if let bid = bundleID, !bid.isEmpty {
                let bidComponents = bid.split(separator: ".")
                // 取 BundleID 后两段作为关键词，例如 com.apple.logic10 → apple.logic10
                if bidComponents.count >= 2 {
                    let keyword = bidComponents.dropFirst().joined(separator: ".")
                    if dirName.localizedCaseInsensitiveContains(keyword) {
                        matched.append(itemURL)
                        continue
                    }
                }
            }

            // 规则4：目录名包含应用名（模糊匹配，用于非标准命名）
            if appName.count >= 4,
               dirName.localizedCaseInsensitiveContains(appName) {
                matched.append(itemURL)
                continue
            }
        }

        return matched
    }

    /// 从 Info.plist 读取 BundleID
    private func readBundleID(from appURL: URL) -> String? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    /// 检测目录当前状态，并区分 AppPorts 受管链接和已有软链接。
    private func inspectItem(at url: URL, type: DataDirType) -> (status: String, linkedDestination: URL?) {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
            return (fileManager.fileExists(atPath: url.path) ? "本地" : "未找到", nil)
        }

        if values.isSymbolicLink == true {
            let linkedDestination = resolveSymlinkDestination(at: url)
            guard let linkedDestination else {
                return ("现有软链", nil)
            }

            if isAppPortsManagedLink(from: url, to: linkedDestination, type: type) {
                return ("已链接", linkedDestination)
            }

            return ("现有软链", linkedDestination)
        }

        if values.isDirectory == true {
            return ("本地", nil)
        }

        return ("未找到", nil)
    }

    private func resolveSymlinkDestination(at url: URL) -> URL? {
        guard let rawPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        return URL(fileURLWithPath: rawPath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    /// AppPorts 管理的数据目录链接会落在：
    /// 1. 目标目录中存在 AppPorts 写入的隐藏元数据
    /// 2. 或者命中历史日志中的迁移记录（兼容旧版本）
    private func isAppPortsManagedLink(from sourceURL: URL, to destinationURL: URL, type: DataDirType) -> Bool {
        let standardizedSource = sourceURL.standardizedFileURL
        let standardizedDestination = destinationURL.standardizedFileURL

        if let metadata = readManagedLinkMetadata(in: standardizedDestination) {
            return metadata.schemaVersion == managedLinkSchemaVersion
                && metadata.managedBy == managedLinkIdentifier
                && metadata.sourcePath == standardizedSource.path
                && metadata.destinationPath == standardizedDestination.path
                && metadata.dataDirType == type.rawValue
        }

        return historicalManagedLinks().contains(linkRecordKey(source: standardizedSource.path, destination: standardizedDestination.path))
    }

    private func readManagedLinkMetadata(in destinationURL: URL) -> ManagedLinkMetadata? {
        let markerURL = markerURL(for: destinationURL)
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? PropertyListDecoder().decode(ManagedLinkMetadata.self, from: data)
    }

    private func historicalManagedLinks() -> Set<String> {
        if let historicalManagedLinksCache {
            return historicalManagedLinksCache
        }

        let logURL = AppLogger.shared.logFileURL
        guard let data = try? Data(contentsOf: logURL),
              let content = String(data: data, encoding: .utf8) else {
            historicalManagedLinksCache = []
            return []
        }

        var records = Set<String>()
        for line in content.components(separatedBy: .newlines) {
            guard let (sourcePath, destinationPath) = parseManagedLinkRecord(from: line) else { continue }
            records.insert(linkRecordKey(source: sourcePath, destination: destinationPath))
        }

        historicalManagedLinksCache = records
        return records
    }

    private func parseManagedLinkRecord(from line: String) -> (String, String)? {
        let prefixes = [
            "步骤3: 符号链接创建成功: ",
            "创建符号链接: "
        ]

        for prefix in prefixes {
            guard let range = line.range(of: prefix) else { continue }
            let payload = String(line[range.upperBound...])
            if let (sourcePath, destinationPath) = splitLoggedLinkPayload(payload) {
                let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
                let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
                return (source, destination)
            }
        }

        return nil
    }

    private func splitLoggedLinkPayload(_ payload: String) -> (String, String)? {
        let separators = [" → ", " -> "]

        for separator in separators {
            guard let range = payload.range(of: separator) else { continue }
            let source = String(payload[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = String(payload[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if !source.isEmpty && !destination.isEmpty {
                return (source, destination)
            }
        }

        return nil
    }

    private func linkRecordKey(source: String, destination: String) -> String {
        source + "\n" + destination
    }

    private func markerURL(for directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(managedLinkMarkerFileName)
    }
}
