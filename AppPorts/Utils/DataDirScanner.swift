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

// MARK: - 快速目录大小计算（非 actor 隔离，支持并发）

/// 目录大小缓存，减少重复遍历
private let directorySizeCache: NSCache<NSString, NSNumber> = {
    let c = NSCache<NSString, NSNumber>()
    c.countLimit = 200
    return c
}()

/// 缓存键带上当前挂载状态。挂载点被挂上或卸下时目录内容会整体替换，
/// 状态一变就等于缓存失效，不会把卸载前那份旧大小继续报给界面。
private func sizeCacheKey(for path: String, isMountPoint: Bool) -> NSString {
    "\(path)|\(isMountPoint ? "mount" : "plain")" as NSString
}

/// 子目录内容变更也会改变所有父目录的总大小，两种挂载状态的缓存都要失效。
func invalidateSizeCache(for url: URL) {
    var path = url.standardizedFileURL.path
    while !path.isEmpty {
        directorySizeCache.removeObject(forKey: sizeCacheKey(for: path, isMountPoint: true))
        directorySizeCache.removeObject(forKey: sizeCacheKey(for: path, isMountPoint: false))
        guard path != "/" else { break }
        path = (path as NSString).deletingLastPathComponent
    }
}

/// 清除全部大小缓存
func clearSizeCache() {
    directorySizeCache.removeAllObjects()
}

/// 非隔离的快速目录大小计算，支持 TaskGroup 并发调用。
///
/// 优先级：内存缓存 → FileManager.enumerator
/// 注意：不对目录使用 Spotlight（kMDItemFSSize 对目录不可靠，PearCleaner 也跳过了）
func fastDirectorySize(
    at url: URL,
    fileManager: FileManager = .default,
    isMountPoint: (URL) -> Bool = { DiskUtility.isMountPoint($0) }
) -> Int64 {
    measureDirectorySize(at: url, fileManager: fileManager, isMountPoint: isMountPoint).bytes
}

/// 界面需要同时知道大小和读取是否完整，不能把读取失败当成 0 字节。
func measureDirectorySize(
    at url: URL,
    fileManager: FileManager = .default,
    useCache: Bool = true,
    isMountPoint: (URL) -> Bool = { DiskUtility.isMountPoint($0) }
) -> DirectorySizeResult {
    let cacheKey = sizeCacheKey(for: url.standardizedFileURL.path, isMountPoint: isMountPoint(url))
    if useCache, let cached = directorySizeCache.object(forKey: cacheKey) {
        return DirectorySizeResult(bytes: cached.int64Value)
    }
    directorySizeCache.removeObject(forKey: cacheKey)

    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: Set(resourceKeys))
    } catch {
        return DirectorySizeResult(readIssues: [DataDirReadIssue(url: url, error: error)])
    }

    // 单文件：直接返回大小
    if values.isRegularFile == true {
        let size = Int64(values.fileSize ?? 0)
        directorySizeCache.setObject(NSNumber(value: size), forKey: cacheKey)
        return DirectorySizeResult(bytes: size)
    }

    guard values.isDirectory == true else { return DirectorySizeResult() }

    // 枚举器遍历（单次批量遍历，替代手动递归的 contentsOfDirectory）
    var result = DirectorySizeResult()
    guard let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
        options: [],
        errorHandler: { failedURL, error in
            result.readIssues.append(DataDirReadIssue(url: failedURL, error: error))
            return true
        }
    ) else {
        return DirectorySizeResult(readIssues: [DataDirReadIssue(url: url, error: CocoaError(.fileReadUnknown))])
    }

    for case let fileURL as URL in enumerator {
        do {
            let attrs = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard attrs.isSymbolicLink != true, attrs.isRegularFile == true,
                  let fileSize = attrs.fileSize else { continue }
            result.bytes += Int64(fileSize)
        } catch {
            result.readIssues.append(DataDirReadIssue(url: fileURL, error: error))
        }
    }
    // 0 不写缓存：未挂载的挂载点就是一个空目录，算出来同样是 0；缓存下来会让卷挂好之后
    // 一直显示「0 字节」。空目录重新遍历的代价可以忽略，所以每次重算更安全。
    if result.isComplete && result.bytes > 0 {
        directorySizeCache.setObject(NSNumber(value: result.bytes), forKey: cacheKey)
    }
    return result
}

