//
//  DataDirScanner.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/3/4.
//

import Foundation
import Darwin

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

/// Measurement groups belong to one detail refresh. Persistent cache hits have already been applied.
struct AppDataDetailSizing {
    typealias Row = (Int, DirectorySizeResult, [DirectorySizeResult], ToolDirectorySizeCacheStore.Entry?)

    let items: [DataDirItem]
    let policy: AppDataSizeCachePolicy
    let paused: Set<URL>
    let forceRefresh: Bool

    func groups(for pending: [Int]) -> [[Int]] {
        guard pending.count > 1, policy.allowCaching else { return pending.map { [$0] } }
        var separate: [[Int]] = []
        var ordinary: [(index: Int, path: String)] = []
        for index in pending {
            let item = items[index]
            guard item.status == DataDirStatus.local, item.linkedDestination == nil, !item.hasManagedLinkRecord,
                  item.weChatSplitMembers.isEmpty, !item.hasMountTransferRecord, item.recoveryOperationID == nil,
                  !directoryIncludesPausedMount(at: item.path, pausedMountDirectories: paused),
                  policy.uncacheablePaths.isEmpty || policy.isCacheable(item: item) else {
                separate.append([index])
                continue
            }
            let path = item.id
            // A possible memory hit stays independent. The actual lookup verifies its current mount state.
            if !forceRefresh, MemoryDirectorySizeCache.shared.hasEntry(for: path) {
                separate.append([index])
                continue
            }
            ordinary.append((index, path + "/"))
        }
        // The trailing slash keeps all descendants contiguous, including names such as Foo and Foo-Bar.
        var parent: String?
        for row in ordinary.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            if let parent, row.path.utf8.starts(with: parent.utf8) {
                separate[separate.count - 1].append(row.index)
            } else {
                parent = row.path
                separate.append([row.index])
            }
        }
        return separate
    }

    func measure(_ indices: [Int]) -> [Row] {
        guard let first = indices.first else { return [] }
        let members = items[first].weChatSplitMembers
        if !members.isEmpty {
            let results = members.map { member in
                let cacheable = policy.isCacheable(item: member)
                return measureDataDirectorySize(for: member, useCache: !forceRefresh && cacheable,
                    pausedMountDirectories: paused, allowWriteToCache: cacheable)
            }
            var total = DirectorySizeResult()
            for result in results {
                total.bytes += result.bytes
                total.readIssues += result.readIssues
            }
            return [(first, total, results, nil)]
        }

        let children = Set(indices.dropFirst().map { items[$0].path })
        let identities = indices.map { policy.cacheIdentity(for: items[$0]) }
        let epoch = MemoryDirectorySizeCache.shared.currentEpoch()
        var finished: [URL: DirectorySizeResult] = [:]
        var rows: [Row] = []
        for (index, identity) in zip(indices, identities) {
            guard !Task.isCancelled else { break }
            let item = items[index]
            guard let url = item.sizeMeasurementURL else {
                rows.append((index, DirectorySizeResult(), [], nil))
                continue
            }
            let measured = measureDirectorySize(at: url, useCache: !forceRefresh && identity != nil,
                pausedMountDirectories: paused, allowWriteToCache: identity != nil, startedAtEpoch: epoch) { root, skipped in
                if index == first, !children.isEmpty {
                    return DirectorySizeTraversal.measure(at: root, skippingDirectories: skipped, subtrees: children) {
                        finished[$0] = $1
                    }.root
                }
                if skipped.isEmpty, let value = finished[url], let identity, policy.cacheIdentity(for: item) == identity {
                    return value
                }
                // Unvisited children (mounts, intermediate links, unreadable or missing parents)
                // must be measured as roots to preserve their own bytes and errors.
                return DirectorySizeTraversal.measure(at: root, skippingDirectories: skipped)
            }
            var entry: ToolDirectorySizeCacheStore.Entry?
            if let identity, measured.isComplete, !directoryIncludesPausedMount(at: url, pausedMountDirectories: paused),
               policy.cacheIdentity(for: item) == identity {
                entry = .init(identity: identity, sourcePath: item.id, targetPath: url.resolvingSymlinksInPath().standardizedFileURL.path,
                              bytes: measured.bytes, measuredAt: Date())
            }
            rows.append((index, measured, [], entry))
        }
        return rows
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

// MARK: - 快速目录大小计算（非 actor 隔离，支持并发）

/// 内存目录大小缓存及并发失效 epoch 守卫，防止后台测量把已失效的旧目录体积回写到缓存。
private final class MemoryDirectorySizeCache: @unchecked Sendable {
    static let shared = MemoryDirectorySizeCache()

    private let lock = NSLock()
    private let cache: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 1000
        return c
    }()
    private var epoch: UInt64 = 0
    private var clearedEpoch: UInt64 = 0
    private var invalidatedEpochByPath: [String: UInt64] = [:]

    func object(forKey key: NSString) -> NSNumber? {
        lock.withLock { cache.object(forKey: key) }
    }

    func removeObject(forKey key: NSString) {
        lock.withLock { cache.removeObject(forKey: key) }
    }

    func hasEntry(for path: String) -> Bool {
        object(forKey: sizeCacheKey(for: path, isMountPoint: false)) != nil
            || object(forKey: sizeCacheKey(for: path, isMountPoint: true)) != nil
    }

    func currentEpoch() -> UInt64 {
        lock.withLock { epoch }
    }

    func store(_ bytes: Int64, forKey key: NSString, path: String, canonicalPath: String, startedAtEpoch: UInt64) {
        lock.withLock {
            guard clearedEpoch <= startedAtEpoch else { return }
            let invalidated = invalidatedEpochByPath.contains { invPath, invEpoch in
                invEpoch > startedAtEpoch
                    && (AppDataSizeCachePolicy.pathsOverlap(path, invPath)
                        || AppDataSizeCachePolicy.pathsOverlap(canonicalPath, invPath))
            }
            guard !invalidated else { return }
            cache.setObject(NSNumber(value: bytes), forKey: key)
        }
    }

    func invalidate(for url: URL) {
        let standardizedPath = url.standardizedFileURL.path
        lock.withLock {
            epoch &+= 1
            invalidatedEpochByPath[standardizedPath] = epoch
            var cursor = standardizedPath
            while !cursor.isEmpty {
                cache.removeObject(forKey: sizeCacheKey(for: cursor, isMountPoint: true))
                cache.removeObject(forKey: sizeCacheKey(for: cursor, isMountPoint: false))
                guard cursor != "/" else { break }
                cursor = (cursor as NSString).deletingLastPathComponent
            }
        }
    }

    func removeAll() {
        lock.withLock {
            epoch &+= 1
            clearedEpoch = epoch
            invalidatedEpochByPath.removeAll()
            cache.removeAllObjects()
        }
    }
}

/// 缓存键带上当前挂载状态。挂载点被挂上或卸下时目录内容会整体替换，
/// 状态一变就等于缓存失效，不会把卸载前那份旧大小继续报给界面。
private func sizeCacheKey(for path: String, isMountPoint: Bool) -> NSString {
    "\(path)|\(isMountPoint ? "mount" : "plain")" as NSString
}

/// 子目录内容变更也会改变所有父目录的总大小，两种挂载状态的缓存都要失效。
func invalidateSizeCache(for url: URL) {
    ToolDirectorySizeCacheStore.shared.invalidate(for: url)
    ToolDirectorySizeCacheStore.appDataDirectories.invalidate(for: url)
    MemoryDirectorySizeCache.shared.invalidate(for: url)
}

/// 清除全部大小缓存
func clearSizeCache() {
    MemoryDirectorySizeCache.shared.removeAll()
}

