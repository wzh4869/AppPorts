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
/// 3. 检测每个目录当前状态（本地 / 已链接 / 未找到）
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

            let status = detectStatus(at: fullPath)
            let linkedDest = detectLinkedDestination(at: fullPath)

            var item = DataDirItem(
                name: known.name,
                path: fullPath,
                type: .dotFolder,
                priority: known.priority,
                description: known.description,
                isMigratable: known.isMigratable,
                nonMigratableReason: known.nonMigratableReason
            )
            item.status = status
            item.linkedDestination = linkedDest

            results.append(item)
        }

        return results.sorted { $0.priority < $1.priority }
    }

    /// 扫描指定应用在 ~/Library/ 下的关联数据目录
    ///
    /// 根据应用的 BundleID 和名称，在标准 Library 子目录中查找匹配目录。
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
                let status = detectStatus(at: candidateURL)
                let linkedDest = detectLinkedDestination(at: candidateURL)

                var item = DataDirItem(
                    name: "\(config.type.rawValue)：\(candidateURL.lastPathComponent)",
                    path: candidateURL,
                    type: config.type,
                    priority: config.priority,
                    description: config.desc,
                    isMigratable: true
                )
                item.associatedAppName = appName
                item.status = status
                item.linkedDestination = linkedDest

                results.append(item)
            }
        }

        return results.sorted { $0.priority < $1.priority }
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
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true, let fileSize = values.fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }

    // MARK: - 私有辅助方法

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

    /// 检测目录当前状态
    private func detectStatus(at url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
            return fileManager.fileExists(atPath: url.path) ? "本地" : "未找到"
        }
        if values.isSymbolicLink == true { return "已链接" }
        if values.isDirectory == true    { return "本地" }
        return "未找到"
    }

    /// 如果是符号链接，返回链接目标 URL；否则返回 nil
    private func detectLinkedDestination(at url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true else { return nil }
        if let dest = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            return URL(fileURLWithPath: dest)
        }
        return nil
    }
}
