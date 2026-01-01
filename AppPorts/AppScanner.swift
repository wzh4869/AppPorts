
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
                
                // Logic to detect if it's "Linked" (our custom deep symlink or standard symlink)
                if let resourceValues = try? itemURL.resourceValues(forKeys: Set(keys)) {
                    if resourceValues.isSymbolicLink == true {
                        status = "已链接"
                    } else if resourceValues.isDirectory == true {
                        // Check deeper for "Contents" symlink (Our Deep Symlink Strategy)
                        let contentsURL = itemURL.appendingPathComponent("Contents")
                        if let contentsResourceValues = try? contentsURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                           contentsResourceValues.isSymbolicLink == true {
                            status = "已链接"
                        }
                    }
                }
                newApps.append(AppItem(name: appName, path: itemURL, status: status, isSystemApp: isSystem, isRunning: isRunning))
            }
        }
        return sortApps(newApps)
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