/// 非隔离的快速目录大小计算，支持 TaskGroup 并发调用。
///
/// 优先级：内存缓存 → FileManager.enumerator
/// 注意：不对目录使用 Spotlight（kMDItemFSSize 对目录不可靠，PearCleaner 也跳过了）
func fastDirectorySize(
    at url: URL,
    fileManager: FileManager = .default,
    isMountPoint: @escaping (URL) -> Bool = { DiskUtility.isMountPoint($0) }
) -> Int64 {
    measureDirectorySize(at: url, fileManager: fileManager, isMountPoint: isMountPoint).bytes
}

/// A split account row represents only its migrated media, not the local database.
func measureDataDirectorySize(for item: DataDirItem, useCache: Bool = false,
                              pausedMountDirectories: Set<URL> = [],
                              allowWriteToCache: Bool = true) -> DirectorySizeResult {
    let sources = item.weChatSplitMembers.isEmpty ? [item] : item.weChatSplitMembers
    var result = DirectorySizeResult()
    for source in sources {
        guard let url = source.sizeMeasurementURL else { continue }
        let measured = measureDirectorySize(
            at: url,
            useCache: useCache,
            pausedMountDirectories: pausedMountDirectories,
            allowWriteToCache: allowWriteToCache
        )
        result.bytes += measured.bytes
        result.readIssues += measured.readIssues
    }
    return result
}

func directoryIncludesPausedMount(at url: URL, pausedMountDirectories: Set<URL>) -> Bool {
    let path = url.standardizedFileURL.path
    return pausedMountDirectories.contains {
        $0.path == path || $0.path.hasPrefix(path + "/")
    }
}

func measureDataDirectorySizeWithPersistentCache(
    for item: DataDirItem,
    useCache: Bool,
    pausedMountDirectories: Set<URL>,
    cacheStore: ToolDirectorySizeCacheStore = .appDataDirectories,
    snapshot: inout ToolDirectorySizeCacheStore.Snapshot
) -> (result: DirectorySizeResult, cacheUpdated: Bool) {
    if !item.weChatSplitMembers.isEmpty {
        var combined = DirectorySizeResult()
        var updated = false
        for member in item.weChatSplitMembers {
            let memberMeasured = measureDataDirectorySizeWithPersistentCache(
                for: member,
                useCache: useCache,
                pausedMountDirectories: pausedMountDirectories,
                cacheStore: cacheStore,
                snapshot: &snapshot
            )
            combined.bytes += memberMeasured.result.bytes
            combined.readIssues += memberMeasured.result.readIssues
            if memberMeasured.cacheUpdated { updated = true }
        }
        return (combined, updated)
    }

    guard let measurementURL = item.sizeMeasurementURL else {
        return (DirectorySizeResult(), false)
    }
    let includesPausedMount = directoryIncludesPausedMount(at: measurementURL, pausedMountDirectories: pausedMountDirectories)
    let key = item.path.standardizedFileURL.path
    let identity = includesPausedMount ? nil : ToolDirectorySizeCacheStore.identity(for: item)
    if useCache, !includesPausedMount, let identity,
       let cached = snapshot.entries[key], cached.identity == identity {
        return (DirectorySizeResult(bytes: cached.bytes), false)
    }

    let removed = snapshot.entries.removeValue(forKey: key) != nil
    let measured = measureDataDirectorySize(for: item, useCache: useCache, pausedMountDirectories: pausedMountDirectories)
    var cacheUpdated = removed
    if measured.isComplete, !includesPausedMount, let identity,
       identity == ToolDirectorySizeCacheStore.identity(for: item) {
        snapshot.entries[key] = .init(
            identity: identity,
            sourcePath: key,
            targetPath: measurementURL.resolvingSymlinksInPath().standardizedFileURL.path,
            bytes: measured.bytes,
            measuredAt: Date()
        )
        cacheUpdated = true
    }
    return (measured, cacheUpdated)
}

/// 界面需要同时知道大小和读取是否完整，不能把读取失败当成 0 字节。
func measureDirectorySize(
    at url: URL,
    fileManager: FileManager = .default,
    useCache: Bool = true,
    pausedMountDirectories: Set<URL> = [],
    isMountPoint: @escaping (URL) -> Bool = { DiskUtility.isMountPoint($0) },
    allowWriteToCache: Bool = true,
    startedAtEpoch: UInt64? = nil,
    traverse: (URL, Set<URL>) -> DirectorySizeResult = { DirectorySizeTraversal.measure(at: $0, skippingDirectories: $1) }
) -> DirectorySizeResult {
    func readIssue(at failedURL: URL, error: Error) -> DataDirReadIssue {
        DataDirReadIssue(url: failedURL, error: error, pausedMountDirectories: pausedMountDirectories,
                         isMountPoint: isMountPoint)
    }
    let standardized = url.standardizedFileURL
    let canonicalPath = standardized.resolvingSymlinksInPath().standardizedFileURL.path
    let cacheKey = sizeCacheKey(for: standardized.path, isMountPoint: isMountPoint(url))
    let relevantPausedMounts = pausedMountDirectories.filter {
        let path = standardized.path
        return $0.path == path || $0.path.hasPrefix(path + "/")
    }
    let includesPausedMount = !relevantPausedMounts.isEmpty
    if useCache, !includesPausedMount, let cached = MemoryDirectorySizeCache.shared.object(forKey: cacheKey) {
        return DirectorySizeResult(bytes: cached.int64Value)
    }
    MemoryDirectorySizeCache.shared.removeObject(forKey: cacheKey)
    let startEpoch = startedAtEpoch ?? MemoryDirectorySizeCache.shared.currentEpoch()
    let pausedIssues = relevantPausedMounts.compactMap {
        DataDirReadIssue.pausedMountIssue(at: $0, pausedMountDirectories: pausedMountDirectories,
                                         isMountPoint: isMountPoint)
    }
    if pausedIssues.contains(where: { $0.url == standardized }) {
        return DirectorySizeResult(readIssues: pausedIssues)
    }

    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: Set(resourceKeys))
    } catch {
        return DirectorySizeResult(readIssues: [readIssue(at: url, error: error)])
    }

    // 单文件：直接返回大小
    if values.isRegularFile == true {
        let size = Int64(values.fileSize ?? 0)
        if allowWriteToCache && !includesPausedMount {
            MemoryDirectorySizeCache.shared.store(
                size,
                forKey: cacheKey,
                path: standardized.path,
                canonicalPath: canonicalPath,
                startedAtEpoch: startEpoch
            )
        }
        return DirectorySizeResult(bytes: size)
    }

    guard values.isDirectory == true else { return DirectorySizeResult() }

    // Native traversal retains the offline guard issues; readable placeholders
    // must never make an ancestor's partial size complete or cacheable.
    var skipped = Set(pausedIssues.map(\.url))
    if isMountPoint(url) {
        for artifact in ContainerVolumeMigrator.volumeSystemArtifacts {
            skipped.insert(standardized.appendingPathComponent(artifact).standardizedFileURL)
        }
    }
    var result = traverse(url, skipped)
    result.readIssues += pausedIssues
    // 0 不写缓存：未挂载的挂载点就是一个空目录，算出来同样是 0；缓存下来会让卷挂好之后
    // 一直显示「0 字节」。空目录重新遍历的代价可以忽略，所以每次重算更安全。
    if allowWriteToCache && !includesPausedMount && result.isComplete && result.bytes > 0 {
        MemoryDirectorySizeCache.shared.store(
            result.bytes,
            forKey: cacheKey,
            path: standardized.path,
            canonicalPath: canonicalPath,
            startedAtEpoch: startEpoch
        )
    }
    return result
}

// MARK: - 数据目录扫描器

