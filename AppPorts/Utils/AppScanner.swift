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
    
    // MARK: - 公共 API
    
    /// 计算目录大小
    ///
    /// 递归计算目录树的总大小，跳过符号链接以避免重复计算。
    ///
    /// - Parameter url: 目录 URL
    /// - Returns: 目录总大小（字节）
    ///
    /// - Note: 符号链接被快速跳过，不会递归进入链接目标
    func calculateDirectorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var size: Int64 = 0
        
        // 快速路径：优先检查是否为符号链接
        if let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           resourceValues.isSymbolicLink == true {
            // 符号链接直接返回 0（不计算链接目标的大小）
            return 0
        }
        
        // 需要获取的资源键
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        
        // 创建目录枚举器（深度优先遍历）
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles], // 跳过隐藏文件提升性能
            errorHandler: nil
        ) else { return 0 }
        
        // 累加所有文件大小
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            if let fileSize = resourceValues?.fileSize { size += Int64(fileSize) }
        }
        return size
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
        let fileManager = FileManager.default
        var newApps: [AppItem] = []
        
        // 性能优化：预先获取需要的资源键
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let items = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        
        for itemURL in items {
            // 只处理 .app 扩展名的项目
            if itemURL.pathExtension == "app" {
                let appName = itemURL.lastPathComponent
                var status = "本地"
                let isSystem = itemURL.path.hasPrefix("/System")
                let isRunning = runningAppURLs.contains(itemURL)
                
                // 检测是否为 App Store 应用和 iOS 应用
                let (isAppStore, isIOS) = detectAppStoreAndIOSApp(at: itemURL)
                
                // 检测链接状态
                // 1. 标准符号链接检测
                if let resourceValues = try? itemURL.resourceValues(forKeys: Set(keys)) {
                    if resourceValues.isSymbolicLink == true {
                        status = "已链接"
                    } else if resourceValues.isDirectory == true {
                        // 2. 深层符号链接检测（检查 Contents 目录）
                        let contentsURL = itemURL.appendingPathComponent("Contents")
                        if let contentsValues = try? contentsURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                           contentsValues.isSymbolicLink == true {
                            status = "已链接"
                        } else {
                            // 3. 更深层检测（检查 MacOS 和 Resources 目录）
                            let macOSURL = contentsURL.appendingPathComponent("MacOS")
                            let resourcesURL = contentsURL.appendingPathComponent("Resources")
                            
                            if let macOSValues = try? macOSURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                               macOSValues.isSymbolicLink == true {
                                status = "已链接"
                            } else if let resourcesValues = try? resourcesURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                                      resourcesValues.isSymbolicLink == true {
                                status = "已链接"
                            }
                        }
                    }
                }
                newApps.append(AppItem(name: appName, path: itemURL, status: status, isSystemApp: isSystem, isRunning: isRunning, isAppStoreApp: isAppStore, isIOSApp: isIOS))
            }
            // 处理包含 .app 的文件夹（如 Microsoft Office、Adobe Creative Cloud 等套件）
            else if let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]),
                    resourceValues.isDirectory == true {
                let folderContents = (try? fileManager.contentsOfDirectory(at: itemURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                let appsInFolder = folderContents.filter { $0.pathExtension == "app" }
                
                if !appsInFolder.isEmpty {
                    let folderName = itemURL.lastPathComponent
                    let appCount = appsInFolder.count
                    
                    // 检查文件夹内是否有正在运行的应用
                    let hasRunning = appsInFolder.contains { runningAppURLs.contains($0) }
                    
                    newApps.append(AppItem(
                        name: folderName,
                        path: itemURL,
                        status: "本地",
                        isSystemApp: false,
                        isRunning: hasRunning,
                        isFolder: true,
                        appCount: appCount
                    ))
                }
            }
        }
        return sortApps(newApps)
    }
    
    // MARK: - 私有辅助方法
    
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
        let fileManager = FileManager.default
        var newApps: [AppItem] = []
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let items = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        
        for itemURL in items {
            if itemURL.pathExtension == "app" {
                let appName = itemURL.lastPathComponent
                var status = "未链接"
                
                // 检查本地是否存在符号链接
                let localAppURL = localAppsDir.appendingPathComponent(appName)
                if fileManager.fileExists(atPath: localAppURL.path) {
                    // 1. 检查标准符号链接（整个 .app 是符号链接）
                    if let resourceValues = try? localAppURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                       resourceValues.isSymbolicLink == true {
                        // 验证符号链接是否指向当前外部应用
                        if let linkDest = try? fileManager.destinationOfSymbolicLink(atPath: localAppURL.path),
                           linkDest == itemURL.path {
                            status = "已链接"
                        }
                    } else if let resourceValues = try? localAppURL.resourceValues(forKeys: [.isDirectoryKey]),
                              resourceValues.isDirectory == true {
                        // 2. 检查深层符号链接（Contents 是符号链接）
                        let localContentsURL = localAppURL.appendingPathComponent("Contents")
                        if let contentsValues = try? localContentsURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                           contentsValues.isSymbolicLink == true {
                            // 验证 Contents 符号链接是否指向当前外部应用的 Contents
                            let externalContentsURL = itemURL.appendingPathComponent("Contents")
                            if let linkDest = try? fileManager.destinationOfSymbolicLink(atPath: localContentsURL.path),
                               linkDest == externalContentsURL.path {
                                status = "已链接"
                            }
                        }
                    }
                }
                newApps.append(AppItem(name: appName, path: itemURL, status: status, isSystemApp: false, isRunning: false))
            }
            // 2. 处理包含 .app 的文件夹（如 Microsoft Office、Adobe Creative Cloud 等套件）
            else if let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]),
                    resourceValues.isDirectory == true {
                // 检查文件夹内是否包含 .app 文件
                let folderContents = (try? fileManager.contentsOfDirectory(at: itemURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                let appsInFolder = folderContents.filter { $0.pathExtension == "app" }
                
                if !appsInFolder.isEmpty {
                    // 这是一个包含应用的文件夹
                    let folderName = itemURL.lastPathComponent
                    let appCount = appsInFolder.count
                    
                    // 检查文件夹内的应用有多少已链接到本地
                    var linkedCount = 0
                    for appURL in appsInFolder {
                        let appName = appURL.lastPathComponent
                        let localAppURL = localAppsDir.appendingPathComponent(appName)
                        if fileManager.fileExists(atPath: localAppURL.path) {
                            linkedCount += 1
                        }
                    }
                    
                   // 确定文件夹状态
                    let status: String
                    if linkedCount == 0 {
                        status = "未链接"
                    } else if linkedCount == appCount {
                        status = "已链接"
                    } else {
                        status = "部分链接"
                    }
                    
                    newApps.append(AppItem(
                        name: folderName,
                        path: itemURL,
                        status: status,
                        isSystemApp: false,
                        isRunning: false,
                        isFolder: true,
                        appCount: appCount
                    ))
                }
            }
        }
        return sortApps(newApps)
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
            return app1.name < app2.name
        }
    }
}
