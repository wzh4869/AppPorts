//
//  AppScanner.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation

// MARK: - AppScanner Actor
// Using an actor guarantees that all this logic runs off the Main Thread
// and serializes access to its internal state if needed.
actor AppScanner {
    
    // MARK: - Scanning Logic
    
    func calculateDirectorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var size: Int64 = 0
        
        // Fast path: Check if it is a symlink first
        if let res = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]), res.isSymbolicLink == true {
            return Int64(res.fileSize ?? 0)
        }
        
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        
        // Use compat options for speed

        
        // Note: Recursive size calculation can be slow.
        // For a true "deep" size, we need to recurse. The options above skip descendants which might refer to package contents.
        // Actually, for an .app bundle, we treat it as a directory.
        // Let's use a standard enumerator for correctness but maybe we can optimize later.
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles], errorHandler: nil) else { return 0 }
        
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            if let fileSize = resourceValues?.fileSize { size += Int64(fileSize) }
        }
        return size
    }
    
    func scanLocalApps(at dir: URL, runningAppURLs: Set<URL>) -> [AppItem] {
        let fileManager = FileManager.default
        var newApps: [AppItem] = []
        
        // Optimizing: pre-fetch only needed keys
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let items = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        
        for itemURL in items {
            if itemURL.pathExtension == "app" {
                let appName = itemURL.lastPathComponent
                var status = "本地"
                let isSystem = itemURL.path.hasPrefix("/System")
                let isRunning = runningAppURLs.contains(itemURL)
                
                // 检测是否为 App Store 应用
                let (isAppStore, isIOS) = detectAppStoreAndIOSApp(at: itemURL)
                
                // Logic to detect if it's "Linked" (our custom deep symlink or standard symlink)
                if let resourceValues = try? itemURL.resourceValues(forKeys: Set(keys)) {
                    if resourceValues.isSymbolicLink == true {
                        status = "已链接"
                    } else if resourceValues.isDirectory == true {
                        // Check deeper for "Contents" symlink (Mac App Deep Symlink Strategy)
                        let contentsURL = itemURL.appendingPathComponent("Contents")
                        if let contentsResourceValues = try? contentsURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                           contentsResourceValues.isSymbolicLink == true {
                            status = "已链接"
                        }
                        
                        // Check for "Wrapper" symlink (iOS App Deep Symlink Strategy)
                        let wrapperURL = itemURL.appendingPathComponent("Wrapper")
                        if let wrapperResourceValues = try? wrapperURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                           wrapperResourceValues.isSymbolicLink == true {
                            status = "已链接"
                        }
                    }
                }
                newApps.append(AppItem(name: appName, path: itemURL, status: status, isSystemApp: isSystem, isRunning: isRunning, isAppStoreApp: isAppStore, isIOSApp: isIOS))
            }
        }
        return sortApps(newApps)
    }
    
    /// 检测是否为 App Store 应用和 iOS 应用
    private func detectAppStoreAndIOSApp(at appURL: URL) -> (isAppStore: Bool, isIOS: Bool) {
        let fileManager = FileManager.default
        
        // 检测 _MASReceipt（Mac App Store 收据）
        let masReceiptURL = appURL.appendingPathComponent("Contents/_MASReceipt")
        let hasMASReceipt = fileManager.fileExists(atPath: masReceiptURL.path)
        
        // 读取 Info.plist 检测 iOS 应用
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        
        // iOS 应用可能在 WrappedBundle 中
        let wrappedBundleURL = appURL.appendingPathComponent("WrappedBundle")
        let hasWrappedBundle = fileManager.fileExists(atPath: wrappedBundleURL.path)
        
        var isIOSApp = false
        var isAppStore = hasMASReceipt
        
        if let plistData = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
            
            // 检测 UIDeviceFamily（1=iPhone, 2=iPad）
            if let deviceFamily = plist["UIDeviceFamily"] as? [Int] {
                // 如果包含 1 或 2，但不包含 6（Mac Catalyst），则是 iOS 应用
                let hasIPhoneOrIPad = deviceFamily.contains(1) || deviceFamily.contains(2)
                let isMacCatalyst = deviceFamily.contains(6) // Mac Catalyst
                if hasIPhoneOrIPad && !isMacCatalyst {
                    isIOSApp = true
                    isAppStore = true  // iOS 应用都来自 App Store
                }
            }
            
            // 检测 LSRequiresIPhoneOS（仅 iOS 应用有此键）
            if plist["LSRequiresIPhoneOS"] as? Bool == true {
                isIOSApp = true
                isAppStore = true
            }
            
            // 检测 DTPlatformName
            if let platform = plist["DTPlatformName"] as? String {
                if platform == "iphoneos" || platform == "iphonesimulator" {
                    isIOSApp = true
                    isAppStore = true
                }
            }
        }
        
        // 如果有 WrappedBundle，也是 iOS 应用
        if hasWrappedBundle {
            isIOSApp = true
            isAppStore = true
        }
        
        return (isAppStore, isIOSApp)
    }
    
    func scanExternalApps(at dir: URL, localAppsDir: URL) -> [AppItem] {
        let fileManager = FileManager.default
        var newApps: [AppItem] = []
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let items = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        
        for itemURL in items {
            if itemURL.pathExtension == "app" {
                let appName = itemURL.lastPathComponent
                var status = "未链接" 
                
                let expectedLocalPath = localAppsDir.appendingPathComponent(appName)
                if fileManager.fileExists(atPath: expectedLocalPath.path) {
                    if let resourceValues = try? expectedLocalPath.resourceValues(forKeys: Set(keys)) {
                         if resourceValues.isSymbolicLink == true {
                             status = "已链接" // The local one is a symlink, so this external one is "Linked" to it
                         } else if resourceValues.isDirectory == true {
                             let contentsPath = expectedLocalPath.appendingPathComponent("Contents")
                             if let contentsRes = try? contentsPath.resourceValues(forKeys: [.isSymbolicLinkKey]), contentsRes.isSymbolicLink == true {
                                 status = "已链接"
                             }
                         }
                    }
                }
                newApps.append(AppItem(name: appName, path: itemURL, status: status, isSystemApp: false, isRunning: false))
            }
        }
        return sortApps(newApps)
    }
    
    private func sortApps(_ apps: [AppItem]) -> [AppItem] {
         return apps.sorted { app1, app2 in
            let isApp1Linked = (app1.status == "已链接")
            let isApp2Linked = (app2.status == "已链接")
            
            // "已链接" comes first
            if isApp1Linked && !isApp2Linked { return true }
            if !isApp1Linked && isApp2Linked { return false }
            
            return app1.name < app2.name
        }
    }
}
