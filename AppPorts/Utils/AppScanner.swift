//
//  AppScanner.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation

// MARK: - 应用扫描器

/// 异步应用扫描工具
///
/// 使用 Actor 模型在后台线程扫描应用程序目录，识别应用状态、类型和大小。
/// 该工具能够检测：
/// - 本地应用和外部存储应用
/// - 符号链接状态（标准符号链接和深层符号链接）
/// - App Store 应用（包含 _MASReceipt 目录）
/// - iOS 应用（运行在 Apple Silicon Mac 上的 iPhone/iPad 应用）
/// - 正在运行的应用
/// - 系统应用
///
/// ## 使用示例
/// ```swift
/// let scanner = AppScanner()
/// let apps = await scanner.scanLocalApps(
///     at: URL(fileURLWithPath: "/Applications"),
///     runningAppURLs: runningApps
/// )
/// ```
///
/// - Note: 使用 Actor 确保所有扫描操作在后台线程串行执行，不阻塞 UI
actor AppScanner {
    private struct ScanCandidate {
        let app: AppItem
        let dedupeKey: String
        let priority: Int
    }

    enum AppSizeMode {
        /// 解析到真实 bundle 或目录后计算内容体积。
        case logicalContent
        /// 保留本地入口结构，仅统计 symlink 或 wrapper 自身占用。
        case localPortal
    }
    
    // MARK: - 公共 API
    
    /// 计算目录大小
    ///
    /// 递归计算目录树的总大小。
    ///
    /// - Parameter url: 目录 URL
    /// - Returns: 目录总大小（字节）
    ///
    /// - Note:
    ///   - 普通目录：跳过内部符号链接，避免重复计算
    ///   - `.app` 包：会尽量解析入口 symlink 或 `Contents` 深层链接，得到真实体积
    func calculateDirectorySize(at url: URL, mode: AppSizeMode = .logicalContent) -> Int64 {
        let fileManager = FileManager.default
        var size: Int64 = 0
        let scanURL: URL
        let countsSymlinkEntries: Bool

        switch mode {
        case .logicalContent:
            scanURL = resolveSizeCalculationURL(for: url)
            countsSymlinkEntries = false
        case .localPortal:
            scanURL = url
            countsSymlinkEntries = true
        }

        guard fileManager.fileExists(atPath: scanURL.path) else { return 0 }
        
        // 需要获取的资源键
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey]

        if let rootValues = try? scanURL.resourceValues(forKeys: Set(resourceKeys)) {
            if case .localPortal = mode, rootValues.isSymbolicLink == true {
                return Int64(rootValues.fileSize ?? 0)
            }

            if rootValues.isDirectory != true {
                return Int64(rootValues.fileSize ?? 0)
            }
        }
        
        // 创建目录枚举器（深度优先遍历）
        guard let enumerator = fileManager.enumerator(
            at: scanURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles], // 跳过隐藏文件提升性能
            errorHandler: nil
        ) else { return 0 }
        
        // 累加所有文件大小
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            if resourceValues?.isSymbolicLink == true {
                if countsSymlinkEntries {
                    size += Int64(resourceValues?.fileSize ?? 0)
                }
                continue
            }
            if let fileSize = resourceValues?.fileSize { size += Int64(fileSize) }
        }
        return size
    }

    /// 根据显示场景选择应用体积计算方式。
    ///
    /// 本地列表中的“已链接”应用应显示本地入口大小，避免看起来像在本地保留了一整份实体副本。
    func calculateDisplayedSize(for app: AppItem, isLocalEntry: Bool) -> Int64 {
        let mode: AppSizeMode = (isLocalEntry && app.status == "已链接") ? .localPortal : .logicalContent
        return calculateDirectorySize(at: app.path, mode: mode)
    }
    
    /// 扫描本地应用目录
    ///
    /// 扫描指定目录（通常是 /Applications），识别所有 .app 包并检测其状态。
    ///
    /// - Parameters:
    ///   - dir: 要扫描的目录 URL
    ///   - runningAppURLs: 当前正在运行的应用 URL 集合
    ///
    /// - Returns: 应用列表，按链接状态和名称排序
    ///
    /// - Note: 检测逻辑包括：
    ///   - 符号链接检测（标准 symlink 和深层 symlink）
    ///   - 系统应用识别（路径以 /System 开头）
    ///   - 运行状态检测
    ///   - App Store 应用和 iOS 应用检测
    func scanLocalApps(at dir: URL, runningAppURLs: Set<URL>) -> [AppItem] {
        let scanID = AppLogger.shared.makeOperationID(prefix: "app-scanner-local")
        AppLogger.shared.logContext(
            "AppScanner 开始扫描本地应用",
            details: [
                ("scan_id", scanID),
                ("directory", dir.path),
                ("running_app_count", String(runningAppURLs.count))
            ],
            level: "TRACE"
        )
        let fileManager = FileManager.default
        var candidates: [ScanCandidate] = []
        
        // 性能优化：预先获取需要的资源键
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let items = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        
        for itemURL in items {
            // 只处理 .app 扩展名的项目
            if itemURL.pathExtension == "app" {
                let appName = itemURL.lastPathComponent
                let status = detectLocalAppStatus(at: itemURL)
                let isSystem = itemURL.path.hasPrefix("/System")
                let isRunning = runningAppURLs.contains(itemURL)
                
                // 检测是否为 App Store 应用和 iOS 应用
                let (isAppStore, isIOS) = detectAppStoreAndIOSApp(at: itemURL)
                let isResigned = checkResignedStatus(bundleURL: itemURL)
                let (isElectron, isSparkle) = detectElectronAndSparkle(at: itemURL)
                let hasUpdater = isSparkle || (isElectron && hasElectronUpdater(at: itemURL)) || hasCustomUpdater(at: itemURL)
                let needsLock = isSparkle || (isElectron && hasElectronUpdater(at: itemURL))
                let app = AppItem(
                    name: appName,
                    path: itemURL,
                    bundleURL: itemURL,
                    status: status,
                    isSystemApp: isSystem,
                    isRunning: isRunning,
                    isAppStoreApp: isAppStore,
                    isIOSApp: isIOS,
                    isResigned: isResigned,
                    isElectronApp: isElectron,
                    isSparkleApp: isSparkle,
                    hasSelfUpdater: hasUpdater,
                    needsLock: needsLock,
                    containerKind: .standaloneApp
                )
                candidates.append(makeCandidate(for: app, bundleURL: itemURL, priority: 10))
            }
            // 处理包含 .app 的文件夹（包括迁移后的“文件夹 symlink -> 外部单应用容器”）
            else {
                let appsInFolder = appBundlesInsideFolderPortal(at: itemURL)

                if !appsInFolder.isEmpty {
                    let folderName = itemURL.lastPathComponent
                    let appCount = appsInFolder.count
                    let status = detectLocalFolderStatus(at: itemURL)

                    let hasRunning = appsInFolder.contains { bundleURL in
                        runningAppURLs.contains(bundleURL)
                            || runningAppURLs.contains(itemURL.appendingPathComponent(bundleURL.lastPathComponent))
                    }

                    if appCount == 1, let bundleURL = appsInFolder.first {
                        let (isAppStore, isIOS) = detectAppStoreAndIOSApp(at: bundleURL)
                        let isResigned = checkResignedStatus(bundleURL: bundleURL)
                        let app = AppItem(
                            name: folderName,
                            path: itemURL,
                            bundleURL: bundleURL,
                            status: status,
                            isSystemApp: false,
                            isRunning: hasRunning,
                            isAppStoreApp: isAppStore,
                            isIOSApp: isIOS,
                            isResigned: isResigned,
                            containerKind: .singleAppContainer,
                            appCount: 1
                        )
                        candidates.append(makeCandidate(for: app, bundleURL: bundleURL, priority: 30))
                    } else {
                        let app = AppItem(
                            name: folderName,
                            path: itemURL,
                            status: status,
                            isSystemApp: false,
                            isRunning: hasRunning,
                            isFolder: true,
                            containerKind: .appSuiteFolder,
                            appCount: appCount
                        )
                        candidates.append(makeCandidate(for: app, bundleURL: itemURL, priority: 20))
                    }
                }
            }
        }
        let sortedApps = sortApps(deduplicate(candidates))
        AppLogger.shared.logContext(
            "AppScanner 完成本地应用扫描",
            details: [
                ("scan_id", scanID),
                ("count", String(sortedApps.count)),
                ("statuses", Dictionary(grouping: sortedApps, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")),
                ("running_count", String(sortedApps.filter(\.isRunning).count))
            ],
            level: "TRACE"
        )
        return sortedApps
    }
    
    // MARK: - 私有辅助方法

    /// 检测本地 `.app` 的显示状态。
    ///
    /// 规则：
    /// - AppPorts 创建的跨卷链接：显示为“已链接”
    /// - 安装器自带的同卷入口 symlink（如 `/Applications` -> `/opt/anaconda3/...`）：仍视为“本地”
    private func detectLocalAppStatus(at appURL: URL) -> String {
        let fm = FileManager.default

        // wholeAppSymlink：整个 .app 是符号链接
        if let linkDest = resolveSymlinkDestination(of: appURL) {
            if isCrossVolumeLink(fromPortalAt: appURL, to: linkDest) {
                return fm.fileExists(atPath: linkDest.path) ? "已链接" : "孤立链接"
            }
            return "本地"
        }

        let contentsURL = appURL.appendingPathComponent("Contents")

        // deepContentsWrapper：Contents/ 是符号链接
        if let linkDest = resolveSymlinkDestination(of: contentsURL) {
            if isCrossVolumeLink(fromPortalAt: appURL, to: linkDest) {
                return fm.fileExists(atPath: linkDest.path) ? "已链接" : "孤立链接"
            }
            return "本地"
        }

        // 旧版混合入口：MacOS/Resources/Frameworks 是符号链接
        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        if let linkDest = resolveSymlinkDestination(of: macOSURL) {
            if isCrossVolumeLink(fromPortalAt: appURL, to: linkDest) {
                return fm.fileExists(atPath: linkDest.path) ? "已链接" : "孤立链接"
            }
            return "本地"
        }
        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        if let linkDest = resolveSymlinkDestination(of: resourcesURL) {
            if isCrossVolumeLink(fromPortalAt: appURL, to: linkDest) {
                return fm.fileExists(atPath: linkDest.path) ? "已链接" : "孤立链接"
            }
            return "本地"
        }
        let frameworksURL = contentsURL.appendingPathComponent("Frameworks")
        if let linkDest = resolveSymlinkDestination(of: frameworksURL) {
            if isCrossVolumeLink(fromPortalAt: appURL, to: linkDest) {
                return fm.fileExists(atPath: linkDest.path) ? "已链接" : "孤立链接"
            }
            return "本地"
        }

        // Stub Portal：检查 launcher 引用的外部 app 是否存在
        let launcherPath = contentsURL.appendingPathComponent("MacOS/launcher")
        if fm.fileExists(atPath: launcherPath.path) {
            // 原生 launcher：从 real_app_path.txt 读取
            let pathFile = contentsURL.appendingPathComponent("Resources/real_app_path.txt")
            if let raw = try? String(contentsOf: pathFile, encoding: .utf8) {
                let realPath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !realPath.isEmpty {
                    return fm.fileExists(atPath: realPath) ? "已链接" : "孤立链接"
                }
            }
            // 旧版 bash launcher：提取 REAL_APP='...'
            if let script = try? String(contentsOf: launcherPath, encoding: .utf8) {
                if let range = script.range(of: "REAL_APP='") {
                    let afterQuote = script[range.upperBound...]
                    if let endQuote = afterQuote.range(of: "'") {
                        let realAppPath = String(afterQuote[..<endQuote.lowerBound])
                        return fm.fileExists(atPath: realAppPath) ? "已链接" : "孤立链接"
                    }
                }
            }
        }

        return "本地"
    }

    private func detectLocalFolderStatus(at folderURL: URL) -> String {
        if let linkDest = resolveSymlinkDestination(of: folderURL) {
            return FileManager.default.fileExists(atPath: linkDest.path) ? "已链接" : "孤立链接"
        }

        return "本地"
    }

    /// 为体积计算解析真实目标。
    ///
    /// 支持两类结构：
    /// - `/Applications/Foo.app -> /somewhere/Foo.app`
    /// - 本地空壳 `.app`，其 `Contents`/`MacOS`/`Resources` 指向外部真实 bundle
    private func resolveSizeCalculationURL(for url: URL) -> URL {
        if let rootTarget = resolveSymlinkDestination(of: url) {
            return enclosingAppBundleURL(for: rootTarget)
        }

        guard url.pathExtension == "app" else { return url }

        let contentsURL = url.appendingPathComponent("Contents")
        if let contentsTarget = resolveSymlinkDestination(of: contentsURL) {
            return enclosingAppBundleURL(for: contentsTarget)
        }

        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        if let macOSTarget = resolveSymlinkDestination(of: macOSURL) {
            return enclosingAppBundleURL(for: macOSTarget)
        }

        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        if let resourcesTarget = resolveSymlinkDestination(of: resourcesURL) {
            return enclosingAppBundleURL(for: resourcesTarget)
        }

        let frameworksURL = contentsURL.appendingPathComponent("Frameworks")
        if let frameworksTarget = resolveSymlinkDestination(of: frameworksURL) {
            return enclosingAppBundleURL(for: frameworksTarget)
        }

        // Stub Portal：从 real_app_path.txt 或 bash launcher 解析外部 app
        if let externalTarget = resolveExternalRealApp(from: url) {
            return externalTarget
        }

        return url
    }

    private func resolveSymlinkDestination(of url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let rawPath = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }

        let parent = url.deletingLastPathComponent()
        return URL(fileURLWithPath: rawPath, relativeTo: parent).standardizedFileURL
    }

    private func isLocalApp(_ localAppURL: URL, linkedTo externalAppURL: URL) -> Bool {
        let standardizedExternalAppURL = externalAppURL.standardizedFileURL

        if let linkDestination = resolveSymlinkDestination(of: localAppURL),
           linkDestination == standardizedExternalAppURL {
            return true
        }

        let localContentsURL = localAppURL.appendingPathComponent("Contents")
        if let contentsDestination = resolveSymlinkDestination(of: localContentsURL),
           contentsDestination == standardizedExternalAppURL.appendingPathComponent("Contents").standardizedFileURL {
            return true
        }

        // 旧版混合入口：MacOS/Resources/Frameworks 是符号链接
        let localMacOS = localContentsURL.appendingPathComponent("MacOS")
        if let macOSDestination = resolveSymlinkDestination(of: localMacOS),
           macOSDestination == standardizedExternalAppURL.appendingPathComponent("Contents/MacOS").standardizedFileURL {
            return true
        }
        let localResources = localContentsURL.appendingPathComponent("Resources")
        if let resourcesDestination = resolveSymlinkDestination(of: localResources),
           resourcesDestination == standardizedExternalAppURL.appendingPathComponent("Contents/Resources").standardizedFileURL {
            return true
        }
        let localFrameworks = localContentsURL.appendingPathComponent("Frameworks")
        if let frameworksDestination = resolveSymlinkDestination(of: localFrameworks),
           frameworksDestination == standardizedExternalAppURL.appendingPathComponent("Contents/Frameworks").standardizedFileURL {
            return true
        }

        // Stub Portal：检查 launcher 引用的外部 app 路径
        let launcherPath = localContentsURL.appendingPathComponent("MacOS/launcher")
        if FileManager.default.fileExists(atPath: launcherPath.path) {
            // 原生 launcher：从 real_app_path.txt 读取
            let pathFile = localContentsURL.appendingPathComponent("Resources/real_app_path.txt")
            if let raw = try? String(contentsOf: pathFile, encoding: .utf8) {
                let realPath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !realPath.isEmpty && realPath == standardizedExternalAppURL.path {
                    return true
                }
            }
            // 旧版 bash launcher：检查脚本内容
            if let script = try? String(contentsOf: launcherPath, encoding: .utf8),
               script.contains(standardizedExternalAppURL.path) {
                return true
            }
        }

        return false
    }

    private func isLocalFolder(_ localFolderURL: URL, linkedTo externalFolderURL: URL) -> Bool {
        guard let linkDestination = resolveSymlinkDestination(of: localFolderURL) else {
            return false
        }

        return linkDestination == externalFolderURL.standardizedFileURL
    }

    private func appBundlesInsideFolderPortal(at folderURL: URL) -> [URL] {
        let inspectURL: URL

        if let resourceValues = try? folderURL.resourceValues(forKeys: [.isDirectoryKey]),
           resourceValues.isDirectory == true {
            inspectURL = folderURL
        } else if let linkDestination = resolveSymlinkDestination(of: folderURL),
                  let targetValues = try? linkDestination.resourceValues(forKeys: [.isDirectoryKey]),
                  targetValues.isDirectory == true {
            inspectURL = linkDestination
        } else {
            return []
        }

        let folderContents = (try? FileManager.default.contentsOfDirectory(at: inspectURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folderContents.filter { $0.pathExtension == "app" }
    }

    private func externalTargetForLocalApp(at localAppURL: URL) -> URL? {
        if let linkDestination = resolveSymlinkDestination(of: localAppURL) {
            return linkDestination
        }

        let contentsURL = localAppURL.appendingPathComponent("Contents")
        if let contentsDestination = resolveSymlinkDestination(of: contentsURL) {
            return enclosingAppBundleURL(for: contentsDestination)
        }

        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        if let macOSDestination = resolveSymlinkDestination(of: macOSURL) {
            return enclosingAppBundleURL(for: macOSDestination)
        }

        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        if let resourcesDestination = resolveSymlinkDestination(of: resourcesURL) {
            return enclosingAppBundleURL(for: resourcesDestination)
        }

        let frameworksURL = contentsURL.appendingPathComponent("Frameworks")
        if let frameworksDestination = resolveSymlinkDestination(of: frameworksURL) {
            return enclosingAppBundleURL(for: frameworksDestination)
        }

        // Stub Portal：从 real_app_path.txt 或 bash launcher 提取外部路径
        let launcherPath = contentsURL.appendingPathComponent("MacOS/launcher")
        if FileManager.default.fileExists(atPath: launcherPath.path) {
            if let resolved = resolveExternalRealApp(from: localAppURL) {
                return resolved
            }
        }

        return nil
    }

    private func isDescendantOrSame(_ url: URL, under root: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL.path
        let normalizedRoot = root.standardizedFileURL.path

        if normalizedURL == normalizedRoot {
            return true
        }

        return normalizedURL.hasPrefix(normalizedRoot + "/")
    }

    private func enclosingAppBundleURL(for url: URL) -> URL {
        var candidate = url.standardizedFileURL

        while true {
            if candidate.pathExtension == "app" {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return url.standardizedFileURL
            }
            candidate = parent
        }
    }

    private func isCrossVolumeLink(fromPortalAt portalURL: URL, to destinationURL: URL) -> Bool {
        let sourceValues = try? portalURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey])
        let destValues = try? destinationURL.resourceValues(forKeys: [.volumeIdentifierKey])

        let sourceVolumeID = sourceValues?.allValues[.volumeIdentifierKey]
        let destVolumeID = destValues?.allValues[.volumeIdentifierKey]

        if let sourceVolumeID, let destVolumeID {
            return String(describing: sourceVolumeID) != String(describing: destVolumeID)
        }

        return destinationURL.standardizedFileURL.path.hasPrefix("/Volumes/")
    }
    
    /// 检测是否为 App Store 应用和 iOS 应用
    ///
    /// 通过检查以下标识来判断应用类型：
    /// 1. _MASReceipt 目录（Mac App Store 收据）
    /// 2. Info.plist 中的 UIDeviceFamily（iOS 应用标识）
    /// 3. WrappedBundle 目录（iOS 应用容器）
    ///
    /// - Parameter appURL: 应用包 URL
    /// - Returns: (isAppStore: 是否为 App Store 应用, isIOS: 是否为 iOS 应用)
    ///
    /// - Note: iOS 应用通常同时也是 App Store 应用
    private func detectAppStoreAndIOSApp(at appURL: URL) -> (isAppStore: Bool, isIOS: Bool) {
        let fileManager = FileManager.default
        
        // 1. 检测 _MASReceipt（Mac App Store 收据目录）
        let receiptURL = appURL.appendingPathComponent("Contents/_MASReceipt")
        let hasMASReceipt = fileManager.fileExists(atPath: receiptURL.path)
        
        // 2. 检测 WrappedBundle（iOS 应用容器）
        let wrappedBundleURL = appURL.appendingPathComponent("WrappedBundle")
        let hasWrappedBundle = fileManager.fileExists(atPath: wrappedBundleURL.path)
        
        var isIOSApp = false
        var isAppStore = hasMASReceipt
        
        // 3. 解析 Info.plist 检测 UIDeviceFamily
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let plistData = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
            
            // 检测 UIDeviceFamily（iOS 设备系列标识）
            // 1 = iPhone, 2 = iPad
            if let deviceFamily = plist["UIDeviceFamily"] as? [Int], !deviceFamily.isEmpty {
                isIOSApp = true
                isAppStore = true // iOS 应用必然来自 App Store
            }
            
            // 检测 DTCompiler（Xcode 编译器版本）
            // 某些 iOS 应用可能没有 UIDeviceFamily，但有 DTCompiler
            if let dtCompiler = plist["DTCompiler"] as? String,
               dtCompiler.contains("com.apple.compilers") {
                // 进一步检查是否为 iOS 平台
                if let platformName = plist["DTPlatformName"] as? String,
                   platformName == "iphoneos" {
                    isIOSApp = true
                    isAppStore = true
                }
            }
        }
        
        // 4. 如果有 WrappedBundle，肯定是 iOS 应用
        if hasWrappedBundle {
            isIOSApp = true
            isAppStore = true
        }
        
        return (isAppStore, isIOSApp)
    }

    /// 检测是否为 Electron 或 Sparkle 自更新应用
    private func detectElectronAndSparkle(at appURL: URL) -> (isElectron: Bool, isSparkle: Bool) {
        let fm = FileManager.default
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks")

        // Electron 检测
        var isElectron = false
        if fm.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path) {
            isElectron = true
        }
        if !isElectron, let items = try? fm.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            isElectron = items.contains { $0.lastPathComponent.contains("Electron Helper") }
        }
        if !isElectron, let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) {
            isElectron = plist["ElectronDefaultApp"] != nil || plist["electron"] != nil
        }

        // Sparkle 检测
        var isSparkle = false
        let sparkleFrameworks = ["Sparkle.framework", "Squirrel.framework"]
        for name in sparkleFrameworks {
            if fm.fileExists(atPath: frameworks.appendingPathComponent(name).path) {
                isSparkle = true
                break
            }
        }
        // 二进制文件名检测（仅对非 Electron 应用，避免 electron-updater 的 "updater" 误判）
        if !isSparkle && !isElectron {
            let updaterNames = ["shipit", "autoupdate", "updater", "update"]
            let searchRoots = [appURL.appendingPathComponent("Contents/MacOS"), frameworks]
            for root in searchRoots {
                let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                if items.contains(where: { item in
                    let name = item.lastPathComponent.lowercased()
                    return updaterNames.contains(where: { name.contains($0) })
                }) {
                    isSparkle = true
                    break
                }
            }
        }
        if !isSparkle, let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) {
            let sparkleKeys = ["SUFeedURL", "SUPublicDSAKeyFile", "SUPublicEDKey", "SUScheduledCheckInterval", "SUAllowsAutomaticUpdates"]
            isSparkle = sparkleKeys.contains { plist[$0] != nil }
        }

        return (isElectron, isSparkle)
    }

    /// 检测 Electron 应用是否有 electron-updater
    private func hasElectronUpdater(at appURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/app-update.yml").path)
    }

    /// 检测是否有自定义更新机制（非 Sparkle、非 Electron）
    private func hasCustomUpdater(at appURL: URL) -> Bool {
        let fm = FileManager.default
        let contents = appURL.appendingPathComponent("Contents")

        // 1. LaunchServices 特权助手（Chrome、Edge、Thunderbird 等）
        let launchServices = contents.appendingPathComponent("Library/LaunchServices")
        if let items = try? fm.contentsOfDirectory(at: launchServices, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            if items.contains(where: { $0.lastPathComponent.lowercased().contains("update") }) {
                return true
            }
        }

        // 2. MacOS/ 下的更新二进制（Parallels、Thunderbird 等）
        let macOS = contents.appendingPathComponent("MacOS")
        if let items = try? fm.contentsOfDirectory(at: macOS, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            if items.contains(where: {
                let name = $0.lastPathComponent.lowercased()
                return (name.contains("update") || name.contains("upgrade")) && !name.contains("electron")
            }) {
                return true
            }
        }

        // 3. SharedSupport/ 更新工具（wpsoffice 等）
        let sharedSupport = contents.appendingPathComponent("SharedSupport")
        if let items = try? fm.contentsOfDirectory(at: sharedSupport, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            if items.contains(where: { $0.lastPathComponent.lowercased().contains("update") }) {
                return true
            }
        }

        // 4. Keystone plist 键（Google Chrome）
        if let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
           plist["KSProductID"] != nil {
            return true
        }

        return false
    }

    /// 扫描外部存储目录
    ///
    /// 扫描外部存储设备上的应用目录，并检测这些应用是否已链接回本地。
    ///
    /// - Parameters:
    ///   - dir: 外部存储目录 URL
    ///   - localAppsDir: 本地应用目录 URL（通常是 /Applications）
    ///
    /// - Returns: 应用列表，按链接状态和名称排序
    ///
    /// - Note: 通过检查本地是否存在同名符号链接来判断应用是否已链接
    func scanExternalApps(at dir: URL, localAppsDir: URL) -> [AppItem] {
        let scanID = AppLogger.shared.makeOperationID(prefix: "app-scanner-external")
        AppLogger.shared.logContext(
            "AppScanner 开始扫描外部应用",
            details: [
                ("scan_id", scanID),
                ("directory", dir.path),
                ("local_apps_directory", localAppsDir.path)
            ],
            level: "TRACE"
        )
        let fileManager = FileManager.default
        var candidates: [ScanCandidate] = []
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let items = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        
        for itemURL in items {
            if itemURL.pathExtension == "app" {
                let appName = itemURL.lastPathComponent
                var status = "未链接"
                
                // 检查本地是否存在符号链接
                let localAppURL = localAppsDir.appendingPathComponent(appName)
                if fileManager.fileExists(atPath: localAppURL.path),
                   isLocalApp(localAppURL, linkedTo: itemURL) {
                    status = "已链接"
                }
                let isResigned = checkResignedStatus(bundleURL: itemURL)
                let (isElectron, isSparkle) = detectElectronAndSparkle(at: itemURL)
                let hasUpdater = isSparkle || (isElectron && hasElectronUpdater(at: itemURL)) || hasCustomUpdater(at: itemURL)
                let needsLock = isSparkle || (isElectron && hasElectronUpdater(at: itemURL))
                let app = AppItem(
                    name: appName,
                    path: itemURL,
                    bundleURL: itemURL,
                    status: status,
                    isSystemApp: false,
                    isRunning: false,
                    isResigned: isResigned,
                    isElectronApp: isElectron,
                    isSparkleApp: isSparkle,
                    hasSelfUpdater: hasUpdater,
                    needsLock: needsLock,
                    containerKind: .standaloneApp
                )
                candidates.append(makeCandidate(for: app, bundleURL: itemURL, priority: 10))
            }
            // 2. 处理包含 .app 的文件夹（如 Microsoft Office、Adobe Creative Cloud 等套件）
            else {
                let appsInFolder = appBundlesInsideFolderPortal(at: itemURL)

                if !appsInFolder.isEmpty {
                    let folderName = itemURL.lastPathComponent
                    let appCount = appsInFolder.count
                    let localFolderURL = localAppsDir.appendingPathComponent(folderName)

                    if appCount == 1, let bundleURL = appsInFolder.first {
                        var status = "未链接"
                        if fileManager.fileExists(atPath: localFolderURL.path),
                           isLocalFolder(localFolderURL, linkedTo: itemURL) {
                            status = "已链接"
                        } else {
                            let localAppURL = localAppsDir.appendingPathComponent(bundleURL.lastPathComponent)
                            if fileManager.fileExists(atPath: localAppURL.path),
                               isLocalApp(localAppURL, linkedTo: bundleURL) {
                                status = "已链接"
                            }
                        }

                        let (isAppStore, isIOS) = detectAppStoreAndIOSApp(at: bundleURL)
                        let isResigned = checkResignedStatus(bundleURL: bundleURL)
                        let app = AppItem(
                            name: folderName,
                            path: itemURL,
                            bundleURL: bundleURL,
                            status: status,
                            isSystemApp: false,
                            isRunning: false,
                            isAppStoreApp: isAppStore,
                            isIOSApp: isIOS,
                            isResigned: isResigned,
                            containerKind: .singleAppContainer,
                            appCount: 1
                        )
                        candidates.append(makeCandidate(for: app, bundleURL: bundleURL, priority: 30))
                    } else {
                        let status: String
                        if fileManager.fileExists(atPath: localFolderURL.path),
                           isLocalFolder(localFolderURL, linkedTo: itemURL) {
                            status = "已链接"
                        } else {
                            var linkedCount = 0
                            for appURL in appsInFolder {
                                let appName = appURL.lastPathComponent
                                let localAppURL = localAppsDir.appendingPathComponent(appName)
                                if fileManager.fileExists(atPath: localAppURL.path),
                                   isLocalApp(localAppURL, linkedTo: appURL) {
                                    linkedCount += 1
                                }
                            }

                            status = linkedCount == 0 ? "未链接" : "部分链接"
                        }

                        let app = AppItem(
                            name: folderName,
                            path: itemURL,
                            status: status,
                            isSystemApp: false,
                            isRunning: false,
                            isFolder: true,
                            containerKind: .appSuiteFolder,
                            appCount: appCount
                        )
                        candidates.append(makeCandidate(for: app, bundleURL: itemURL, priority: 20))
                    }
                }
            }
        }

        let localItems = (try? fileManager.contentsOfDirectory(at: localAppsDir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        for localItemURL in localItems {
            if localItemURL.pathExtension == "app" {
                guard let externalTargetURL = externalTargetForLocalApp(at: localItemURL),
                      isDescendantOrSame(externalTargetURL, under: dir),
                      fileManager.fileExists(atPath: externalTargetURL.path) else {
                    continue
                }

                let (isAppStore, isIOS) = detectAppStoreAndIOSApp(at: externalTargetURL)
                let isResigned = checkResignedStatus(bundleURL: externalTargetURL)
                let app = AppItem(
                    name: externalTargetURL.lastPathComponent,
                    path: externalTargetURL,
                    bundleURL: externalTargetURL,
                    status: "已链接",
                    isSystemApp: false,
                    isRunning: false,
                    isAppStoreApp: isAppStore,
                    isIOSApp: isIOS,
                    isResigned: isResigned,
                    containerKind: .standaloneApp
                )
                candidates.append(makeCandidate(for: app, bundleURL: externalTargetURL, priority: 40))
                continue
            }

            guard let externalTargetURL = resolveSymlinkDestination(of: localItemURL),
                  isDescendantOrSame(externalTargetURL, under: dir) else {
                continue
            }

            let appsInFolder = appBundlesInsideFolderPortal(at: externalTargetURL)
            guard !appsInFolder.isEmpty else {
                continue
            }

            if appsInFolder.count == 1, let bundleURL = appsInFolder.first {
                let (isAppStore, isIOS) = detectAppStoreAndIOSApp(at: bundleURL)
                let isResigned = checkResignedStatus(bundleURL: bundleURL)
                let app = AppItem(
                    name: externalTargetURL.lastPathComponent,
                    path: externalTargetURL,
                    bundleURL: bundleURL,
                    status: "已链接",
                    isSystemApp: false,
                    isRunning: false,
                    isAppStoreApp: isAppStore,
                    isIOSApp: isIOS,
                    isResigned: isResigned,
                    containerKind: .singleAppContainer,
                    appCount: 1
                )
                candidates.append(makeCandidate(for: app, bundleURL: bundleURL, priority: 40))
            } else {
                let app = AppItem(
                    name: externalTargetURL.lastPathComponent,
                    path: externalTargetURL,
                    status: "已链接",
                    isSystemApp: false,
                    isRunning: false,
                    isFolder: true,
                    containerKind: .appSuiteFolder,
                    appCount: appsInFolder.count
                )
                candidates.append(makeCandidate(for: app, bundleURL: externalTargetURL, priority: 40))
            }
        }

        // macOS >= 15.1: 扫描外部磁盘根目录的 Applications 文件夹
        if AppMigrationService.isMASExternalInstallSupported {
            let masDir = AppMigrationService.masApplicationsURL(for: dir)
            let masItems = (try? fileManager.contentsOfDirectory(at: masDir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
            for itemURL in masItems where itemURL.pathExtension == "app" {
                let appName = itemURL.lastPathComponent
                var status = "未链接"
                let localAppURL = localAppsDir.appendingPathComponent(appName)
                if fileManager.fileExists(atPath: localAppURL.path),
                   isLocalApp(localAppURL, linkedTo: itemURL) {
                    status = "已链接"
                }
                let (isAppStore, isIOS) = detectAppStoreAndIOSApp(at: itemURL)
                let isResigned = checkResignedStatus(bundleURL: itemURL)
                let app = AppItem(
                    name: appName,
                    path: itemURL,
                    bundleURL: itemURL,
                    status: status,
                    isSystemApp: false,
                    isRunning: false,
                    isAppStoreApp: isAppStore,
                    isMASExternal: true,
                    isIOSApp: isIOS,
                    isResigned: isResigned,
                    containerKind: .standaloneApp
                )
                candidates.append(makeCandidate(for: app, bundleURL: itemURL, priority: 15))
            }
        }

        let sortedApps = sortApps(deduplicate(candidates))
        AppLogger.shared.logContext(
            "AppScanner 完成外部应用扫描",
            details: [
                ("scan_id", scanID),
                ("count", String(sortedApps.count)),
                ("statuses", Dictionary(grouping: sortedApps, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
            ],
            level: "TRACE"
        )
        return sortedApps
    }
    
    /// 应用列表排序
    ///
    /// 排序规则：
    /// 1. "已链接" 应用优先显示
    /// 2. 相同状态的应用按名称字母顺序排序
    ///
    /// - Parameter apps: 待排序的应用列表
    /// - Returns: 排序后的应用列表
    private func sortApps(_ apps: [AppItem]) -> [AppItem] {
         return apps.sorted { app1, app2 in
            let isApp1Linked = (app1.status == "已链接")
            let isApp2Linked = (app2.status == "已链接")
            
            // "已链接" 状态优先
            if isApp1Linked && !isApp2Linked { return true }
            if !isApp1Linked && isApp2Linked { return false }
            
            // 同状态按名称排序
            return app1.displayName < app2.displayName
        }
    }

    private func makeCandidate(for app: AppItem, bundleURL: URL, priority: Int) -> ScanCandidate {
        ScanCandidate(
            app: app,
            dedupeKey: dedupeKey(for: bundleURL, fallbackName: app.displayName),
            priority: priority
        )
    }

    private func deduplicate(_ candidates: [ScanCandidate]) -> [AppItem] {
        var selectedByKey: [String: ScanCandidate] = [:]
        var orderedKeys: [String] = []

        for candidate in candidates {
            if let existing = selectedByKey[candidate.dedupeKey] {
                if shouldReplace(existing: existing, with: candidate) {
                    selectedByKey[candidate.dedupeKey] = candidate
                }
                continue
            }

            selectedByKey[candidate.dedupeKey] = candidate
            orderedKeys.append(candidate.dedupeKey)
        }

        return orderedKeys.compactMap { selectedByKey[$0]?.app }
    }

    private func shouldReplace(existing: ScanCandidate, with candidate: ScanCandidate) -> Bool {
        let existingStatusRank = statusRank(for: existing.app.status)
        let candidateStatusRank = statusRank(for: candidate.app.status)

        if candidateStatusRank != existingStatusRank {
            return candidateStatusRank > existingStatusRank
        }

        return candidate.priority > existing.priority
    }

    private func statusRank(for status: String) -> Int {
        switch status {
        case "已链接":
            return 3
        case "部分链接":
            return 2
        default:
            return 1
        }
    }

    private func dedupeKey(for bundleURL: URL, fallbackName: String) -> String {
        if let bundleID = readBundleIdentifier(from: bundleURL), !bundleID.isEmpty {
            return "bundle:\(bundleID.lowercased())"
        }

        let normalized = fallbackName
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive])
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return "name:\(normalized)"
    }

    private func readBundleIdentifier(from appURL: URL) -> String? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        return plist["CFBundleIdentifier"] as? String
    }

    private func readBundleVersion(from appURL: URL) -> String? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    private static var backupDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AppPorts/signature-backups")
    }

    private func checkResignedStatus(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }

        // 先用本地 bundle ID 检查
        if let bundleID = readBundleIdentifier(from: bundleURL) {
            let backupPlist = Self.backupDirectoryURL.appendingPathComponent("\(bundleID).plist")
            if FileManager.default.fileExists(atPath: backupPlist.path) {
                return isAdHocSigned(at: bundleURL)
            }
        }

        // 已链接应用：备份保存在真实应用的 bundle ID 下，需要解析外部路径
        if let externalURL = resolveExternalRealApp(from: bundleURL),
           let realBundleID = readBundleIdentifier(from: externalURL) {
            let backupPlist = Self.backupDirectoryURL.appendingPathComponent("\(realBundleID).plist")
            if FileManager.default.fileExists(atPath: backupPlist.path) {
                // 检查外部真实应用是否为 ad-hoc 签名
                return isAdHocSigned(at: externalURL)
            }
        }

        return false
    }

    /// 解析已链接应用的外部真实路径（支持 whole-app symlink 和 stub portal）
    private func resolveExternalRealApp(from localURL: URL) -> URL? {
        // Whole-app symlink
        if let target = resolveSymlinkDestination(of: localURL) {
            return target
        }

        // Stub Portal：从原生 launcher 的 real_app_path.txt 解析外部路径
        let realAppPathFile = localURL.appendingPathComponent("Contents/Resources/real_app_path.txt")
        if let raw = try? String(contentsOf: realAppPathFile, encoding: .utf8),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let realPath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: realPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Stub Portal（旧版 bash launcher）：从 launcher 脚本解析外部路径
        let launcherPath = localURL.appendingPathComponent("Contents/MacOS/launcher")
        if let script = try? String(contentsOf: launcherPath, encoding: .utf8) {
            let pattern = "REAL_APP='([^']+)'"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
               let range = Range(match.range(at: 1), in: script) {
                let path = String(script[range])
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }

        return nil
    }

    /// 检查 app 是否为 ad-hoc 签名（非 Developer ID）
    private func isAdHocSigned(at appURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", appURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // ad-hoc 签名的特征：Signature=adhoc
        return output.contains("Signature=adhoc")
    }
}
