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

private struct AppMatchProfile {
    let exactMatches: Set<String>
    let containsMatches: [String]
    let shortPrefixMatches: [String]
}

private struct AppDataSearchConfig {
    let localBaseURL: URL
    let type: DataDirType
    let priority: DataDirPriority
    let description: String
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
    private let managedLinkMetadataSidecarSuffix = ".appports-link-metadata.plist"
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
            applyInspectionResult(to: &item, inspection: inspection, externalRootURL: nil)

            results.append(item)
        }

        return results.sorted { $0.priority < $1.priority }
    }

    /// 扫描指定应用的关联数据目录
    ///
    /// 默认会在 `~/Library/` 标准子目录中查找，同时为少数特殊安装方式补充额外目录。
    ///
    /// - Parameters:
    ///   - app: 要查找关联数据的应用
    ///   - externalRootURL: 已选择的外部存储根目录。若存在，会额外扫描其镜像目录中的可接回数据。
    /// - Returns: 找到的关联数据目录列表（未计算大小）
    func scanLibraryDirs(for app: AppItem, externalRootURL: URL? = nil) -> [DataDirItem] {
        guard !app.isFolder else { return [] }

        // 从 Info.plist 读取 BundleID
        let bundleID = readBundleID(from: app.path)
        let appName = app.name.replacingOccurrences(of: ".app", with: "")
        let matchProfile = buildMatchProfile(bundleID: bundleID, appName: appName)

        var resultsByPath: [String: DataDirItem] = [:]

        for config in appDataSearchConfigs() {
            let localCandidates = findMatchingDirs(in: config.localBaseURL, matchProfile: matchProfile)

            for candidateURL in localCandidates {
                let inspection = inspectItem(at: candidateURL, type: config.type)

                var item = makeAppDataItem(
                    name: candidateURL.lastPathComponent,
                    path: candidateURL,
                    type: config.type,
                    priority: config.priority,
                    description: config.description,
                    appName: appName
                )
                applyInspectionResult(to: &item, inspection: inspection, externalRootURL: externalRootURL)

                resultsByPath[candidateURL.standardizedFileURL.path] = item

                if config.type == .containers {
                    for nestedItem in scanNestedContainerDataLinks(
                        in: candidateURL,
                        priority: config.priority,
                        appName: appName,
                        externalRootURL: externalRootURL
                    ) {
                        resultsByPath[nestedItem.path.standardizedFileURL.path] = nestedItem
                    }
                }
            }

            for externalBaseURL in externalBaseURLs(for: config.localBaseURL, externalRootURL: externalRootURL) {
                let externalCandidates = findMatchingDirs(in: externalBaseURL, matchProfile: matchProfile)

                for externalCandidate in externalCandidates {
                    guard let localURL = mapExternalCandidate(
                        externalCandidate,
                        from: externalBaseURL,
                        to: config.localBaseURL
                    ) else { continue }

                    let localKey = localURL.standardizedFileURL.path
                    if resultsByPath[localKey] != nil { continue }
                    if fileManager.fileExists(atPath: localURL.path) { continue }

                    var item = makeAppDataItem(
                        name: localURL.lastPathComponent,
                        path: localURL,
                        type: config.type,
                        priority: config.priority,
                        description: config.description,
                        appName: appName
                    )
                    item.status = "待接回"
                    item.linkedDestination = externalCandidate.standardizedFileURL

                    resultsByPath[localKey] = item
                }
            }
        }

        for item in scanSpecialAssociatedDirs(for: app, bundleID: bundleID, appName: appName, externalRootURL: externalRootURL) {
            resultsByPath[item.path.standardizedFileURL.path] = item
        }

        return Array(resultsByPath.values).sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// 异步计算单个目录大小
    ///
    /// - Parameter item: 要计算大小的目录项
    /// - Returns: 大小（字节）
    func calculateSize(for item: DataDirItem) -> Int64 {
        // 如果是已链接状态，我们需要计算链接目标（外部存储）的大小
        var scanURL = item.linkedDestination ?? item.path
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey]

        if item.linkedDestination == nil,
           let values = try? scanURL.resourceValues(forKeys: Set(resourceKeys)),
           values.isSymbolicLink == true,
           let resolvedURL = resolveSymlinkDestination(at: scanURL) {
            scanURL = resolvedURL
        }

        guard fileManager.fileExists(atPath: scanURL.path) else { return 0 }

        if let values = try? scanURL.resourceValues(forKeys: Set(resourceKeys)),
           values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }

        guard let enumerator = fileManager.enumerator(
            at: scanURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: nil
        ) else { return 0 }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            if isManagedLinkMetadataFile(fileURL.lastPathComponent) {
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

    private func appDataSearchConfigs() -> [AppDataSearchConfig] {
        let libraryRoot = homeDir.appendingPathComponent("Library")

        return [
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("Application Support"),
                type: .applicationSupport,
                priority: .critical,
                description: "应用核心数据（设置、数据库等）"
            ),
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("Preferences"),
                type: .preferences,
                priority: .critical,
                description: "应用偏好设置与工作区配置"
            ),
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("Containers"),
                type: .containers,
                priority: .critical,
                description: "沙盒容器数据（App Store 应用）"
            ),
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("Group Containers"),
                type: .groupContainers,
                priority: .recommended,
                description: "应用组共享数据"
            ),
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("Application Scripts"),
                type: .applicationScripts,
                priority: .recommended,
                description: "扩展脚本与共享扩展数据"
            ),
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("WebKit"),
                type: .webKit,
                priority: .recommended,
                description: "WebKit 本地存储与网页登录状态"
            ),
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("Caches"),
                type: .caches,
                priority: .optional,
                description: "应用缓存（可重建）"
            ),
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("HTTPStorages"),
                type: .httpStorages,
                priority: .optional,
                description: "网络会话与 Cookie 存储"
            ),
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("Logs"),
                type: .logs,
                priority: .optional,
                description: "应用日志与诊断数据"
            ),
            AppDataSearchConfig(
                localBaseURL: libraryRoot.appendingPathComponent("Saved Application State"),
                type: .savedState,
                priority: .optional,
                description: "窗口状态恢复数据"
            )
        ]
    }

    private func scanNestedContainerDataLinks(
        in containerURL: URL,
        priority: DataDirPriority,
        appName: String,
        externalRootURL: URL?
    ) -> [DataDirItem] {
        let dataURL = containerURL.appendingPathComponent("Data")
        guard fileManager.fileExists(atPath: dataURL.path) else { return [] }

        var results: [DataDirItem] = []

        for childURL in directoryEntries(at: dataURL) {
            guard let targetURL = resolveSymlinkDestination(at: childURL),
                  shouldSurfaceNestedContainerLink(from: childURL, to: targetURL, externalRootURL: externalRootURL) else {
                continue
            }

            let inspection = inspectItem(at: childURL, type: .containers)
            let relativeSuffix = childURL.path.replacingOccurrences(of: containerURL.path + "/", with: "")

            var item = DataDirItem(
                name: "容器子目录: \(relativeSuffix)",
                path: childURL,
                type: .containers,
                priority: priority,
                description: "容器内部拆分迁移的数据目录（如聊天记录、下载文件或运行时数据）".localized,
                isMigratable: true
            )
            item.associatedAppName = appName
            item.linkedDestination = inspection.linkedDestination ?? targetURL
            applyInspectionResult(
                to: &item,
                inspection: (inspection.status, inspection.linkedDestination ?? targetURL),
                externalRootURL: externalRootURL
            )

            results.append(item)
        }

        return deduplicate(items: results)
    }

    private func shouldSurfaceNestedContainerLink(from sourceURL: URL, to targetURL: URL, externalRootURL: URL?) -> Bool {
        let standardizedTargetPath = targetURL.standardizedFileURL.path
        let standardizedHomePath = homeDir.standardizedFileURL.path

        if standardizedTargetPath.hasPrefix(standardizedHomePath + "/") {
            return false
        }

        let allowedRoot: URL
        if let externalRootURL,
           let mountedVolumeRoot = mountedVolumeRoot(for: externalRootURL) {
            allowedRoot = mountedVolumeRoot
        } else if let externalRootURL {
            allowedRoot = externalRootURL.standardizedFileURL
        } else {
            allowedRoot = URL(fileURLWithPath: "/Volumes")
        }

        let rootPath = allowedRoot.standardizedFileURL.path
        return standardizedTargetPath == rootPath || standardizedTargetPath.hasPrefix(rootPath + "/")
    }

    private func makeAppDataItem(
        name: String,
        path: URL,
        type: DataDirType,
        priority: DataDirPriority,
        description: String,
        appName: String
    ) -> DataDirItem {
        var item = DataDirItem(
            name: "\(type.rawValue.localized): \(name)",
            path: path,
            type: type,
            priority: priority,
            description: description.localized,
            isMigratable: true
        )
        item.associatedAppName = appName
        return item
    }

    private func applyInspectionResult(
        to item: inout DataDirItem,
        inspection: (status: String, linkedDestination: URL?),
        externalRootURL: URL?
    ) {
        item.status = inspection.status
        item.linkedDestination = inspection.linkedDestination

        guard inspection.status == "已链接",
              let linkedDestination = inspection.linkedDestination,
              needsNormalization(for: item, currentTarget: linkedDestination, externalRootURL: externalRootURL) else {
            return
        }

        item.status = "待规范"
    }

    private func needsNormalization(for item: DataDirItem, currentTarget: URL, externalRootURL: URL?) -> Bool {
        normalizedManagementDestination(for: item, currentTarget: currentTarget, externalRootURL: externalRootURL).standardizedFileURL.path
            != currentTarget.standardizedFileURL.path
    }

    private func normalizedManagementDestination(for item: DataDirItem, currentTarget: URL, externalRootURL: URL?) -> URL {
        if let externalRootURL {
            return suggestedDestinationPath(for: item, under: externalRootURL)
        }

        if item.type != .dotFolder {
            let libraryRoot = homeDir.appendingPathComponent("Library").standardizedFileURL.path
            let localPath = item.path.standardizedFileURL.path

            if localPath.hasPrefix(libraryRoot + "/") {
                let relativePath = String(localPath.dropFirst(libraryRoot.count + 1))
                if let range = currentTarget.standardizedFileURL.path.range(of: "/Library/\(relativePath)") {
                    let basePath = String(currentTarget.standardizedFileURL.path[..<range.lowerBound])
                    return URL(fileURLWithPath: basePath).appendingPathComponent(relativePath)
                }
            }
        }

        return currentTarget.standardizedFileURL
    }

    private func suggestedDestinationPath(for item: DataDirItem, under externalRoot: URL) -> URL {
        guard item.type != .dotFolder else {
            return externalRoot.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
        }

        let standardizedPath = item.path.standardizedFileURL.path
        let libraryRoot = homeDir.appendingPathComponent("Library").standardizedFileURL.path

        if standardizedPath.hasPrefix(libraryRoot + "/") {
            let relativePath = String(standardizedPath.dropFirst(libraryRoot.count + 1))
            return externalRoot.appendingPathComponent(relativePath)
        }

        return externalRoot.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
    }

    private func buildMatchProfile(bundleID: String?, appName: String) -> AppMatchProfile {
        var exactMatches = Set<String>()
        var containsMatches: [String] = []
        var shortPrefixMatches: [String] = []

        let cleanedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let strippedVariants = strippedNameVariants(for: cleanedAppName)

        for variant in strippedVariants {
            exactMatches.insert(variant)
            let compact = compactName(variant)
            if !compact.isEmpty {
                exactMatches.insert(compact)
            }
        }

        for token in strippedVariants.flatMap({ tokens(from: $0) }) {
            if token.count <= 3 {
                shortPrefixMatches.append(token)
            } else {
                containsMatches.append(token)
            }
        }

        if let bundleID, !bundleID.isEmpty {
            exactMatches.insert(bundleID)

            let components = bundleID.split(separator: ".").map(String.init)
            if components.count >= 2 {
                for index in 1..<components.count {
                    let suffix = components[index...].joined(separator: ".")
                    if suffix.count >= 3 {
                        containsMatches.append(suffix)
                    }
                }
            }
        }

        return AppMatchProfile(
            exactMatches: exactMatches,
            containsMatches: deduplicate(strings: containsMatches),
            shortPrefixMatches: deduplicate(strings: shortPrefixMatches)
        )
    }

    private func strippedNameVariants(for appName: String) -> [String] {
        var variants = Set<String>()
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        variants.insert(trimmed)

        let yearStripped = trimmed.replacingOccurrences(
            of: #"\s+(19|20)\d{2}$"#,
            with: "",
            options: .regularExpression
        )
        if !yearStripped.isEmpty {
            variants.insert(yearStripped)
        }

        let versionStripped = trimmed.replacingOccurrences(
            of: #"\s+\d+([._-]\d+)*$"#,
            with: "",
            options: .regularExpression
        )
        if !versionStripped.isEmpty {
            variants.insert(versionStripped)
        }

        return variants.filter { !$0.isEmpty }
    }

    private func tokens(from rawName: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)

        return rawName
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                guard !token.isEmpty else { return false }
                if token.allSatisfy(\.isNumber) {
                    return false
                }
                return token.count >= 2
            }
    }

    private func compactName(_ rawName: String) -> String {
        rawName
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .joined()
    }

    private func deduplicate(strings: [String]) -> [String] {
        var seen = Set<String>()
        var results: [String] = []

        for string in strings where !string.isEmpty {
            let key = string.lowercased()
            if seen.insert(key).inserted {
                results.append(string)
            }
        }

        return results
    }

    private func externalBaseURLs(for localBaseURL: URL, externalRootURL: URL?) -> [URL] {
        guard let externalRootURL,
              let mirroredSubpath = mirroredExternalSubpath(for: localBaseURL) else { return [] }

        var candidates: [URL] = []
        let rootCandidates = deduplicate(urls: externalSearchRoots(from: externalRootURL) + siblingExternalRoots(for: mirroredSubpath, externalRootURL: externalRootURL))

        for rootURL in rootCandidates {
            candidates.append(rootURL.appendingPathComponent(mirroredSubpath))

            if mirroredSubpath.hasPrefix("Library/") {
                let legacySubpath = String(mirroredSubpath.dropFirst("Library/".count))
                candidates.append(rootURL.appendingPathComponent(legacySubpath))
            }
        }

        return deduplicate(urls: candidates)
    }

    private func externalSearchRoots(from externalRootURL: URL) -> [URL] {
        let standardizedRoot = externalRootURL.standardizedFileURL
        var candidates = [standardizedRoot]

        guard let volumeRoot = mountedVolumeRoot(for: standardizedRoot) else {
            return deduplicate(urls: candidates)
        }

        var cursor = standardizedRoot
        while cursor.path != volumeRoot.path {
            let parent = cursor.deletingLastPathComponent().standardizedFileURL
            guard parent.path.hasPrefix(volumeRoot.path) else { break }
            candidates.append(parent)
            cursor = parent
        }

        candidates.append(volumeRoot)
        return deduplicate(urls: candidates)
    }

    private func siblingExternalRoots(for mirroredSubpath: String, externalRootURL: URL) -> [URL] {
        guard let volumeRoot = mountedVolumeRoot(for: externalRootURL) else { return [] }

        let legacySubpath = mirroredSubpath.hasPrefix("Library/")
            ? String(mirroredSubpath.dropFirst("Library/".count))
            : nil

        return directoryEntries(at: volumeRoot).filter { candidateRoot in
            let standardizedCandidateRoot = candidateRoot.standardizedFileURL

            if standardizedCandidateRoot.path == externalRootURL.standardizedFileURL.path {
                return false
            }

            if fileManager.fileExists(atPath: standardizedCandidateRoot.appendingPathComponent(mirroredSubpath).path) {
                return true
            }

            if let legacySubpath,
               fileManager.fileExists(atPath: standardizedCandidateRoot.appendingPathComponent(legacySubpath).path) {
                return true
            }

            return false
        }
    }

    private func mountedVolumeRoot(for url: URL) -> URL? {
        let pathComponents = url.standardizedFileURL.pathComponents
        guard pathComponents.count >= 3,
              pathComponents[1] == "Volumes" else { return nil }

        return URL(fileURLWithPath: "/Volumes/\(pathComponents[2])").standardizedFileURL
    }

    private func mirroredExternalSubpath(for localBaseURL: URL) -> String? {
        let standardizedLocalBase = localBaseURL.standardizedFileURL
        let homeLibraryRoot = homeDir.appendingPathComponent("Library").standardizedFileURL.path

        guard standardizedLocalBase.path.hasPrefix(homeLibraryRoot + "/") else { return nil }

        let libraryRelativePath = String(standardizedLocalBase.path.dropFirst(homeLibraryRoot.count + 1))
        return "Library/" + libraryRelativePath
    }

    private func mapExternalCandidate(_ externalURL: URL, from externalBaseURL: URL, to localBaseURL: URL) -> URL? {
        let standardizedExternal = externalURL.standardizedFileURL.path
        let standardizedBase = externalBaseURL.standardizedFileURL.path

        guard standardizedExternal.hasPrefix(standardizedBase + "/") else { return nil }

        let relativePath = String(standardizedExternal.dropFirst(standardizedBase.count + 1))
        return localBaseURL.appendingPathComponent(relativePath).standardizedFileURL
    }

    /// 补充少数“入口 app 与真实安装根目录分离”的应用目录。
    ///
    /// 当前主要覆盖 Conda 发行版：
    /// `/Applications/Anaconda-Navigator.app -> /opt/anaconda3/Anaconda-Navigator.app`
    private func scanSpecialAssociatedDirs(for app: AppItem, bundleID: String?, appName: String, externalRootURL: URL?) -> [DataDirItem] {
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
            applyInspectionResult(to: &item, inspection: inspection, externalRootURL: externalRootURL)

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

    /// 在指定目录中查找与应用匹配的子目录。
    ///
    /// 除了顶层目录外，还会额外检查一层子目录，用于覆盖：
    /// - `Application Support/Adobe/Adobe Photoshop 2026`
    /// - `Group Containers/FN2V63AD2J.com.tencent/qqex`
    private func findMatchingDirs(in baseURL: URL, matchProfile: AppMatchProfile) -> [URL] {
        guard fileManager.fileExists(atPath: baseURL.path) else { return [] }

        var matched: [URL] = []
        let topLevelEntries = directoryEntries(at: baseURL)

        for itemURL in topLevelEntries {
            if matchesDirectoryName(itemURL.lastPathComponent, profile: matchProfile) {
                matched.append(itemURL)
                continue
            }

            for childURL in directoryEntries(at: itemURL) where matchesDirectoryName(childURL.lastPathComponent, profile: matchProfile) {
                matched.append(childURL)
            }
        }

        return deduplicate(urls: matched)
    }

    private func directoryEntries(at baseURL: URL) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: .skipsHiddenFiles
        )) ?? []

        return contents.filter { itemURL in
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDir = resourceValues?.isDirectory ?? false
            let isSymlink = resourceValues?.isSymbolicLink ?? false
            return isDir || isSymlink
        }
    }

    private func matchesDirectoryName(_ rawName: String, profile: AppMatchProfile) -> Bool {
        let compactDirName = compactName(rawName)

        for exact in profile.exactMatches {
            if rawName.localizedCaseInsensitiveCompare(exact) == .orderedSame {
                return true
            }
            if !compactDirName.isEmpty && compactDirName.localizedCaseInsensitiveCompare(exact) == .orderedSame {
                return true
            }
        }

        for needle in profile.containsMatches where rawName.localizedCaseInsensitiveContains(needle) || compactDirName.localizedCaseInsensitiveContains(needle) {
            return true
        }

        for prefix in profile.shortPrefixMatches {
            if rawName.lowercased().hasPrefix(prefix.lowercased()) || compactDirName.lowercased().hasPrefix(prefix.lowercased()) {
                return true
            }
        }

        return false
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
        let standardizedURL = directoryURL.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])

        if values?.isDirectory == true {
            return standardizedURL.appendingPathComponent(managedLinkMarkerFileName)
        }

        return standardizedURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(standardizedURL.lastPathComponent)\(managedLinkMetadataSidecarSuffix)")
    }

    private func isManagedLinkMetadataFile(_ fileName: String) -> Bool {
        fileName == managedLinkMarkerFileName
            || (fileName.hasPrefix(".") && fileName.hasSuffix(managedLinkMetadataSidecarSuffix))
    }
}