// MARK: - 数据目录扫描器

actor DataDirScanner {

    private let fileManager = FileManager.default
    private let homeDir: URL
    private let managedLinkMarkerFileName = ".appports-link-metadata.plist"
    private let managedLinkMetadataSidecarSuffix = ".appports-link-metadata.plist"
    private let managedLinkIdentifier = "com.shimoko.AppPorts"
    private let managedLinkSchemaVersion = 1
    private let mountStore: ContainerMountStore
    private let isMountPoint: @Sendable (URL) -> Bool
    private let isVolumeOnline: @Sendable (String) -> Bool
    private let isSandboxedApplication: @Sendable (URL) -> Bool
    /// 本轮扫描开始时读取一次的挂载记录，避免逐路径重复读文件。
    private var mountRecordsByPath: [String: ContainerMountRecord] = [:]
    private var recoveryInspection: ContainerMountStore.Inspection?
    private var readIssues: [DataDirReadIssue] = []

    private struct ManagedLinkMetadata: Codable, Sendable {
        let schemaVersion: Int
        let managedBy: String
        let sourcePath: String
        let destinationPath: String
        let dataDirType: String
    }

    init(
        homeDir: URL = URL(fileURLWithPath: NSHomeDirectory()),
        mountStore: ContainerMountStore = .shared,
        isMountPoint: @escaping @Sendable (URL) -> Bool = { DiskUtility.isMountPoint($0) },
        isVolumeOnline: @escaping @Sendable (String) -> Bool = { DiskUtility.isVolumeOnline($0) },
        isSandboxedApplication: @escaping @Sendable (URL) -> Bool = { DataDirScanner.isSandboxedRealApplication($0) }
    ) {
        self.homeDir = homeDir.standardizedFileURL
        self.mountStore = mountStore
        self.isMountPoint = isMountPoint
        self.isVolumeOnline = isVolumeOnline
        self.isSandboxedApplication = isSandboxedApplication
    }

    /// 解析入口到真实应用后读取 entitlements；找不到真实应用时按非沙盒处理，
    /// 后续的重签名与挂载入口会各自再做校验。
    static func isSandboxedRealApplication(_ appURL: URL) -> Bool {
        guard let realURL = try? CodeSigner.resolveAppURL(at: appURL) else { return false }
        return CodeSigner.isSandboxed(at: realURL)
    }

    /// 关联应用是否为沙盒应用。沙盒应用迁移数据后不能重签名。
    /// 容器目录本身是否需要挂载迁移不看这个值：见 `scanLibraryDirs` 中的统一规则。
    func isSandboxed(_ app: AppItem) -> Bool {
        guard !app.isFolder else { return false }
        return isSandboxedApplication(app.displayURL)
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
            name: "Gradle 缓存",
            relativePath: ".gradle",
            priority: .recommended,
            description: "Gradle 构建缓存、Wrapper 和依赖数据"
        ),
        KnownDotFolder(
            name: "Android 开发数据",
            relativePath: ".android",
            priority: .recommended,
            description: "Android、ADB 和模拟器配置与缓存数据"
        ),
        KnownDotFolder(
            name: "Flutter/Dart 缓存",
            relativePath: ".pub-cache",
            priority: .recommended,
            description: "Dart 和 Flutter Pub 包缓存"
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
    func scanKnownDotFolders(externalRootURL: URL? = nil) -> [DataDirItem] {
        let scanID = AppLogger.shared.makeOperationID(prefix: "scanner-dot-folders")
        AppLogger.shared.logContext(
            "DataDirScanner 开始扫描工具目录",
            details: [
                ("scan_id", scanID),
                ("known_count", String(knownDotFolders.count)),
                ("external_root", externalRootURL?.path)
            ],
            level: "TRACE"
        )
        refreshMountRecords(for: nil)
        var results: [DataDirItem] = []

        for known in knownDotFolders {
            let fullPath = homeDir.appendingPathComponent(known.relativePath)

            var item = DataDirItem(
                name: known.name.localized,
                path: fullPath,
                type: .dotFolder,
                priority: known.priority,
                description: known.description.localized,
                isMigratable: known.isMigratable,
                nonMigratableReason: known.nonMigratableReason?.localized
            )

            if directoryExistsOrIsSymlink(at: fullPath) {
                let inspection = inspectItem(at: fullPath, type: .dotFolder)
                applyInspectionResult(to: &item, inspection: inspection, externalRootURL: externalRootURL)
                results.append(item)
                continue
            }

            if fileManager.fileExists(atPath: fullPath.path) {
                continue
            }

            if let externalRootURL {
                let externalPath = suggestedDestinationPath(for: item, under: externalRootURL)
                if existingDirectory(at: externalPath) {
                    item.status = "待接回"
                    item.linkedDestination = externalPath.standardizedFileURL
                    results.append(item)
                }
            }
        }

        let sortedResults = results.sorted { $0.priority < $1.priority }
        AppLogger.shared.logContext(
            "DataDirScanner 完成工具目录扫描",
            details: [
                ("scan_id", scanID),
                ("result_count", String(sortedResults.count)),
                ("statuses", Dictionary(grouping: sortedResults, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
            ],
            level: "TRACE"
        )
        return sortedResults
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
        scanLibraryDirsWithDiagnostics(for: app, externalRootURL: externalRootURL).items
    }

    func scanLibraryDirsWithDiagnostics(for app: AppItem, externalRootURL: URL? = nil) -> DataDirScanResult {
        readIssues = []
        guard !app.isFolder else { return DataDirScanResult(items: [], readIssues: []) }
        let scanID = AppLogger.shared.makeOperationID(prefix: "scanner-library-dirs")
        let identity: ResolvedAppIdentity?
        let identityIssue: AppIdentityIssue?
        switch AppIdentityResolver.resolve(at: app.displayURL) {
        case .success(let resolved):
            identity = resolved
            identityIssue = nil
        case .failure(let issue):
            identity = nil
            identityIssue = issue
        }
        let bundleID = identity?.bundleIdentifier
        refreshMountRecords(for: bundleID)
        let appName = app.displayName.replacingOccurrences(of: ".app", with: "")
        let matchProfile = buildMatchProfile(bundleID: bundleID, appName: appName)
        let appIsSandboxed = isSandboxedApplication(app.displayURL)
        AppLogger.shared.logContext(
            "DataDirScanner 开始扫描应用数据目录",
            details: [
                ("scan_id", scanID),
                ("app_name", appName),
                ("app_path", app.path.path),
                ("bundle_id", bundleID),
                ("identity_source", identity?.source.rawValue),
                ("identity_bundle_path", identity?.identityBundleURL.path),
                ("real_app_path", identity?.realAppURL.path),
                ("identity_error", identityIssue?.reason.rawValue),
                ("external_root", externalRootURL?.path),
                ("sandboxed", appIsSandboxed ? "true" : "false"),
                ("exact_match_count", String(matchProfile.exactMatches.count)),
                ("contains_match_count", String(matchProfile.containsMatches.count)),
                ("short_prefix_match_count", String(matchProfile.shortPrefixMatches.count))
            ],
            level: "TRACE"
        )

        var resultsByPath: [String: DataDirItem] = [:]

        for config in appDataSearchConfigs() {
            // Ordinary sandbox containers are keyed by application identity. Product-name
            // similarities are insufficient evidence that another container belongs to this app.
            let localCandidates = config.type == .containers
                ? findExactAppContainer(in: config.localBaseURL, bundleID: bundleID)
                : findMatchingDirs(in: config.localBaseURL, matchProfile: matchProfile)

            for candidateURL in localCandidates {
                let inspection = inspectItem(at: candidateURL, type: config.type)

                if config.type == .containers || config.type == .groupContainers {
                    for nestedItem in scanContainerStructure(
                        in: candidateURL, type: config.type, priority: config.priority,
                        appName: appName, externalRootURL: externalRootURL
                    ) {
                        resultsByPath[nestedItem.id] = nestedItem
                    }
                } else {
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
                }
            }

            // Detached container data is recovered from persistent records below, not
            // rediscovered by fuzzy product names in an external mirror.
            if config.type == .containers { continue }
            for externalBaseURL in externalBaseURLs(for: config.localBaseURL, externalRootURL: externalRootURL) {
                let externalCandidates = findMatchingDirs(in: externalBaseURL, matchProfile: matchProfile)

                for externalCandidate in externalCandidates {
                    guard let localURL = mapExternalCandidate(
                        externalCandidate,
                        from: externalBaseURL,
                        to: config.localBaseURL
                    ) else { continue }

                    // 跳过顶层容器目录（与本地扫描一致）
                    if config.type == .containers || config.type == .groupContainers { continue }

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

        // Persistent records remain visible even when the mount point is absent, deeply nested,
        // or outside the current discovery whitelist. Ownership was checked before caching them.
        for record in mountRecordsByPath.values {
            guard let type = DataDirType(rawValue: record.dataDirType) else { continue }
            let url = record.mountPointURL.standardizedFileURL
            var item = makeAppDataItem(name: url.lastPathComponent, path: url, type: type,
                                      priority: .critical, description: "容器内部数据目录", appName: appName)
            applyInspectionResult(to: &item, inspection: inspectItem(at: url, type: type), externalRootURL: externalRootURL)
            resultsByPath[item.id] = item
        }

        mergeRecoveryRecords(into: &resultsByPath, bundleID: bundleID, appName: appName, externalRootURL: externalRootURL)

        let policy = DataPathPolicy(homeDirectory: homeDir)
        for (key, item) in resultsByPath where item.type == .containers || item.type == .groupContainers {
            var updated = item
            if ![DataPathPolicy.Reason.runtimeConflict, .readFailure, .retainedOriginal].contains(where: { $0 == item.pathPolicy?.reason }) {
                updated.applyPathPolicy(policy.evaluate(item.path))
            }
            if recoveryInspection?.validationError != nil {
                updated.applyPathPolicy(.init(role: updated.pathPolicy?.role ?? .businessData, reason: .runtimeConflict,
                                              canMigrate: false, mayDiscoverChildren: false))
            }
            if readIssues.contains(where: { $0.url.standardizedFileURL == item.path.standardizedFileURL }) {
                updated.applyPathPolicy(.init(role: updated.pathPolicy?.role ?? .businessData, reason: .readFailure,
                                              canMigrate: false, mayDiscoverChildren: false))
                updated.sizeIsIncomplete = true
            }
            if let record = mountRecord(for: item.path),
               let reason = recoveryInspection?.remountInterventions[record.volumeUUID.uppercased()] {
                updated.applyPathPolicy(.init(role: updated.pathPolicy?.role ?? .businessData, reason: .runtimeConflict,
                                              canMigrate: false, mayDiscoverChildren: false))
                updated.nonMigratableReason = reason
            }
            if updated.isUserDirectoryLink,
               updated.pathPolicy?.reason != .runtimeConflict, updated.pathPolicy?.reason != .readFailure {
                updated.isMigratable = false
                updated.nonMigratableReason = updated.sizeScopeExplanation
                updated.applySize(DirectorySizeResult())
            }
            updated.requiresMountMigration = true
            updated.migrationWarning = nil
            resultsByPath[key] = updated
        }

        for key in Array(resultsByPath.keys) {
            resultsByPath[key]?.associatedBundleIdentifier = bundleID
        }

        let sortedResults = Array(resultsByPath.values).sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        AppLogger.shared.logContext(
            "DataDirScanner 完成应用数据目录扫描",
            details: [
                ("scan_id", scanID),
                ("app_name", appName),
                ("result_count", String(sortedResults.count)),
                ("statuses", Dictionary(grouping: sortedResults, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
            ],
            level: "TRACE"
        )
        return DataDirScanResult(items: sortedResults, readIssues: readIssues, identityIssue: identityIssue)
    }

    /// 异步计算单个目录大小
    ///
    /// 遇到符号链接时：
    /// - 标准沙盒链接（Desktop、Downloads 等指向 `~/` 的）→ 跳过，避免误计入用户个人文件
    /// - 指向外部存储的链接 → 递归计算目标目录大小，确保已迁移数据被正确计量
    ///
    /// - Parameter item: 要计算大小的目录项
    /// - Returns: 大小（字节）
    func calculateSize(for item: DataDirItem) -> Int64 {
        guard var scanURL = item.sizeMeasurementURL else { return 0 }
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey]

        if item.linkedDestination == nil,
           let values = try? scanURL.resourceValues(forKeys: Set(resourceKeys)),
           values.isSymbolicLink == true,
           let resolvedURL = resolveSymlinkDestination(at: scanURL) {
            scanURL = resolvedURL
        }

        guard fileManager.fileExists(atPath: scanURL.path) else { return 0 }

        let result = fastDirectorySize(at: scanURL, fileManager: fileManager)
        AppLogger.shared.log("[SizeDebug] \(item.name) | path=\(item.path.path) | scan=\(scanURL.path) | linked=\(item.linkedDestination?.path ?? "nil") | size=\(result) (\(result / (1024*1024)) MB)", level: "DEBUG")
        return result
    }

    // MARK: - 私有辅助方法

    private func refreshMountRecords(for bundleID: String?) {
        mountRecordsByPath = [:]
        recoveryInspection = nil
        guard let bundleID else { return }
        let records: [ContainerMountRecord]
        do {
            let inspection = try mountStore.recordsForInspection()
            recoveryInspection = inspection
            records = inspection.mounts
            if let error = inspection.validationError {
                recordReadIssue(at: homeDir.appendingPathComponent("Library/Application Support/AppPorts/container-mounts.plist"), error: error)
            }
        }
        catch {
            recordReadIssue(at: homeDir.appendingPathComponent("Library/Application Support/AppPorts/container-mounts.plist"), error: error)
            return
        }
        for record in records {
            let url = record.mountPointURL.standardizedFileURL
            let containerBases = ["Library/Containers", "Library/Group Containers"].map {
                homeDir.appendingPathComponent($0).standardizedFileURL
            }
            guard containerBases.contains(where: { base in
                let canonical = base.resolvingSymlinksInPath().path
                let source = url.resolvingSymlinksInPath().path
                return url.path.hasPrefix(base.path + "/") || source.hasPrefix(canonical + "/")
            }) else { continue }
            let root = homeDir.appendingPathComponent("Library/Containers/" + bundleID).standardizedFileURL.path
            let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            let path = url.resolvingSymlinksInPath().path
            let legacyIdentityMatches = record.bundleIdentifier == nil
                && (url.path == root || url.path.hasPrefix(root + "/")
                    || path == canonicalRoot || path.hasPrefix(canonicalRoot + "/"))
            guard record.bundleIdentifier == bundleID || legacyIdentityMatches else { continue }
            mountRecordsByPath[url.path] = record
            mountRecordsByPath[path] = record
        }
    }

    /// Indexes, unlike directory enumeration, survive missing paths and business-tree depth limits.
    private func mergeRecoveryRecords(into items: inout [String: DataDirItem], bundleID: String?, appName: String, externalRootURL: URL?) {
        guard let bundleID, let inspection = recoveryInspection else { return }
        func belongs(_ recordedBundle: String?, _ source: URL) -> Bool {
            let lexical = source.standardizedFileURL.path
            let canonical = source.resolvingSymlinksInPath().path
            let home = homeDir.resolvingSymlinksInPath().path
            guard lexical.hasPrefix(homeDir.path + "/") || canonical.hasPrefix(home + "/") else { return false }
            if recordedBundle == bundleID { return true }
            guard recordedBundle == nil else { return false }
            let root = homeDir.appendingPathComponent("Library/Containers/" + bundleID).path
            return lexical == root || lexical.hasPrefix(root + "/")
        }
        func conflict(_ item: inout DataDirItem) {
            let role = DataPathPolicy(homeDirectory: homeDir).evaluate(item.path).role
            item.applyPathPolicy(.init(role: role, reason: .runtimeConflict, canMigrate: false, mayDiscoverChildren: false))
        }
        for link in inspection.managedLinks {
            let source = URL(fileURLWithPath: link.originalPath).standardizedFileURL
            guard belongs(link.bundleIdentifier, source), let type = DataDirType(rawValue: link.dataDirType) else { continue }
            let destination = URL(fileURLWithPath: link.destinationPath).standardizedFileURL
            let inspection = inspectItem(at: source, type: type)
            var item = items[source.path] ?? makeAppDataItem(name: source.lastPathComponent, path: source, type: type,
                priority: .critical, description: "容器内部数据目录", appName: appName)
            item.hasManagedLinkRecord = true
            item.linkedDestination = destination
            if inspection.linkedDestination?.standardizedFileURL == destination {
                applyInspectionResult(to: &item, inspection: (DataDirStatus.linked, destination), externalRootURL: externalRootURL)
            } else {
                item.status = inspection.status
                if inspection.status != DataDirStatus.missing { conflict(&item) }
            }
            // A same-name replacement never inherits the old migration's identity.
            if let identity = try? DataPathIdentity.capture(destination), !identity.matchesFilesystemObject(link.destinationIdentity) { conflict(&item) }
            items[item.id] = item
        }
        for transfer in inspection.transfers {
            let source = URL(fileURLWithPath: transfer.originalPath).standardizedFileURL
            guard belongs(transfer.bundleIdentifier, source), let type = DataDirType(rawValue: transfer.dataDirType) else { continue }
            var item = items[source.path] ?? makeAppDataItem(name: source.lastPathComponent, path: source, type: type,
                priority: .critical, description: "容器内部数据目录", appName: appName)
            if items[source.path] == nil {
                applyInspectionResult(to: &item, inspection: inspectItem(at: source, type: type), externalRootURL: externalRootURL)
            }
            item.recoveryOperationID = transfer.operationID
            // Retention after success reserves the layout, but is not an error.
            // Interrupted operations still require explicit inspection.
            if [.awaitingUserVerification, .cleanupRequested].contains(transfer.phase), transfer.recoverableReason == nil,
               item.pathPolicy?.reason != .runtimeConflict, item.pathPolicy?.reason != .readFailure {
                let role = DataPathPolicy(homeDirectory: homeDir).evaluate(item.path).role
                item.applyPathPolicy(.init(role: role, reason: .retainedOriginal, canMigrate: false, mayDiscoverChildren: false))
            } else {
                conflict(&item)
            }
            items[item.id] = item
        }
    }

    private func mountRecord(for url: URL) -> ContainerMountRecord? {
        mountRecordsByPath[url.standardizedFileURL.path]
            ?? mountRecordsByPath[url.resolvingSymlinksInPath().path]
    }

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

    /// Enumerate structure, not entire business trees. A protected node is a display item;
    /// its lock never propagates to ordinary business descendants.
    private func scanContainerStructure(
        in rootURL: URL,
        type: DataDirType,
        priority: DataDirPriority,
        appName: String,
        externalRootURL: URL?
    ) -> [DataDirItem] {
        let policy = DataPathPolicy(homeDirectory: homeDir)
        var results: [DataDirItem] = []

        func visit(_ url: URL, depth: Int) {
            let inspection = inspectItem(at: url, type: type)
            let decision = policy.evaluate(url)
            var item = makeAppDataItem(name: containerRelativeSuffix(of: url, in: rootURL), path: url,
                                      type: type, priority: priority, description: "容器内部数据目录", appName: appName)
            applyInspectionResult(to: &item, inspection: inspection, externalRootURL: externalRootURL)
            item.applyPathPolicy(decision)
            // Ordinary sandbox convenience links point at user folders and are not app data.
            // Protected/managed links are still shown for diagnosis and recovery.
            if inspection.status == DataDirStatus.existingSymlink, decision.canMigrate, !item.isUserDirectoryLink,
               let target = inspection.linkedDestination,
               !shouldSurfaceNestedContainerLink(from: url, to: target, externalRootURL: externalRootURL) {
                return
            }
            results.append(item)
            guard inspection.status == DataDirStatus.local,
                  !isSymbolicLinkPath(at: url), !isMountPoint(url),
                  decision.mayDiscoverChildren, depth < 5 else { return }
            let entries = directoryEntries(at: url)
            for child in entries {
                // Container metadata is not a data candidate. The Data root is deliberately visible.
                if depth == 0 && type == .containers && child.lastPathComponent != "Data" { continue }
                visit(child, depth: depth + 1)
            }
        }

        visit(rootURL, depth: 0)
        return deduplicate(items: results)
    }

    private func containerRelativeSuffix(of url: URL, in containerURL: URL) -> String {
        let containerPath = containerURL.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(containerPath + "/") else { return url.lastPathComponent }
        return String(fullPath.dropFirst(containerPath.count + 1))
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
            name: "\(type.localizedTitle): \(name)",
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
        // 地区、平台和版本词既不能作为 Bundle ID 后缀，也不能从应用名中拆出后模糊匹配。
        // 例如 Trae CN 的「CN」不是应用身份，不能因此关联 cn.wps.* 的容器。
        let genericMatchTerms: Set<String> = [
            "app", "com", "org", "net", "io", "dev", "cn", "us", "uk", "de", "fr", "jp", "kr",
            "mac", "macos", "osx", "desktop", "client", "helper", "dmg", "pkg", "free", "pro", "lite", "beta", "ide"
        ]

        let cleanedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let strippedVariants = strippedNameVariants(for: cleanedAppName)

        for variant in strippedVariants {
            exactMatches.insert(variant)
            let compact = compactName(variant)
            if !compact.isEmpty {
                exactMatches.insert(compact)
            }
        }

        for token in strippedVariants.flatMap({ tokens(from: $0) }) where !genericMatchTerms.contains(token.lowercased()) {
            if token.count <= 3 {
                shortPrefixMatches.append(token)
            } else {
                containsMatches.append(token)
            }
        }

        if let bundleID, !bundleID.isEmpty, !bundleID.lowercased().hasSuffix(".appports.stub") {
            exactMatches.insert(bundleID)

            let components = bundleID.split(separator: ".").map(String.init)
            if components.count >= 2 {
                // 通用 TLD / 平台 / 打包词汇，作为 containsMatch 会造成大范围误匹配
                // （如 com.termius-dmg.mac 的 "mac" 会命中 com.tencent.QQMusicMac）。
                for index in 1..<components.count {
                    let suffix = components[index...].joined(separator: ".")
                    // 跳过纯通用后缀（如 "app"、"mac"）和由通用词汇组成的多段后缀
                    if components[index...].allSatisfy({ genericMatchTerms.contains($0.lowercased()) }) {
                        continue
                    }
                    // 单段后缀必须足够独特；短于 4 个字符的单词（"mac"、"ide"）几乎必然误匹配
                    let isSingleComponent = index == components.count - 1
                    if suffix.count >= (isSingleComponent ? 4 : 3) {
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

    /// Ordinary container discovery requires the resolved application identity.
    private func findExactAppContainer(in baseURL: URL, bundleID: String?) -> [URL] {
        guard let bundleID else { return [] }
        let candidate = baseURL.appendingPathComponent(bundleID).standardizedFileURL
        guard candidate.deletingLastPathComponent() == baseURL.standardizedFileURL else { return [] }
        do {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true || values.isSymbolicLink == true ? [candidate] : []
        } catch {
            recordReadIssue(at: candidate, error: error)
            return []
        }
    }

    /// 在指定目录中查找与应用匹配的子目录。
    ///
    /// 使用 enumerator 仅遍历至多 2 层深度，单次批量遍历替代逐层 contentsOfDirectory。
    /// 对非匹配的顶层目录自动下钻一层，匹配后跳过子树。
    private func findMatchingDirs(in baseURL: URL, matchProfile: AppMatchProfile) -> [URL] {
        guard fileManager.fileExists(atPath: baseURL.path) else { return [] }

        var matched: [URL] = []
        guard let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { failedURL, error in
                // 不将其他应用目录的访问限制算成当前应用的扫描失败。
                let path = failedURL.standardizedFileURL.path
                if path == baseURL.standardizedFileURL.path
                    || matched.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") })
                    || self.matchesDirectoryName(failedURL.lastPathComponent, profile: matchProfile) {
                    self.recordReadIssue(at: failedURL, error: error)
                }
                return true
            }
        ) else { return [] }

        let baseDepth = baseURL.standardizedFileURL.pathComponents.count

        for case let itemURL as URL in enumerator {
            let depth = itemURL.standardizedFileURL.pathComponents.count - baseDepth
            guard depth <= 2 else {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  (values.isDirectory == true || values.isSymbolicLink == true) else { continue }

            if matchesDirectoryName(itemURL.lastPathComponent, profile: matchProfile) {
                matched.append(itemURL)
                if depth >= 2 {
                    enumerator.skipDescendants()
                }
            } else if depth >= 2 {
                // 非匹配的二级目录不再深入
                enumerator.skipDescendants()
            }
        }

        return deduplicate(urls: matched)
    }

    private func directoryEntries(at baseURL: URL) -> [URL] {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: .skipsHiddenFiles
            )
        } catch {
            recordReadIssue(at: baseURL, error: error)
            return []
        }

        return contents.filter { itemURL in
            do {
                let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true || values.isSymbolicLink == true
            } catch {
                recordReadIssue(at: itemURL, error: error)
                return false
            }
        }
    }

    private func recordReadIssue(at url: URL, error: Error) {
        // 不存在的可选目录很常见；只有实际的读取失败影响统计完整性。
        guard !DataDirReadIssue.isMissingFile(error) else { return }
        let issue = DataDirReadIssue(url: url, error: error)
        guard !readIssues.contains(where: { $0.url == issue.url }) else { return }
        readIssues.append(issue)
        AppLogger.shared.logError(
            "应用数据目录读取失败，空间统计不完整",
            error: error,
            errorCode: "DATA-DIR-SCAN-READ-FAILED",
            relatedURLs: [("path", url)]
        )
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

    /// 检测目录当前状态，并区分 AppPorts 受管链接、挂载迁移项和已有符号链接。
    private func inspectItem(at url: URL, type: DataDirType) -> (status: String, linkedDestination: URL?) {
        if let record = mountRecord(for: url) {
            if isMountPoint(url) {
                return (DataDirStatus.mounted, nil)
            }
            return (isVolumeOnline(record.volumeUUID) ? DataDirStatus.pendingMount : DataDirStatus.volumeMissing, nil)
        }

        if isSymbolicLinkPath(at: url) {
            let linkedDestination = resolveSymlinkDestination(at: url)
            guard let linkedDestination else {
                AppLogger.shared.logError(
                    "DataDirScanner 检测到无法解析目标的软链",
                    context: [("path", url.path), ("type", type.rawValue)],
                    relatedURLs: [("path", url)]
                )
                return ("现有软链", nil)
            }

            if isAppPortsManagedLink(from: url, to: linkedDestination, type: type) {
                AppLogger.shared.logContext(
                    "DataDirScanner 识别到受管软链",
                    details: [("path", url.path), ("target", linkedDestination.path), ("type", type.rawValue)],
                    level: "TRACE"
                )
                return ("已链接", linkedDestination)
            }

            AppLogger.shared.logContext(
                "DataDirScanner 识别到现有软链",
                details: [("path", url.path), ("target", linkedDestination.path), ("type", type.rawValue)],
                level: "TRACE"
            )
            return ("现有软链", linkedDestination)
        }

        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
            return (fileManager.fileExists(atPath: url.path) ? "本地" : "未找到", nil)
        }

        if values.isDirectory == true {
            return ("本地", nil)
        }

        return ("未找到", nil)
    }

    private func directoryExistsOrIsSymlink(at url: URL) -> Bool {
        existingDirectory(at: url) || isSymbolicLinkPath(at: url)
    }

    private func existingDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isSymbolicLinkPath(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func resolveSymlinkDestination(at url: URL) -> URL? {
        guard let rawPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        return URL(fileURLWithPath: rawPath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    /// AppPorts 管理的数据目录链接会落在：
    /// AppPorts 管理的数据目录链接必须命中目标目录中的元数据标记。
    ///
    /// 历史日志会轮转、截断，也可能被复制到其他机器，不能作为受管状态的权威来源。
    /// 这里宁可把缺少标记的旧链接降级成“现有软链”，也不能误判成受管对象。
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

        return false
    }

    private func readManagedLinkMetadata(in destinationURL: URL) -> ManagedLinkMetadata? {
        let markerURL = markerURL(for: destinationURL)
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? PropertyListDecoder().decode(ManagedLinkMetadata.self, from: data)
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
