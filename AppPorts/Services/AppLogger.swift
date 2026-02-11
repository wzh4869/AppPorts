//
//  AppLogger.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation
import AppKit

// MARK: - 应用日志管理器

/// 全局日志管理服务
///
/// 提供完整的日志记录、管理和系统诊断功能。支持：
/// - 📝 多级别日志（INFO、ERROR、DIAG、DISK、PERF）
/// - 💾 日志文件自动轮转（避免占用过多空间）
/// - 🔧 系统信息诊断（硬件、软件、磁盘）
/// - 📊 性能监控（迁移速度、耗时统计）
/// - ⚙️ 用户可配置（文件路径、最大大小、启用/禁用）
///
/// ## 使用示例
/// ```swift
/// // 基本日志
/// AppLogger.shared.log("应用启动")
///
/// // 错误日志
/// AppLogger.shared.logError("操作失败", error: someError)
///
/// // 系统诊断
/// AppLogger.shared.logSystemInfo()
///
/// // 性能监控
/// AppLogger.shared.logMigrationPerformance(
///     appName: "Xcode.app",
///     size: 10_000_000_000,
///     duration: 120.5,
///     sourcePath: "/Applications/Xcode.app",
///     destPath: "/Volumes/External/Xcode.app"
/// )
/// ```
///
/// - Note: 所有日志同时输出到控制台和文件（如果启用）
class AppLogger {
    /// 单例实例
    static let shared = AppLogger()
    
    // MARK: - 私有属性
    
    /// 日期格式化器（格式：yyyy-MM-dd HH:mm:ss）
    private let dateFormatter: DateFormatter
    
    /// 文件管理器
    private let fileManager = FileManager.default
    
    /// UserDefaults 存储键
    private let logPathKey = "LogFilePath"         // 日志文件路径
    private let maxLogSizeKey = "MaxLogSizeBytes"  // 最大日志大小
    private let logEnabledKey = "LogEnabled"       // 日志启用状态
    
    /// 默认最大日志大小: 2MB
    private let defaultMaxSize: Int64 = 2 * 1024 * 1024
    
    // MARK: - 公共属性
    
    /// 日志是否启用
    ///
    /// 控制日志是否写入文件。关闭后：
    /// - 日志仍会输出到控制台（用于开发调试）
    /// - 不会写入日志文件（节省磁盘空间）
    ///
    /// - Note: 默认为启用状态
    var isLoggingEnabled: Bool {
        get {
            // 默认为开启 (true)
            UserDefaults.standard.object(forKey: logEnabledKey) == nil ? true : UserDefaults.standard.bool(forKey: logEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: logEnabledKey)
            if newValue {
                log("日志记录已启用")
            } else {
                log("日志记录已禁用")
            }
        }
    }
    
    /// 当前日志文件路径
    ///
    /// 返回日志文件的完整 URL。路径来源优先级：
    /// 1. 用户自定义路径（通过 `setLogPath(_:)` 设置）
    /// 2. 默认路径：`~/Library/Application Support/AppPorts/AppPorts_Log.txt`
    ///
    /// - Note: 如果目录不存在会自动创建
    var logFileURL: URL {
        if let savedPath = UserDefaults.standard.string(forKey: logPathKey) {
            return URL(fileURLWithPath: savedPath)
        }
        // 默认位置: 应用支持目录
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AppPorts")
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("AppPorts_Log.txt")
    }
    