actor DataDirScanner {

    private static let ignoredRuntimeMetadataSymlinkNames: Set<String> = [
        "RunningChromeVersion",
        "SingletonLock",
        "SingletonCookie",
        "SingletonSocket"
    ]

    private let fileManager = FileManager.default
    private let homeDir: URL
    private let managedLinkMarkerFileName = ".appports-link-metadata.plist"
    private let managedLinkMetadataSidecarSuffix = ".appports-link-metadata.plist"
    private let managedLinkIdentifier = "com.shimoko.AppPorts"
    private let managedLinkSchemaVersion = 1
    private let mountStore: ContainerMountStore
    private let isMountPoint: @Sendable (URL) -> Bool
    private let isVolumeOnlineOverride: (@Sendable (String) -> Bool)?
    private let isVolumeLockedOverride: (@Sendable (String) -> Bool)?
    private let isSandboxedApplication: @Sendable (URL) -> Bool
    /// 本轮扫描开始时读取一次的挂载记录，避免逐路径重复读文件。
    private var mountRecordsByPath: [String: ContainerMountRecord] = [:]
    private var volumeStateCache: [String: DiskUtility.VolumePresenceAndLockState] = [:]
    private var recoveryInspection: ContainerMountStore.Inspection?
    private var readIssues: [DataDirReadIssue] = []
    private var pausedMountDirectories: Set<URL> = []
    private let partialWeChatMigrationEnabled: Bool
    private let preferredWeChatSplitGroup: PartialWeChatMigrationPolicy.SplitGroup?
    private let weChatContainerIdentifier: String

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
        partialWeChatMigrationEnabled: Bool = false,
        preferredWeChatSplitGroup: PartialWeChatMigrationPolicy.SplitGroup? = nil,
        weChatContainerIdentifier: String = PartialWeChatMigrationPolicy.bundleIdentifier,
        isMountPoint: @escaping @Sendable (URL) -> Bool = { DiskUtility.isMountPoint($0) },
        isVolumeOnline: (@Sendable (String) -> Bool)? = nil,
        isVolumeLocked: (@Sendable (String) -> Bool)? = nil,
        isSandboxedApplication: @escaping @Sendable (URL) -> Bool = { DataDirScanner.isSandboxedRealApplication($0) }
    ) {
        self.homeDir = homeDir.standardizedFileURL
        self.mountStore = mountStore
        self.partialWeChatMigrationEnabled = partialWeChatMigrationEnabled
        self.preferredWeChatSplitGroup = preferredWeChatSplitGroup
        self.weChatContainerIdentifier = weChatContainerIdentifier
        self.isMountPoint = isMountPoint
        self.isVolumeOnlineOverride = isVolumeOnline
        self.isVolumeLockedOverride = isVolumeLocked
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
        volumeStateCache.removeAll(keepingCapacity: true)
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

    struct AppDataMeasurementTarget: Sendable {
        let item: DataDirItem
        let isMigrated: Bool
        let measurementKey: String
    }

    struct AppDataBatchPlan: Sendable {
        let targetsByAppID: [String: [AppDataMeasurementTarget]]
        let uniqueTargets: [String: DataDirItem]
        let readIssueAppIDs: Set<String>
        let pausedMountDirectories: Set<URL>
        let sizeCachePolicy: AppDataSizeCachePolicy
    }

    private struct IndexedDirectoryEntry {
        let url: URL
        let name: String
        let compactName: String
        let lowercasedName: String
        let lowercasedCompactName: String
    }

    private struct IndexedExternalRoot {
        let baseURL: URL
        let entries: [IndexedDirectoryEntry]
    }

    /// 单遍索引 `~/Library` 候选目录与外置镜像，为左侧应用列表批量汇总展示大小。
    func buildAppDataBatchPlan(for apps: [AppItem], externalRootURL: URL?) -> AppDataBatchPlan {
        guard !Task.isCancelled else {
            return AppDataBatchPlan(
                targetsByAppID: [:],
                uniqueTargets: [:],
                readIssueAppIDs: [],
                pausedMountDirectories: [],
                sizeCachePolicy: .empty
            )
        }
        readIssues = []
        mountRecordsByPath = [:]
        pausedMountDirectories = []
        recoveryInspection = nil
        volumeStateCache.removeAll(keepingCapacity: true)

        var hasGlobalStoreError = false
        var inspection: ContainerMountStore.Inspection?
        do {
            let loaded = try mountStore.recordsForInspection()
            inspection = loaded
            recoveryInspection = loaded
            if loaded.validationError != nil {
                hasGlobalStoreError = true
            }
        } catch {
            hasGlobalStoreError = true
        }

        let containerBases = ["Library/Containers", "Library/Group Containers"].map {
            homeDir.appendingPathComponent($0).standardizedFileURL
        }
        var mountsByBundleID: [String: [ContainerMountRecord]] = [:]
        var legacyMounts: [ContainerMountRecord] = []
        if let inspection {
            for record in inspection.mounts {
                let url = record.mountPointURL.standardizedFileURL
                let canonical = url.resolvingSymlinksInPath().path
                let insideContainerBase = containerBases.contains { base in
                    let baseCanonical = base.resolvingSymlinksInPath().path
                    return url.path.hasPrefix(base.path + "/") || canonical.hasPrefix(baseCanonical + "/")
                }
                guard insideContainerBase else { continue }
                mountRecordsByPath[url.path] = record
                mountRecordsByPath[canonical] = record
                if inspection.validationError == nil,
                   !isMountPoint(url) || (try? mountStore.isManuallyUnmounted(record)) == true {
                    pausedMountDirectories.insert(url)
                    pausedMountDirectories.insert(
                        url.deletingLastPathComponent().resolvingSymlinksInPath()
                            .appendingPathComponent(url.lastPathComponent).standardizedFileURL
                    )
                }
                if let bundleID = record.bundleIdentifier, !bundleID.isEmpty {
                    mountsByBundleID[bundleID, default: []].append(record)
                } else {
                    legacyMounts.append(record)
                }
            }
        }

        var linksByBundleID: [String: [ManagedDataLinkRecord]] = [:]
        var legacyLinks: [ManagedDataLinkRecord] = []
        if let inspection {
            for link in inspection.managedLinks {
                if let bundleID = link.bundleIdentifier, !bundleID.isEmpty {
                    linksByBundleID[bundleID, default: []].append(link)
                } else {
                    legacyLinks.append(link)
                }
            }
        }

        let configs = appDataSearchConfigs()
        var containerExactMap: [String: URL] = [:]
        var containerLowerMap: [String: URL] = [:]
        var indexedLocalByType: [DataDirType: [IndexedDirectoryEntry]] = [:]
        var indexedExternalByType: [DataDirType: [IndexedExternalRoot]] = [:]
        var hasRootReadIssue = false

        for config in configs {
            guard !Task.isCancelled else {
                return AppDataBatchPlan(
                    targetsByAppID: [:],
                    uniqueTargets: [:],
                    readIssueAppIDs: [],
                    pausedMountDirectories: pausedMountDirectories,
                    sizeCachePolicy: .empty
                )
            }
            if config.type == .containers {
                let levelOne = indexOneLevelContainers(in: config.localBaseURL, trackRootFailure: &hasRootReadIssue)
                containerExactMap = levelOne.exact
                containerLowerMap = levelOne.lower
                continue
            }
            var configRootFailed = false
            indexedLocalByType[config.type] = indexTwoLevels(in: config.localBaseURL, trackRootFailure: &configRootFailed)
            if configRootFailed { hasRootReadIssue = true }
            if config.type != .groupContainers {
                let externalRoots = externalBaseURLs(for: config.localBaseURL, externalRootURL: externalRootURL)
                var externalIndexed: [IndexedExternalRoot] = []
                for extBase in externalRoots {
                    guard !Task.isCancelled else { break }
                    var ignoredFailure = false
                    let entries = indexTwoLevels(in: extBase, trackRootFailure: &ignoredFailure)
                    if !entries.isEmpty {
                        externalIndexed.append(IndexedExternalRoot(baseURL: extBase, entries: entries))
                    }
                }
                indexedExternalByType[config.type] = externalIndexed
            }
        }

        var inspectionCache: [String: (status: String, linkedDestination: URL?)] = [:]
        func cachedInspectItem(at url: URL, type: DataDirType) -> (status: String, linkedDestination: URL?) {
            let key = "\(type.rawValue)|\(url.standardizedFileURL.path)"
            if let cached = inspectionCache[key] { return cached }
            let result = inspectItem(at: url, type: type)
            inspectionCache[key] = result
            return result
        }

        var targetsByAppID: [String: [AppDataMeasurementTarget]] = [:]
        var uniqueTargets: [String: DataDirItem] = [:]
        var readIssueAppIDs: Set<String> = []
        let homePath = homeDir.path
        let canonicalHomePath = homeDir.resolvingSymlinksInPath().path

        func belongsToHome(_ source: URL, bundleID: String?, recordedBundle: String?) -> Bool {
            let lexical = source.standardizedFileURL.path
            let canonical = source.resolvingSymlinksInPath().path
            guard lexical.hasPrefix(homePath + "/") || canonical.hasPrefix(canonicalHomePath + "/") else { return false }
            if let bundleID, recordedBundle == bundleID { return true }
            guard recordedBundle == nil, let bundleID else { return false }
            let root = homeDir.appendingPathComponent("Library/Containers/" + bundleID).standardizedFileURL.path
            let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            return lexical == root || lexical.hasPrefix(root + "/")
                || canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/")
        }

        for app in apps where !app.isFolder {
            guard !Task.isCancelled else { break }
            let bundleID: String?
            var appHasReadIssue = hasGlobalStoreError || hasRootReadIssue
            switch AppIdentityResolver.resolve(at: app.displayURL) {
            case .success(let resolved):
                bundleID = resolved.bundleIdentifier
            case .failure:
                bundleID = nil
                appHasReadIssue = true
            }

            let appName = app.displayName.replacingOccurrences(of: ".app", with: "")
            let matchProfile = buildMatchProfile(bundleID: bundleID, appName: appName)
            var resultsByPath: [String: DataDirItem] = [:]

            for config in configs {
                guard !Task.isCancelled else { break }
                if config.type == .containers {
                    if let bundleID,
                       let containerURL = containerExactMap[bundleID] ?? containerLowerMap[bundleID.lowercased()] {
                        let itemInspection = cachedInspectItem(at: containerURL, type: .containers)
                        var item = makeAppDataItem(
                            name: containerURL.lastPathComponent,
                            path: containerURL,
                            type: .containers,
                            priority: config.priority,
                            description: config.description,
                            appName: appName
                        )
                        applyInspectionResult(to: &item, inspection: itemInspection, externalRootURL: externalRootURL)
                        resultsByPath[item.id] = item
                    }
                    continue
                }

                if let entries = indexedLocalByType[config.type] {
                    for entry in entries where matchesIndexedDirectory(entry, profile: matchProfile) {
                        let itemInspection = cachedInspectItem(at: entry.url, type: config.type)
                        var item = makeAppDataItem(
                            name: entry.name,
                            path: entry.url,
                            type: config.type,
                            priority: config.priority,
                            description: config.description,
                            appName: appName
                        )
                        applyInspectionResult(to: &item, inspection: itemInspection, externalRootURL: externalRootURL)
                        resultsByPath[item.id] = item
                    }
                }

                if config.type != .groupContainers, let externalRoots = indexedExternalByType[config.type] {
                    for extRoot in externalRoots {
                        for entry in extRoot.entries where matchesIndexedDirectory(entry, profile: matchProfile) {
                            guard let localURL = mapExternalCandidate(entry.url, from: extRoot.baseURL, to: config.localBaseURL) else {
                                continue
                            }
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
                            item.status = DataDirStatus.pendingRelink
                            item.linkedDestination = entry.url.standardizedFileURL
                            resultsByPath[localKey] = item
                        }
                    }
                }
            }

            for specialItem in scanSpecialAssociatedDirs(for: app, bundleID: bundleID, appName: appName, externalRootURL: externalRootURL) {
                resultsByPath[specialItem.id] = specialItem
            }

            if let bundleID {
                let candidateMounts = (mountsByBundleID[bundleID] ?? []) + legacyMounts
                for record in candidateMounts {
                    let url = record.mountPointURL.standardizedFileURL
                    guard belongsToHome(url, bundleID: bundleID, recordedBundle: record.bundleIdentifier),
                          let type = DataDirType(rawValue: record.dataDirType) else { continue }
                    let itemInspection = cachedInspectItem(at: url, type: type)
                    var item = resultsByPath[url.path] ?? makeAppDataItem(
                        name: url.lastPathComponent,
                        path: url,
                        type: type,
                        priority: .critical,
                        description: "容器内部数据目录",
                        appName: appName
                    )
                    applyInspectionResult(to: &item, inspection: itemInspection, externalRootURL: externalRootURL)
                    resultsByPath[item.id] = item
                }

                let candidateLinks = (linksByBundleID[bundleID] ?? []) + legacyLinks
                for link in candidateLinks {
                    let source = URL(fileURLWithPath: link.originalPath).standardizedFileURL
                    guard belongsToHome(source, bundleID: bundleID, recordedBundle: link.bundleIdentifier),
                          let type = DataDirType(rawValue: link.dataDirType) else { continue }
                    let destination = URL(fileURLWithPath: link.destinationPath).standardizedFileURL
                    let itemInspection = cachedInspectItem(at: source, type: type)
                    var item = resultsByPath[source.path] ?? makeAppDataItem(
                        name: source.lastPathComponent,
                        path: source,
                        type: type,
                        priority: .critical,
                        description: "容器内部数据目录",
                        appName: appName
                    )
                    item.hasManagedLinkRecord = true
                    item.linkedDestination = destination
                    if itemInspection.linkedDestination?.standardizedFileURL == destination {
                        applyInspectionResult(to: &item, inspection: (DataDirStatus.linked, destination), externalRootURL: externalRootURL)
                    } else {
                        item.status = itemInspection.status
                    }
                    resultsByPath[item.id] = item
                }
            }

            let roots = deduplicateMeasurementRoots(Array(resultsByPath.values))
            var appTargets: [AppDataMeasurementTarget] = []
            appTargets.reserveCapacity(roots.count)
            for root in roots {
                guard let measurementURL = root.sizeMeasurementURL else { continue }
                let key = "\(measurementURL.standardizedFileURL.path)|\(isMountPoint(measurementURL) ? "mount" : "plain")"
                let isMigrated = DataDirDisplaySizeSummary.isMigratedItem(root)
                appTargets.append(AppDataMeasurementTarget(item: root, isMigrated: isMigrated, measurementKey: key))
                if uniqueTargets[key] == nil {
                    uniqueTargets[key] = root
                } else if DataDirStatus.mountStatuses.contains(root.status), root.status != DataDirStatus.mounted {
                    // 优先保留离线/待解锁挂载状态，避免同键被本地占位覆写。
                    uniqueTargets[key] = root
                }
            }
            targetsByAppID[app.id] = appTargets
            if appHasReadIssue {
                readIssueAppIDs.insert(app.id)
            }
        }

        let sizeCachePolicy = AppDataSizeCachePolicy(
            inspection: inspection,
            pausedMountDirectories: pausedMountDirectories,
            isMountPoint: isMountPoint
        )

        return AppDataBatchPlan(
            targetsByAppID: targetsByAppID,
            uniqueTargets: uniqueTargets,
            readIssueAppIDs: readIssueAppIDs,
            pausedMountDirectories: pausedMountDirectories,
            sizeCachePolicy: sizeCachePolicy
        )
    }

    /// 测量 `AppDataBatchPlan` 中的全部去重目标，并发限 2 路，每 250ms 批量向上层发布渐进结果。
    static func measureAppDataBatch(
        plan: AppDataBatchPlan,
        apps: [AppItem],
        priorityAppIDs: Set<String>,
        forceRefresh: Bool,
        cacheStore: ToolDirectorySizeCacheStore = .appDataDirectories,
        isMountPoint: @escaping @Sendable (URL) -> Bool = { DiskUtility.isMountPoint($0) },
        onBatchUpdate: @Sendable ([String: AppDataRowSizeSummary]) async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let cacheEpoch = cacheStore.currentEpoch()
        let snapshot = cacheStore.load()
        var stateByKey: [String: (bytes: Int64, isIncomplete: Bool)] = [:]
        var pendingKeys: [String] = []
        var appIDsByKey: [String: [String]] = [:]
        for (appID, targets) in plan.targetsByAppID {
            for target in targets {
                appIDsByKey[target.measurementKey, default: []].append(appID)
            }
        }

        let priorityKeys = Set(priorityAppIDs.flatMap { plan.targetsByAppID[$0]?.map(\.measurementKey) ?? [] })

        for (key, item) in plan.uniqueTargets {
            guard !Task.isCancelled else { return }
            if DataDirStatus.mountStatuses.contains(item.status), item.status != DataDirStatus.mounted {
                stateByKey[key] = (0, true)
                continue
            }
            guard let measurementURL = item.sizeMeasurementURL else {
                stateByKey[key] = (0, false)
                continue
            }
            let includesPausedMount = directoryIncludesPausedMount(at: measurementURL, pausedMountDirectories: plan.pausedMountDirectories)
            let cacheIdentity = plan.sizeCachePolicy.cacheIdentity(for: item)
            if !forceRefresh, !includesPausedMount, let cacheIdentity {
                let sourceKey = item.path.standardizedFileURL.path
                if let cached = snapshot.entries[sourceKey],
                   cached.identity == cacheIdentity {
                    stateByKey[key] = (cached.bytes, false)
                    continue
                }
                let memKey = sizeCacheKey(for: measurementURL.standardizedFileURL.path, isMountPoint: isMountPoint(measurementURL))
                if let memCached = MemoryDirectorySizeCache.shared.object(forKey: memKey) {
                    stateByKey[key] = (memCached.int64Value, false)
                    continue
                }
            }
            pendingKeys.append(key)
        }

        pendingKeys.sort { lhs, rhs in
            let lhsPriority = priorityKeys.contains(lhs)
            let rhsPriority = priorityKeys.contains(rhs)
            if lhsPriority != rhsPriority { return lhsPriority }
            return lhs < rhs
        }

        func buildSummary(for appID: String) -> AppDataRowSizeSummary {
            let targets = plan.targetsByAppID[appID] ?? []
            var localBytes: Int64 = 0
            var migratedBytes: Int64 = 0
            var hasMigrated = false
            var isIncomplete = plan.readIssueAppIDs.contains(appID)
            var isCalculating = false
            for target in targets {
                if target.isMigrated { hasMigrated = true }
                if let measured = stateByKey[target.measurementKey] {
                    if target.isMigrated {
                        migratedBytes += max(0, measured.bytes)
                    } else {
                        localBytes += max(0, measured.bytes)
                    }
                    if measured.isIncomplete { isIncomplete = true }
                } else {
                    isCalculating = true
                }
            }
            return AppDataRowSizeSummary(
                localBytes: localBytes,
                migratedBytes: migratedBytes,
                hasMigratedItems: hasMigrated,
                isIncomplete: isIncomplete,
                isCalculating: isCalculating
            )
        }

        let allAppIDs = apps.filter { !$0.isFolder }.map(\.id)
        var initialUpdates: [String: AppDataRowSizeSummary] = [:]
        initialUpdates.reserveCapacity(allAppIDs.count)
        for appID in allAppIDs {
            initialUpdates[appID] = buildSummary(for: appID)
        }
        await onBatchUpdate(initialUpdates)
        guard !Task.isCancelled, !pendingKeys.isEmpty else { return }

        var newCacheEntries: [ToolDirectorySizeCacheStore.Entry] = []
        var dirtyAppIDs: Set<String> = []
        var lastFlushNanos = DispatchTime.now().uptimeNanoseconds
        let flushIntervalNanos: UInt64 = 250_000_000

        await withTaskGroup(of: (String, DirectorySizeResult, ToolDirectorySizeCacheStore.Entry?).self) { group in
            var nextIndex = 0
            let maxConcurrency = 2

            func enqueueNext() {
                guard !Task.isCancelled, nextIndex < pendingKeys.count else { return }
                let key = pendingKeys[nextIndex]
                nextIndex += 1
                guard let item = plan.uniqueTargets[key],
                      let measurementURL = item.sizeMeasurementURL else { return }
                let paused = plan.pausedMountDirectories
                let sizeCachePolicy = plan.sizeCachePolicy
                let preIdentity = sizeCachePolicy.cacheIdentity(for: item)
                let cacheable = preIdentity != nil
                let includesPaused = directoryIncludesPausedMount(at: measurementURL, pausedMountDirectories: paused)
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else {
                        return (key, DirectorySizeResult(), nil)
                    }
                    let measured = measureDataDirectorySize(
                        for: item,
                        useCache: !forceRefresh && cacheable,
                        pausedMountDirectories: paused,
                        allowWriteToCache: cacheable
                    )
                    let entry: ToolDirectorySizeCacheStore.Entry?
                    if !includesPaused,
                       let preIdentity,
                       measured.isComplete,
                       let postIdentity = sizeCachePolicy.cacheIdentity(for: item),
                       postIdentity == preIdentity {
                        let sourceKey = item.path.standardizedFileURL.path
                        entry = .init(
                            identity: postIdentity,
                            sourcePath: sourceKey,
                            targetPath: measurementURL.resolvingSymlinksInPath().standardizedFileURL.path,
                            bytes: measured.bytes,
                            measuredAt: Date()
                        )
                    } else {
                        entry = nil
                    }
                    return (key, measured, entry)
                }
            }

            for _ in 0..<min(maxConcurrency, pendingKeys.count) {
                enqueueNext()
            }

            for await (key, measured, entry) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                stateByKey[key] = (measured.bytes, !measured.isComplete)
                if let entry {
                    newCacheEntries.append(entry)
                }
                for appID in appIDsByKey[key] ?? [] {
                    dirtyAppIDs.insert(appID)
                }
                let now = DispatchTime.now().uptimeNanoseconds
                if !dirtyAppIDs.isEmpty && now - lastFlushNanos >= flushIntervalNanos {
                    var payload: [String: AppDataRowSizeSummary] = [:]
                    payload.reserveCapacity(dirtyAppIDs.count)
                    for appID in dirtyAppIDs {
                        payload[appID] = buildSummary(for: appID)
                    }
                    dirtyAppIDs.removeAll(keepingCapacity: true)
                    lastFlushNanos = now
                    await onBatchUpdate(payload)
                }
                enqueueNext()
            }
        }

        if !newCacheEntries.isEmpty {
            cacheStore.merge(newCacheEntries, startedAtEpoch: cacheEpoch)
        }
        guard !Task.isCancelled else { return }
        if !dirtyAppIDs.isEmpty {
            var payload: [String: AppDataRowSizeSummary] = [:]
            payload.reserveCapacity(dirtyAppIDs.count)
            for appID in dirtyAppIDs {
                payload[appID] = buildSummary(for: appID)
            }
            await onBatchUpdate(payload)
        }
    }

    private func indexOneLevelContainers(
        in baseURL: URL,
        trackRootFailure: inout Bool
    ) -> (exact: [String: URL], lower: [String: URL]) {
        guard !Task.isCancelled, fileManager.fileExists(atPath: baseURL.path) else { return ([:], [:]) }
        let items: [URL]
        do {
            items = try fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            trackRootFailure = true
            return ([:], [:])
        }
        var exact: [String: URL] = [:]
        var lower: [String: URL] = [:]
        for itemURL in items {
            guard !Task.isCancelled else { break }
            var metadata = stat()
            guard lstat(itemURL.path, &metadata) == 0 else { continue }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFLNK) else { continue }
            let standardized = itemURL.standardizedFileURL
            let folderName = standardized.lastPathComponent
            exact[folderName] = standardized
            let lowerKey = folderName.lowercased()
            if lower[lowerKey] == nil { lower[lowerKey] = standardized }
        }
        return (exact, lower)
    }

    private func indexTwoLevels(in baseURL: URL, trackRootFailure: inout Bool) -> [IndexedDirectoryEntry] {
        guard !Task.isCancelled, fileManager.fileExists(atPath: baseURL.path) else { return [] }
        let firstLevel: [URL]
        do {
            firstLevel = try fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            trackRootFailure = true
            return []
        }

        var entries: [IndexedDirectoryEntry] = []
        var seen = Set<String>()

        func record(_ url: URL) -> Bool {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { return false }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFLNK) else { return false }
            if kind == mode_t(S_IFLNK), isRuntimeMetadataSymlink(at: url) { return false }
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                let name = standardized.lastPathComponent
                let compact = compactName(name)
                entries.append(IndexedDirectoryEntry(
                    url: standardized,
                    name: name,
                    compactName: compact,
                    lowercasedName: name.lowercased(),
                    lowercasedCompactName: compact.lowercased()
                ))
            }
            return kind == mode_t(S_IFDIR)
        }

        for firstURL in firstLevel {
            guard !Task.isCancelled else { break }
            guard record(firstURL) else { continue }
            guard let secondLevel = try? fileManager.contentsOfDirectory(
                at: firstURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for secondURL in secondLevel {
                guard !Task.isCancelled else { break }
                _ = record(secondURL)
            }
        }
        return entries
    }

    private func matchesIndexedDirectory(_ entry: IndexedDirectoryEntry, profile: AppMatchProfile) -> Bool {
        for exact in profile.exactMatches {
            if entry.name.localizedCaseInsensitiveCompare(exact) == .orderedSame {
                return true
            }
            if !entry.compactName.isEmpty && entry.compactName.localizedCaseInsensitiveCompare(exact) == .orderedSame {
                return true
            }
        }
        for needle in profile.containsMatches
            where entry.name.localizedCaseInsensitiveContains(needle)
                || entry.compactName.localizedCaseInsensitiveContains(needle) {
            return true
        }
        for prefix in profile.shortPrefixMatches {
            let lowered = prefix.lowercased()
            if entry.lowercasedName.hasPrefix(lowered) || entry.lowercasedCompactName.hasPrefix(lowered) {
                return true
            }
        }
        return false
    }

    private func deduplicateMeasurementRoots(_ items: [DataDirItem]) -> [DataDirItem] {
        let candidates = items.filter { !$0.isUserDirectoryLink }
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.id).inserted }
        return unique.filter { item in
            !unique.contains { parent in
                guard parent.id != item.id,
                      item.id.hasPrefix(parent.id == "/" ? "/" : parent.id + "/") else { return false }
                return item.linkedDestination == nil && !DataDirDisplaySizeSummary.isMigratedItem(item)
                    && parent.linkedDestination == nil && !DataDirStatus.mountStatuses.contains(parent.status)
                    && parent.weChatSplitMembers.isEmpty
            }
        }
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

    /// Restore checks use the verified original's identifiers. Product-name
    /// matching and the business browser's depth limit cannot prove absence.
    func scanSignatureDependencies(bundleIdentifier: String, applicationGroups: [String]) -> DataDirScanResult {
        readIssues = []
        volumeStateCache.removeAll(keepingCapacity: true)
        let containers = homeDir.appendingPathComponent("Library/Containers")
        let groups = homeDir.appendingPathComponent("Library/Group Containers")
        var roots: [(URL, DataDirType)] = []
        for (identifier, base, type) in [(bundleIdentifier, containers, DataDirType.containers)]
            + applicationGroups.map({ ($0, groups, DataDirType.groupContainers) }) {
            let root = base.appendingPathComponent(identifier).standardizedFileURL
            guard !identifier.isEmpty, identifier != ".", identifier != "..",
                  root.deletingLastPathComponent() == base.standardizedFileURL else {
                recordReadIssue(at: base, error: CocoaError(.fileReadCorruptFile))
                continue
            }
            roots.append((root, type))
        }
        var found: [String: DataDirItem] = [:]
        let policy = DataPathPolicy(homeDirectory: homeDir, partialWeChatMigrationEnabled: partialWeChatMigrationEnabled,
                                    weChatContainerIdentifier: weChatContainerIdentifier)
        func inspect(_ url: URL, type: DataDirType) -> Bool {
            let state = inspectItem(at: url, type: type)
            var item = makeAppDataItem(name: url.lastPathComponent, path: url, type: type,
                                      priority: .recommended, description: "容器内部数据目录", appName: bundleIdentifier)
            applyInspectionResult(to: &item, inspection: state, externalRootURL: nil)
            item.applyPathPolicy(policy.evaluate(url))
            found[item.id] = item
            return state.status == DataDirStatus.local && !isSymbolicLinkPath(at: url) && !isMountPoint(url)
        }
        for (root, type) in roots {
            var pending = [root]
            while let url = pending.popLast() {
                if Task.isCancelled {
                    recordReadIssue(at: url, error: CancellationError())
                    break
                }
                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true || values.isSymbolicLink == true else { continue }
                    if inspect(url, type: type) {
                        pending.append(contentsOf: directoryEntries(at: url, includeHidden: true))
                    }
                } catch { recordReadIssue(at: url, error: error) }
            }
        }
        do {
            let records = try mountStore.recordsForInspection()
            if let error = records.validationError { throw error }
            func root(for path: String) -> (URL, DataDirType)? {
                let path = URL(fileURLWithPath: path).standardizedFileURL.path
                return roots.first { path == $0.0.path || path.hasPrefix($0.0.path + "/") }
            }
            // Shared groups may be indexed under another application. Match
            // the original path, not the record's bundleIdentifier.
            for link in records.managedLinks {
                guard let (_, type) = root(for: link.originalPath) else { continue }
                let path = URL(fileURLWithPath: link.originalPath).standardizedFileURL
                _ = inspect(path, type: type)
                found[path.standardizedFileURL.path]?.hasManagedLinkRecord = true
            }
            for transfer in records.transfers where !transfer.isDataSwitchComplete {
                guard root(for: transfer.originalPath) != nil else { continue }
                recordReadIssue(at: URL(fileURLWithPath: transfer.originalPath),
                                error: ContainerMountStore.StoreError.conflict("Container transfer has not completed"))
            }
        } catch {
            recordReadIssue(at: homeDir.appendingPathComponent("Library/Application Support/AppPorts/container-mounts.plist"), error: error)
        }
        return DataDirScanResult(items: found.values.sorted { $0.id < $1.id }, readIssues: readIssues)
    }

    func scanLibraryDirsWithDiagnostics(for app: AppItem, externalRootURL: URL? = nil) -> DataDirScanResult {
        readIssues = []
        guard !Task.isCancelled else { return DataDirScanResult(items: [], readIssues: []) }
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
        volumeStateCache.removeAll(keepingCapacity: true)
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
            guard !Task.isCancelled else { return DataDirScanResult(items: [], readIssues: []) }
            // Ordinary sandbox containers are keyed by application identity. Product-name
            // similarities are insufficient evidence that another container belongs to this app.
            let localCandidates = config.type == .containers
                ? findExactAppContainer(in: config.localBaseURL, bundleID: bundleID)
                : findMatchingDirs(in: config.localBaseURL, matchProfile: matchProfile)

            for candidateURL in localCandidates {
                guard !Task.isCancelled else { return DataDirScanResult(items: [], readIssues: []) }
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
                guard !Task.isCancelled else { return DataDirScanResult(items: [], readIssues: []) }
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

        guard !Task.isCancelled else { return DataDirScanResult(items: [], readIssues: []) }
        for item in scanSpecialAssociatedDirs(for: app, bundleID: bundleID, appName: appName, externalRootURL: externalRootURL) {
            resultsByPath[item.path.standardizedFileURL.path] = item
        }

        // Persistent records remain visible even when the mount point is absent, deeply nested,
        // or outside the current discovery whitelist. Ownership was checked before caching them.
        for record in mountRecordsByPath.values {
            guard let type = DataDirType(rawValue: record.dataDirType) else { continue }
            let url = record.mountPointURL.standardizedFileURL
            if resultsByPath[url.path] != nil { continue }
            var item = makeAppDataItem(name: url.lastPathComponent, path: url, type: type,
                                      priority: .critical, description: "容器内部数据目录", appName: appName)
            applyInspectionResult(to: &item, inspection: inspectItem(at: url, type: type), externalRootURL: externalRootURL)
            resultsByPath[item.id] = item
        }

        mergeRecoveryRecords(into: &resultsByPath, bundleID: bundleID, appName: appName, externalRootURL: externalRootURL)

        let weChatPolicy = PartialWeChatMigrationPolicy(homeDirectory: homeDir, containerIdentifier: weChatContainerIdentifier)
        var coldAccounts: Set<String> = []
        if preferredWeChatSplitGroup == .filesAndVideos {
            for existing in resultsByPath.values where weChatPolicy.isAccount(existing.path) {
                coldAccounts.insert(existing.path.standardizedFileURL.path)
            }
        }
        for existing in resultsByPath.values {
            if let match = weChatPolicy.memberMatch(for: existing.path), match.group == .filesAndVideos {
                coldAccounts.insert(match.account.standardizedFileURL.path)
            }
        }
        for accountPath in coldAccounts {
            let accountURL = URL(fileURLWithPath: accountPath)
            for candidate in weChatPolicy.existingDirectoryMembers(of: accountURL, group: .filesAndVideos) {
                guard resultsByPath[candidate.path] == nil else { continue }
                var item = makeAppDataItem(
                    name: PartialWeChatMigrationPolicy.displayMemberLabel(for: candidate),
                    path: candidate,
                    type: .containers,
                    priority: .critical,
                    description: "容器内部数据目录",
                    appName: appName
                )
                applyInspectionResult(to: &item, inspection: inspectItem(at: candidate, type: .containers), externalRootURL: externalRootURL)
                resultsByPath[item.id] = item
            }
        }

        let policy = DataPathPolicy(homeDirectory: homeDir, partialWeChatMigrationEnabled: partialWeChatMigrationEnabled,
                                    weChatContainerIdentifier: weChatContainerIdentifier)
        for (key, item) in resultsByPath where item.type == .containers || item.type == .groupContainers {
            var updated = item
            if ![DataPathPolicy.Reason.runtimeConflict, .readFailure, .retainedOriginal].contains(where: { $0 == item.pathPolicy?.reason }) {
                updated.applyPathPolicy(policy.evaluate(item.path))
            }
            if recoveryInspection?.validationError != nil {
                updated.applyPathPolicy(.init(role: updated.pathPolicy?.role ?? .businessData, reason: .runtimeConflict,
                                              canMigrate: false, mayDiscoverChildren: false))
            }
            if readIssues.contains(where: { $0.requiresAttention && $0.url.standardizedFileURL == item.path.standardizedFileURL }) {
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
        let sizeCachePolicy = AppDataSizeCachePolicy(
            inspection: recoveryInspection,
            pausedMountDirectories: pausedMountDirectories,
            isMountPoint: isMountPoint
        )
        return DataDirScanResult(items: sortedResults, readIssues: readIssues, identityIssue: identityIssue,
                                 pausedMountDirectories: pausedMountDirectories,
                                 sizeCachePolicy: sizeCachePolicy)
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
        pausedMountDirectories = []
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
            // Offline guards hide external data even when automatic mounting is not paused.
            if recoveryInspection?.validationError == nil,
               !isMountPoint(url) || (try? mountStore.isManuallyUnmounted(record)) == true {
                pausedMountDirectories.insert(url)
                // Foundation may report the /private/var spelling for a /var fixture.
                // Resolve only the parent so the leaf cannot become a symlink exemption.
                pausedMountDirectories.insert(url.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(url.lastPathComponent).standardizedFileURL)
                if let issue = DataDirReadIssue.pausedMountIssue(at: url, pausedMountDirectories: pausedMountDirectories,
                                                               isMountPoint: isMountPoint) {
                    readIssues.append(issue)
                }
            }
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
            let role = DataPathPolicy(homeDirectory: homeDir, partialWeChatMigrationEnabled: partialWeChatMigrationEnabled,
                                    weChatContainerIdentifier: weChatContainerIdentifier).evaluate(item.path).role
            item.applyPathPolicy(.init(role: role, reason: .runtimeConflict, canMigrate: false, mayDiscoverChildren: false))
        }
        // A successful restore is usable local data. Its old copies can be
        // finished by the next migration workflow without reserving the row.
        // Only the exact restored entry qualifies; failed or replaced entries
        // still need their recovery records inspected.
        var completedRestores: [String: DataTransferRecord] = [:]
        if inspection.validationError == nil {
            let histories = Dictionary(grouping: inspection.transfers) {
                URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path
            }
            for (path, history) in histories {
                guard history.allSatisfy({ $0.isDataSwitchComplete }),
                      !inspection.managedLinks.contains(where: { $0.originalPath == path }),
                      !inspection.mounts.contains(where: { $0.mountPointPath == path }) else { continue }
                let terminals = history.filter { candidate in
                    !history.contains { $0.priorOperationID == candidate.operationID }
                }
                guard terminals.count == 1, let restored = terminals.first, restored.direction == .restore,
                      restored.activePath == path, restored.destinationPath == path,
                      let expected = restored.destinationIdentity,
                      let current = try? DataPathIdentity.capture(URL(fileURLWithPath: path)),
                      expected.matchesFilesystemObject(current),
                      !DiskUtility.isMountPoint(URL(fileURLWithPath: path)),
                      (try? fileManager.destinationOfSymbolicLink(atPath: path)) == nil else { continue }
                completedRestores[path] = restored
            }
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
            item.recoveryOperationID = completedRestores[source.path]?.operationID ?? transfer.operationID
            item.hasMountTransferRecord = item.hasMountTransferRecord || transfer.mode == .mount
            item.hasCompletedRestore = completedRestores[source.path] != nil
            // Retention is a separate housekeeping task after a completed
            // restore. The execution workflow verifies and finishes its lineage
            // before reusing an old destination.
            if transfer.isDataSwitchComplete,
               item.pathPolicy?.reason != .runtimeConflict, item.pathPolicy?.reason != .readFailure {
                let policy = DataPathPolicy(homeDirectory: homeDir, partialWeChatMigrationEnabled: partialWeChatMigrationEnabled,
                                    weChatContainerIdentifier: weChatContainerIdentifier).evaluate(item.path)
                let canContinue = item.hasCompletedRestore && item.status == DataDirStatus.local
                item.applyPathPolicy(.init(role: policy.role, reason: .retainedOriginal,
                                           canMigrate: canContinue && policy.canMigrate, mayDiscoverChildren: false))
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
        let policy = DataPathPolicy(homeDirectory: homeDir, partialWeChatMigrationEnabled: partialWeChatMigrationEnabled,
                                    weChatContainerIdentifier: weChatContainerIdentifier)
        var results: [DataDirItem] = []

        func visit(_ url: URL, depth: Int) {
            guard !Task.isCancelled else { return }
            let inspection = inspectItem(at: url, type: type)
            let decision = policy.evaluate(url)
            var item = makeAppDataItem(name: containerRelativeSuffix(of: url, in: rootURL), path: url,
                                      type: type, priority: priority, description: "容器内部数据目录", appName: appName)
            applyInspectionResult(to: &item, inspection: inspection, externalRootURL: externalRootURL)
            item.applyPathPolicy(decision)
            // Ordinary sandbox convenience links point at user folders and are not app data.
            // Top-level personal folder shortcuts stay as hidden non-actionable rows, while
            // Data/Library/* sandbox links are omitted at scan time even under WeChat's locked
            // compatibility policy. Protected/managed links remain visible for diagnosis and recovery.
            if inspection.status == DataDirStatus.existingSymlink, !item.isPersonalFolderShortcut,
               let target = inspection.linkedDestination,
               item.isUserDirectoryLink
                   || (decision.canMigrate && !shouldSurfaceNestedContainerLink(from: url, to: target, externalRootURL: externalRootURL)) {
                return
            }
            results.append(item)
            guard inspection.status == DataDirStatus.local,
                  !isSymbolicLinkPath(at: url), !isMountPoint(url),
                  decision.mayDiscoverChildren, depth < 5 else { return }
            let entries = directoryEntries(at: url)
            for child in entries {
                if isSymbolicLinkPath(at: child), isRuntimeMetadataSymlink(at: child) { continue }
                if PartialWeChatMigrationPolicy(homeDirectory: homeDir, containerIdentifier: weChatContainerIdentifier).isAccount(url),
                   !PartialWeChatMigrationPolicy.memberNames.contains(child.lastPathComponent) { continue }
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
        item.autoMountPaused = mountRecord(for: item.path).map { (try? mountStore.isManuallyUnmounted($0)) == true } ?? false
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
                name: String(format: "Conda 安装目录：%@".localized, candidateURL.lastPathComponent),
                path: candidateURL,
                type: .custom,
                priority: .critical,
                description: "Conda Python 发行版根目录（包含解释器、包、环境和 Navigator 相关文件）".localized,
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

    /// Discover at most two levels without letting a recursive enumerator open deeper nodes.
    private func findMatchingDirs(in baseURL: URL, matchProfile: AppMatchProfile) -> [URL] {
        guard !Task.isCancelled, fileManager.fileExists(atPath: baseURL.path) else { return [] }
        var matched: [URL] = []

        func recordRelatedReadIssue(at url: URL, error: Error) {
            let path = url.standardizedFileURL.path
            if path == baseURL.standardizedFileURL.path
                || matched.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") })
                || matchesDirectoryName(url.lastPathComponent, profile: matchProfile) {
                recordReadIssue(at: url, error: error)
            }
        }

        func entries(in directory: URL) -> [URL] {
            guard !Task.isCancelled else { return [] }
            do {
                // Do not prefetch metadata for unrelated files, sockets or named pipes.
                return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])
            } catch {
                // Preserve diagnostics for the search root and matching app directories only.
                recordRelatedReadIssue(at: directory, error: error)
                return []
            }
        }

        func inspect(_ url: URL) -> Bool {
            guard !Task.isCancelled else { return false }
            // Read the entry itself without opening special files or following links.
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                recordRelatedReadIssue(at: url, error: error)
                return false
            }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFLNK) else { return false }
            if kind == mode_t(S_IFLNK), isRuntimeMetadataSymlink(at: url) { return false }
            if matchesDirectoryName(url.lastPathComponent, profile: matchProfile) {
                matched.append(url)
            }
            return kind == mode_t(S_IFDIR)
        }

        for firstLevelURL in entries(in: baseURL) {
            guard !Task.isCancelled else { return [] }
            guard inspect(firstLevelURL) else { continue }
            for secondLevelURL in entries(in: firstLevelURL) {
                guard !Task.isCancelled else { return [] }
                _ = inspect(secondLevelURL)
            }
        }
        return deduplicate(urls: matched)
    }

    /// Chromium / Electron 系应用使用符号链接原子性存储运行版本号、实例锁与套接字路径，
    /// 并非可迁移的用户数据目录（例如 `RunningChromeVersion -> 157.0.4341.60:1`）。
    private func isRuntimeMetadataSymlink(at url: URL) -> Bool {
        guard let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let standardizedPath = url.standardizedFileURL.path
        let hasRecordedLink = recoveryInspection?.managedLinks.contains {
            URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path == standardizedPath
        } ?? false
        if hasRecordedLink { return false }
        if Self.ignoredRuntimeMetadataSymlinkNames.contains(url.lastPathComponent) {
            return true
        }
        // 纯单段字符串且不包含路径分隔符的悬空软链（如进程锁 `hostname-pid` 或版本号标记）
        // 并非指向外置盘或其它目录的数据迁移链接；指向 `/Volumes/...` 或 `../...` 的离线外置软链仍保留。
        guard !rawTarget.contains("/") else { return false }
        let resolved = URL(fileURLWithPath: rawTarget, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        var targetStat = stat()
        return lstat(resolved.path, &targetStat) != 0
    }

    private func directoryEntries(at baseURL: URL, includeHidden: Bool = false) -> [URL] {
        guard !Task.isCancelled else { return [] }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: includeHidden ? [] : .skipsHiddenFiles
            )
        } catch {
            recordReadIssue(at: baseURL, error: error)
            return []
        }

        // Foundation can enumerate /var through its /private/var alias. Keep
        // the inspected entry's spelling so diagnostics and stored links share
        // one key, without resolving the entry's own symbolic link.
        let entries = includeHidden ? contents.map {
            baseURL.appendingPathComponent($0.lastPathComponent, isDirectory: false).standardizedFileURL
        } : contents
        return entries.filter { itemURL in
            guard !Task.isCancelled else { return false }
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
        let issue = DataDirReadIssue(url: url, error: error, pausedMountDirectories: pausedMountDirectories,
                                     isMountPoint: isMountPoint)
        if let existing = readIssues.firstIndex(where: { $0.url == issue.url }) {
            guard issue.requiresAttention, !readIssues[existing].requiresAttention else { return }
            readIssues[existing] = issue
        } else {
            readIssues.append(issue)
        }
        guard issue.requiresAttention else { return }
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

    private func volumeState(for volumeUUID: String) -> DiskUtility.VolumePresenceAndLockState {
        let key = volumeUUID.uppercased()
        if let cached = volumeStateCache[key] {
            return cached
        }
        let state: DiskUtility.VolumePresenceAndLockState
        if isVolumeOnlineOverride == nil && isVolumeLockedOverride == nil {
            state = DiskUtility.volumePresenceAndLockState(volumeUUID)
        } else {
            let online = (isVolumeOnlineOverride ?? { DiskUtility.isVolumeOnline($0) })(volumeUUID)
            let locked = online ? (isVolumeLockedOverride ?? { DiskUtility.isVolumeLocked($0) })(volumeUUID) : false
            state = DiskUtility.VolumePresenceAndLockState(isOnline: online, isLocked: locked)
        }
        volumeStateCache[key] = state
        return state
    }

    /// 检测目录当前状态，并区分 AppPorts 受管链接、挂载迁移项和已有符号链接。
    private func inspectItem(at url: URL, type: DataDirType) -> (status: String, linkedDestination: URL?) {
        if let record = mountRecord(for: url) {
            if isMountPoint(url) {
                return (DataDirStatus.mounted, nil)
            }
            let volume = volumeState(for: record.volumeUUID)
            guard volume.isOnline else { return (DataDirStatus.volumeMissing, nil) }
            if record.isEncrypted == true, volume.isLocked {
                return (DataDirStatus.waitingForUnlock, nil)
            }
            return (DataDirStatus.pendingMount, nil)
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