    /// 最大日志大小（字节）
    ///
    /// 当日志文件超过此大小时，会自动执行轮转（删除旧内容，保留后半部分）。
    ///
    /// 常用值：
    /// - 1 MB = 1,048,576 字节
    /// - 5 MB = 5,242,880 字节
    /// - 10 MB = 10,485,760 字节
    ///
    /// - Note: 默认为 2 MB
    var maxLogSize: Int64 {
        get {
            let saved = UserDefaults.standard.integer(forKey: maxLogSizeKey)
            return saved > 0 ? Int64(saved) : defaultMaxSize
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: maxLogSizeKey)
        }
    }
    
    // MARK: - 初始化
    
    /// 私有初始化（单例模式）
    ///
    /// 配置日期格式化器用于日志时间戳
    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }
    
    /// 设置日志文件路径
    func setLogPath(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: logPathKey)
        log("日志路径已更改为: \(url.path)")
    }
    
    /// 在 Finder 中打开日志文件
    func openLogInFinder() {
        let url = logFileURL
        if fileManager.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // 如果日志文件不存在，打开其所在目录
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
    
    /// 清空日志
    func clearLog() {
        try? fileManager.removeItem(at: logFileURL)
        log("日志已清空")
    }
    
    func log(_ message: String, level: String = "INFO") {
        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] [\(level)] \(message)\n"
        
        print(logLine) // 同时打印到控制台
        
        // 如果日志被禁用，则不写入文件
        guard isLoggingEnabled else { return }
        
        let url = logFileURL
        
        // 检查并执行日志轮转
        rotateLogIfNeeded()
        
        if let data = logLine.data(using: .utf8) {
            if fileManager.fileExists(atPath: url.path) {
                if let fileHandle = try? FileHandle(forWritingTo: url) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                // 确保目录存在
                try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
    
    /// 日志轮转：当日志超过最大大小时，删除旧内容
    private func rotateLogIfNeeded() {
        let url = logFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64,
              fileSize > maxLogSize else {
            return
        }
        
        // 读取现有内容，保留后半部分
        if let data = try? Data(contentsOf: url),
           let content = String(data: data, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
            let keepLines = lines.suffix(lines.count / 2) // 保留后半部分
            let newContent = keepLines.joined(separator: "\n")
            try? newContent.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    func logError(_ message: String, error: Error? = nil) {
        var fullMessage = message
        if let error = error {
            fullMessage += " | 错误: \(error.localizedDescription) | 类型: \(type(of: error))"
            if let nsError = error as NSError? {
                fullMessage += " | Domain: \(nsError.domain) | Code: \(nsError.code)"
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                    fullMessage += " | 底层错误: \(underlying)"
                }
            }
        }
        log(fullMessage, level: "ERROR")
    }
    
    /// 获取日志大小的可读字符串
    func getLogSizeString() -> String {
        let url = logFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return "0 KB"
        }
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
    
    // MARK: - 系统诊断信息
    
    /// 记录应用启动时的系统信息
    func logSystemInfo() {
        log("========== 系统诊断信息 ==========", level: "DIAG")
        log("App 版本: \(getAppVersion())", level: "DIAG")
        log("macOS 版本: \(getMacOSVersion())", level: "DIAG")
        log("设备型号: \(getDeviceModel())", level: "DIAG")
        log("处理器: \(getProcessorInfo())", level: "DIAG")
        log("内存: \(getMemoryInfo())", level: "DIAG")
        log("======================================", level: "DIAG")
    }
    
    /// 记录外接硬盘信息
    func logExternalDriveInfo(at url: URL) {
        log("========== 外接硬盘信息 ==========", level: "DISK")
        
        // 获取卷信息
        let volumeInfo = getVolumeInfo(at: url)
        for (key, value) in volumeInfo {
            log("\(key): \(value)", level: "DISK")
        }
        
        // 获取磁盘接口和速率
        let diskInterface = getDiskInterfaceInfo(at: url)
        for (key, value) in diskInterface {
            log("\(key): \(value)", level: "DISK")
        }
        
        log("====================================", level: "DISK")
    }
    
    /// 记录迁移性能信息
    func logMigrationPerformance(appName: String, size: Int64, duration: TimeInterval, sourcePath: String, destPath: String) {
        let speed = duration > 0 ? Double(size) / duration / 1024 / 1024 : 0
        log("========== 迁移性能报告 ==========", level: "PERF")
        log("应用: \(appName)", level: "PERF")
        log("大小: \(formatBytes(size))", level: "PERF")
        log("耗时: \(String(format: "%.2f", duration)) 秒", level: "PERF")
        log("速度: \(String(format: "%.2f", speed)) MB/s", level: "PERF")
        log("源路径: \(sourcePath)", level: "PERF")
        log("目标: \(destPath)", level: "PERF")
        log("====================================", level: "PERF")
    }
    
    // MARK: - 获取系统信息的辅助方法
    
    private func getAppVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        return "\(version) (\(build))"
    }
    
    private func getMacOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        
        // 获取 macOS 名称
        var macOSName = "macOS"
        if version.majorVersion >= 15 {
            macOSName = "macOS Sequoia"
        } else if version.majorVersion >= 14 {
            macOSName = "macOS Sonoma"
        } else if version.majorVersion >= 13 {
            macOSName = "macOS Ventura"
        } else if version.majorVersion >= 12 {
            macOSName = "macOS Monterey"
        }
        
        return "\(macOSName) \(versionString)"
    }
    
    private func getDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model)
        
        // 尝试获取更友好的名称
        let friendlyName = getMarketingModelName(modelString)
        return "\(friendlyName) (\(modelString))"
    }
    
    private func getMarketingModelName(_ identifier: String) -> String {
        // 常见 Mac 型号映射
        let models: [String: String] = [
            "Mac14,2": "MacBook Air (M2, 2022)",
            "Mac14,3": "MacBook Pro (14-inch, M2 Pro, 2023)",
            "Mac14,5": "MacBook Pro (14-inch, M2 Max, 2023)",
            "Mac14,6": "MacBook Pro (16-inch, M2 Pro, 2023)",
            "Mac14,7": "MacBook Pro (13-inch, M2, 2022)",
            "Mac14,9": "MacBook Pro (14-inch, M3, 2023)",
            "Mac14,10": "MacBook Pro (16-inch, M3, 2023)",
            "Mac14,12": "Mac mini (M2, 2023)",
            "Mac14,13": "Mac Studio (M2 Max, 2023)",
            "Mac14,14": "Mac Studio (M2 Ultra, 2023)",
            "Mac14,15": "MacBook Air (15-inch, M2, 2023)",
            "Mac15,3": "MacBook Pro (14-inch, M3 Pro, 2023)",
            "Mac15,4": "iMac (24-inch, M3, 2023)",
            "Mac15,5": "MacBook Air (13-inch, M3, 2024)",
            "Mac15,6": "MacBook Pro (14-inch, M3 Max, 2023)",
            "Mac15,7": "MacBook Pro (16-inch, M3 Pro, 2023)",
            "Mac15,8": "MacBook Pro (16-inch, M3 Max, 2023)",
            "Mac15,9": "MacBook Pro (16-inch, M3 Pro, 2023)",
            "Mac15,10": "MacBook Pro (14-inch, M3 Pro, 2023)",
            "Mac15,11": "MacBook Pro (16-inch, M3 Max, 2023)",
            "Mac15,12": "MacBook Air (13-inch, M3, 2024)",
            "Mac15,13": "MacBook Air (15-inch, M3, 2024)",
            "MacBookPro18,3": "MacBook Pro (14-inch, M1 Pro, 2021)",
            "MacBookPro18,4": "MacBook Pro (14-inch, M1 Max, 2021)",
            "MacBookPro18,1": "MacBook Pro (16-inch, M1 Pro, 2021)",
            "MacBookPro18,2": "MacBook Pro (16-inch, M1 Max, 2021)",
            "MacBookAir10,1": "MacBook Air (M1, 2020)",
            "Macmini9,1": "Mac mini (M1, 2020)",
            "iMac21,1": "iMac (24-inch, M1, 2021)",
            "iMac21,2": "iMac (24-inch, M1, 2021)"
        ]
        return models[identifier] ?? "Mac"
    }
    
    private func getProcessorInfo() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let brandString = String(cString: brand)
        
        // 获取 CPU 核心数
        let processorCount = ProcessInfo.processInfo.processorCount
        let activeCount = ProcessInfo.processInfo.activeProcessorCount
        
        if brandString.isEmpty {
            // Apple Silicon
            return "Apple Silicon (\(processorCount) 核心, \(activeCount) 活跃)"
        }
        return "\(brandString) (\(activeCount)/\(processorCount) 核心)"
    }
    
    private func getMemoryInfo() -> String {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        return formatBytes(Int64(physicalMemory))
    }
    
    // MARK: - 获取磁盘信息的辅助方法
    
    private func getVolumeInfo(at url: URL) -> [(String, String)] {
        var info: [(String, String)] = []
        
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeLocalizedFormatDescriptionKey
            ])
            
            if let name = values.volumeName {
                info.append(("卷名称", name))
            }
            if let total = values.volumeTotalCapacity {
                info.append(("总容量", formatBytes(Int64(total))))
            }
            if let available = values.volumeAvailableCapacity {
                info.append(("可用空间", formatBytes(Int64(available))))
            }
            if let format = values.volumeLocalizedFormatDescription {
                info.append(("文件系统", format))
            }
            if let removable = values.volumeIsRemovable {
                info.append(("可移除", removable ? "是" : "否"))
            }
            if let ejectable = values.volumeIsEjectable {
                info.append(("可弹出", ejectable ? "是" : "否"))
            }
        } catch {
            info.append(("错误", error.localizedDescription))
        }
        
        return info
    }
    
    private func getDiskInterfaceInfo(at url: URL) -> [(String, String)] {
        var info: [(String, String)] = []
        
        // 1. 使用 diskutil info -plist 获取基础信息
        let task = Process()
        task.launchPath = "/usr/sbin/diskutil"
        task.arguments = ["info", "-plist", url.path]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        var diskName = ""
        var physicalStore = ""
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                
                // 提取基本信息
                if let location = plist["DeviceLocation"] as? String {
                    info.append(("设备位置", location))
                } else if let mediaName = plist["MediaName"] as? String {
                    info.append(("设备名称", mediaName))
                }
                
                if let blockSize = plist["DeviceBlockSize"] as? Int {
                    info.append(("块大小", "\(blockSize) Bytes"))
                }
                
                if let protocolName = plist["BusProtocol"] as? String {
                    info.append(("接口协议", protocolName))
                }
                
                if let uuid = plist["VolumeUUID"] as? String {
                    info.append(("卷 UUID", uuid))
                }
                
                if let deviceIdentifier = plist["DeviceIdentifier"] as? String {
                    diskName = deviceIdentifier
                }
                
                // APFS 容器处理：获取物理存储标识符
                if let parent = plist["APFSPhysicalStores"] as? [[String: Any]],
                   let firstStore = parent.first,
                   let storeIdentifier = firstStore["DeviceIdentifier"] as? String {
                    physicalStore = storeIdentifier
                } else if plist["Partitions"] != nil {
                    // HFS+ 分区不需要额外处理物理存储
                }
            }
        } catch {
            info.append(("diskutil错误", error.localizedDescription))
        }
        
        // 2. 使用 system_profiler 获取更详细的速率信息
        // 我们会尝试使用卷名称、设备标识符 (diskX) 和物理存储标识符
        let volumeName = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
        let speedInfo = getConnectionSpeedInfo(volumeName: volumeName, diskIdentifier: diskName, physicalStore: physicalStore)
        info.append(contentsOf: speedInfo)
        
        return info
    }
    
    private func getConnectionSpeedInfo(volumeName: String, diskIdentifier: String, physicalStore: String) -> [(String, String)] {
        var info: [(String, String)] = []
        let searchTerms = [volumeName, diskIdentifier, physicalStore].filter { !$0.isEmpty }
        
        // 用于避免重复添加
        var foundSpeed = false
        
        // 尝试从 USB 设备信息获取
        if let usbOutput = runSystemProfiler(dataType: "SPUSBDataType"),
           let usbData = usbOutput["SPUSBDataType"] as? [[String: Any]] {
            if let usbInfo = searchDeviceRecursive(in: usbData, searchTerms: searchTerms, type: "USB") {
                info.append(contentsOf: usbInfo)
                foundSpeed = true
            }
        }
        
        // 如果 USB 没找到，尝试 Thunderbolt
        if !foundSpeed,
           let tbOutput = runSystemProfiler(dataType: "SPThunderboltDataType"),
           let tbData = tbOutput["SPThunderboltDataType"] as? [[String: Any]] {
            if let tbInfo = searchDeviceRecursive(in: tbData, searchTerms: searchTerms, type: "Thunderbolt") {
                info.append(contentsOf: tbInfo)
                foundSpeed = true
            }
        }
        
        // 如果还没找到，尝试 SATA/NVMe (内置/雷电扩展坞)
        if !foundSpeed,
           let storageOutput = runSystemProfiler(dataType: "SPNVMExpressDataType"),
           let storageData = storageOutput["SPNVMExpressDataType"] as? [[String: Any]] {
             if let storeInfo = searchDeviceRecursive(in: storageData, searchTerms: searchTerms, type: "NVMe") {
                 info.append(contentsOf: storeInfo)
                 foundSpeed = true
             }
        }
        
        if !foundSpeed {
            info.append(("接口速率", "未检测到或内置存储"))
        }
        
        return info
    }
    
    private func runSystemProfiler(dataType: String) -> [String: Any]? {
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = [dataType, "-json"]
        
        let pipe = Pipe()
         task.standardOutput = pipe
         task.standardError = FileHandle.nullDevice // Suppress stderr
         
         do {
             try task.run()
             task.waitUntilExit()
             let data = pipe.fileHandleForReading.readDataToEndOfFile()
             return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
         } catch {
             return nil
         }
    }
    
    // 通用递归搜索
    private func searchDeviceRecursive(in devices: [[String: Any]], searchTerms: [String], type: String) -> [(String, String)]? {
        for device in devices {
            // Check current device
            let deviceName = (device["_name"] as? String ?? "").lowercased()
            let deviceBSDName = (device["bsd_name"] as? String ?? "").lowercased()  // NVMe/SATA usually have this
            
            // Check Media/Volumes
            var mediaMatch = false
            if let media = device["Media"] as? [[String: Any]] {
                for mediaItem in media {
                    // Check volume names
                    if let volumes = mediaItem["volumes"] as? [[String: Any]] {
                        for vol in volumes {
                            if let volName = vol["_name"] as? String {
                                if searchTerms.contains(where: { volName.localizedCaseInsensitiveContains($0) }) {
                                    mediaMatch = true
                                }
                            }
                        }
                    }
                    // Check bsd name of media
                    if let bsdName = mediaItem["bsd_name"] as? String {
                         if searchTerms.contains(where: { bsdName.localizedCaseInsensitiveContains($0) }) {
                             mediaMatch = true
                         }
                    }
                }
            }
            
            // Check direct match on device name or disk identifier
            let directMatch = searchTerms.contains { term in
                return deviceName.localizedCaseInsensitiveContains(term) ||
                       deviceBSDName.localizedCaseInsensitiveContains(term)
            }
            
            if mediaMatch || directMatch {
                var info: [(String, String)] = []
                
                if type == "USB" {
                    if let speed = device["device_speed"] as? String { info.append(("设备速率", speed)) }
                    if let busSpeed = device["host_controller_speed"] as? String { info.append(("总线速率", busSpeed)) }
                } else if type == "Thunderbolt" {
                    if let speed = device["link_speed"] as? String { info.append(("链接速率", speed)) }
                    if let width = device["link_width"] as? String { info.append(("链接带宽", width)) }
                } else if type == "NVMe" {
                    if let width = device["link_width"] as? String { info.append(("链接宽度", width)) }
                    if let speed = device["link_speed"] as? String { info.append(("链接速率", speed)) }
                }
                
                info.append(("连接类型", type))
                return info
            }
            
            // Recursive check
            if let items = device["_items"] as? [[String: Any]] {
                if let found = searchDeviceRecursive(in: items, searchTerms: searchTerms, type: type) {
                    return found
                }
            }
        }
        return nil
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
