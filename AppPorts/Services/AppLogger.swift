//
//  AppLogger.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation
import AppKit
import Darwin
import UniformTypeIdentifiers

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
final class AppLogger: @unchecked Sendable {
    struct OperationSummaryRecord: Codable, Sendable {
        let operationID: String
        let category: String
        let result: String
        let errorCode: String?
        let startedAt: String?
        let endedAt: String
        let durationMs: Int?
        let sessionID: String
        let details: [String: String]
    }

    /// 单例实例
    static let shared = AppLogger(userDefaults: .standard,
        usesTestLogDirectory: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    
    // MARK: - 私有属性
    
    /// 日期格式化器（格式：yyyy-MM-dd HH:mm:ss）
    private let dateFormatter: DateFormatter
    
    /// 文件管理器
    nonisolated(unsafe) private let fileManager = FileManager.default

    /// 串行日志队列，避免多线程写文件交错
    private let writeQueue = DispatchQueue(label: "com.shimoko.AppPorts.logger")

    /// 磁盘查询可能等待设备响应，不占用调用者（尤其是主线程）。
    private let diagnosticQueue = DispatchQueue(label: "com.shimoko.AppPorts.logger.diagnostics", qos: .utility)

    nonisolated(unsafe) private let userDefaults: UserDefaults
    nonisolated private let usesTestLogDirectory: Bool

    /// 当前启动会话 ID，便于用户粘贴日志后快速关联一次运行
    nonisolated private let sessionID: String

    /// 当前进程 ID
    nonisolated private let processID: Int32 = ProcessInfo.processInfo.processIdentifier

    /// 最近操作摘要，导出诊断包时直接复用
    nonisolated(unsafe) private var recentOperationSummaries: [OperationSummaryRecord] = []
    
    /// UserDefaults 存储键
    nonisolated private let logPathKey = "LogFilePath"         // 日志文件路径
    nonisolated private let maxLogSizeKey = "MaxLogSizeBytes"  // 最大日志大小
    nonisolated private let logEnabledKey = "LogEnabled"       // 日志启用状态
    
    /// 默认最大日志大小: 2MB
    nonisolated private let defaultMaxSize: Int64 = 2 * 1024 * 1024

    /// 最多保留最近 100 条操作摘要，避免无限增长
    nonisolated private let maxOperationSummaryCount = 100
    
    // MARK: - 公共属性
    
    /// 日志是否启用
    ///
    /// 控制日志是否写入文件。关闭后：
    /// - 日志仍会输出到控制台（用于开发调试）
    /// - 不会写入日志文件（节省磁盘空间）
    ///
    /// - Note: 默认为启用状态
    nonisolated var isLoggingEnabled: Bool {
        get {
            // 默认为开启 (true)
            userDefaults.object(forKey: logEnabledKey) == nil ? true : userDefaults.bool(forKey: logEnabledKey)
        }
        set {
            userDefaults.set(newValue, forKey: logEnabledKey)
            if newValue {
                log("日志记录已启用".localized)
            } else {
                log("日志记录已禁用".localized)
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
    nonisolated var logFileURL: URL {
        if usesTestLogDirectory {
            let directory = fileManager.temporaryDirectory.appendingPathComponent("AppPortsTestLogs-\(ProcessInfo.processInfo.processIdentifier)")
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("AppPorts_Log.txt")
        }
        if let savedPath = userDefaults.string(forKey: logPathKey) {
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
    nonisolated var maxLogSize: Int64 {
        get {
            let saved = userDefaults.integer(forKey: maxLogSizeKey)
            return saved > 0 ? Int64(saved) : defaultMaxSize
        }
        set {
            userDefaults.set(Int(newValue), forKey: maxLogSizeKey)
        }
    }
    
    // MARK: - 初始化
    
    /// 应用使用标准设置；独立设置可用于隔离诊断测试。
    nonisolated init(userDefaults: UserDefaults, usesTestLogDirectory: Bool = false) {
        self.usesTestLogDirectory = usesTestLogDirectory
        self.userDefaults = userDefaults
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sessionID = String(UUID().uuidString.prefix(8))
    }

    nonisolated func logLaunchSession() {
        log("========== AppPorts 启动 ==========")
        logContext(
            "启动会话",
            details: [
                ("session_id", sessionID),
                ("pid", String(processID)),
                ("bundle_id", Bundle.main.bundleIdentifier ?? "未知"),
                ("bundle_path", Bundle.main.bundleURL.path),
                ("current_directory", fileManager.currentDirectoryPath),
                ("log_enabled", isLoggingEnabled ? "true" : "false"),
                ("log_file", logFileURL.path),
                ("max_log_size", formatBytes(maxLogSize)),
                ("app_language", selectedAppLanguageCode()),
                ("app_locale", selectedAppLocaleIdentifier()),
                ("locale", Locale.current.identifier),
                ("timezone", TimeZone.current.identifier),
                ("preferred_languages", Locale.preferredLanguages.joined(separator: ", "))
            ],
            level: "DIAG"
        )
        logSystemInfo()
    }

    nonisolated func makeOperationID(prefix: String) -> String {
        let compactPrefix = prefix.replacingOccurrences(of: " ", with: "-")
        return "\(compactPrefix)-\(String(UUID().uuidString.prefix(8)))"
    }
    
    /// 设置日志文件路径
    nonisolated func setLogPath(_ url: URL) {
        userDefaults.set(url.path, forKey: logPathKey)
        logContext("日志路径已更改", details: [("path", url.path)])
    }
    
    /// 在 Finder 中打开日志文件
    @MainActor
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
    nonisolated func clearLog() {
        writeQueue.sync {
            let url = logFileURL
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                writeLogMessages(["日志已清空".localized], level: "INFO")
            } catch {
                reportLogWriteFailure(error)
            }
        }
    }

    @MainActor
    func exportDiagnosticPackageInteractively() {
        let savePanel = NSSavePanel()
        savePanel.title = "导出诊断包".localized
        savePanel.prompt = "导出".localized
        savePanel.nameFieldStringValue = defaultDiagnosticArchiveName()
        savePanel.allowedContentTypes = [UTType.zip]
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
            return
        }

        do {
            let archiveURL = try createDiagnosticArchive()

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: archiveURL, to: destinationURL)
            logContext(
                "诊断包导出完成".localized,
                details: [
                    ("destination", destinationURL.path),
                    ("redaction_mode", "share_safe")
                ],
                level: "DIAG"
            )
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            logError("导出诊断包失败".localized, error: error, errorCode: "LOG-EXPORT-FAILED")
            let alert = NSAlert()
            alert.messageText = "导出诊断包失败".localized
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好的".localized)
            alert.runModal()
        }
    }

    nonisolated func log(_ message: String, level: String = "INFO") {
        writeQueue.sync {
            writeLogMessages([message], level: level)
        }
    }

    nonisolated func logContext(_ title: String, details: [(String, String?)], level: String = "INFO") {
        var messages = [title]
        for (key, value) in details.sorted(by: { $0.0 < $1.0 }) {
            guard let value, !value.isEmpty else { continue }
            messages.append("  \(key): \(value)")
        }
        writeQueue.sync {
            writeLogMessages(messages, level: level)
        }
    }

    /// 仅在 writeQueue 内调用，使轮转和整组上下文写入保持在同一事务中。
    nonisolated private func writeLogMessages(_ messages: [String], level: String) {
        let logLines = messages.map { buildLogLine(message: $0, level: level) }.joined()
        print(logLines, terminator: "")
        guard isLoggingEnabled else { return }
        rotateLogIfNeeded()
        writeLogLine(logLines)
    }

    nonisolated func logPathState(_ label: String, url: URL, level: String = "TRACE") {
        logContext("路径状态[\(label)]", details: pathStateDetails(for: url), level: level)
    }
    
    /// 日志轮转：当日志超过最大大小时，删除旧内容
    nonisolated private func rotateLogIfNeeded() {
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
            writeLogLine(
                buildLogLine(
                    message: "日志轮转已执行，原大小: \(formatBytes(fileSize))，阈值: \(formatBytes(maxLogSize))",
                    level: "DIAG"
                )
            )
        }
    }
    
    nonisolated func logError(
        _ message: String,
        error: Error? = nil,
        errorCode: String? = nil,
        context: [(String, String?)] = [],
        relatedURLs: [(String, URL)] = []
    ) {
        var details = context

        if let errorCode, !errorCode.isEmpty {
            details.append(("error_code", errorCode))
        }

        if let error {
            details.append(contentsOf: errorDetails(for: error))
        }

        logContext(message, details: details, level: "ERROR")

        for (label, url) in relatedURLs {
            logPathState(label, url: url, level: "ERROR")
        }
    }

    nonisolated func logOperationSummary(
        category: String,
        operationID: String,
        result: String,
        startedAt: Date? = nil,
        errorCode: String? = nil,
        details: [(String, String?)] = []
    ) {
        let endedAt = Date()
        let durationMs = startedAt.map { Int(endedAt.timeIntervalSince($0) * 1000) }
        let filteredDetails = details.reduce(into: [String: String]()) { partialResult, item in
            guard let value = item.1, !value.isEmpty else { return }
            partialResult[item.0] = value
        }

        let record = OperationSummaryRecord(
            operationID: operationID,
            category: category,
            result: result,
            errorCode: errorCode,
            startedAt: startedAt.map(timestampString(for:)),
            endedAt: timestampString(for: endedAt),
            durationMs: durationMs,
            sessionID: sessionID,
            details: filteredDetails
        )

        writeQueue.sync {
            recentOperationSummaries.append(record)
            if recentOperationSummaries.count > maxOperationSummaryCount {
                recentOperationSummaries.removeFirst(recentOperationSummaries.count - maxOperationSummaryCount)
            }
        }

        var summaryDetails: [(String, String?)] = [
            ("operation_id", operationID),
            ("category", category),
            ("result", result),
            ("error_code", errorCode),
            ("duration_ms", durationMs.map(String.init))
        ]
        summaryDetails.append(contentsOf: details)
        logContext("操作结束摘要", details: summaryDetails, level: logLevel(forOperationResult: result))
    }

    /// 获取日志大小的可读字符串
    nonisolated func getLogSizeString() -> String {
        let url = logFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return "0 KB"
        }

        return LocalizedByteCountFormatter.string(fromByteCount: fileSize, allowedUnits: [.kb, .mb])
    }
    
    // MARK: - 系统诊断信息
    
    /// 记录应用启动时的系统信息
    nonisolated func logSystemInfo() {
        logContext(
            "========== 系统诊断信息 ==========".localized,
            details: [
                ("app_version", getAppVersion()),
                ("macos_version", getMacOSVersion()),
                ("device_model", getDeviceModel()),
                ("processor", getProcessorInfo()),
                ("memory", getMemoryInfo())
            ],
            level: "DIAG"
        )
    }
    
    /// 记录外接硬盘信息
    nonisolated func logExternalDriveInfo(at url: URL) {
        diagnosticQueue.async { [self] in
            let details = getVolumeInfo(at: url) + getDiskInterfaceInfo(at: url)
            logContext(
                "========== 外接硬盘信息 ==========".localized,
                details: [("path", url.path)] + details.map { ($0.0, Optional($0.1)) },
                level: "DISK"
            )
        }
    }
    
    /// 记录迁移性能信息
    nonisolated func logMigrationPerformance(appName: String, size: Int64, duration: TimeInterval, sourcePath: String, destPath: String) {
        let speed = duration > 0 ? Double(size) / duration / 1024 / 1024 : 0
        logContext(
            "========== 迁移性能报告 ==========".localized,
            details: [
                ("app_name", appName),
                ("size", formatBytes(size)),
                ("duration_seconds", String(format: "%.2f", duration)),
                ("speed_mb_per_s", String(format: "%.2f", speed)),
                ("source_path", sourcePath),
                ("destination_path", destPath)
            ],
            level: "PERF"
        )
    }
    
    // MARK: - 获取系统信息的辅助方法
    
    nonisolated private func getAppVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知".localized
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知".localized
        return "\(version) (\(build))"
    }
    
    nonisolated private func getMacOSVersion() -> String {
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
    
    nonisolated private func getDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model)
        
        // 尝试获取更友好的名称
        let friendlyName = getMarketingModelName(modelString)
        return "\(friendlyName) (\(modelString))"
    }
    
    nonisolated private func getMarketingModelName(_ identifier: String) -> String {
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
        return models[identifier] ?? "Mac".localized
    }
    
    nonisolated private func getProcessorInfo() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let brandString = String(cString: brand)
        
        // 获取 CPU 核心数
        let processorCount = ProcessInfo.processInfo.processorCount
        let activeCount = ProcessInfo.processInfo.activeProcessorCount
        
        if brandString.isEmpty {
            return "Apple Silicon (\(processorCount) cores, \(activeCount) active)"
        }
        return "\(brandString) (\(activeCount)/\(processorCount) cores)"
    }
    
    nonisolated private func getMemoryInfo() -> String {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        return formatBytes(Int64(physicalMemory))
    }
    
    // MARK: - 获取磁盘信息的辅助方法
    
    nonisolated private func getVolumeInfo(at url: URL) -> [(String, String)] {
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
                info.append(("卷名称".localized, name))
            }
            if let total = values.volumeTotalCapacity {
                info.append(("总容量".localized, formatBytes(Int64(total))))
            }
            if let available = values.volumeAvailableCapacity {
                info.append(("可用空间".localized, formatBytes(Int64(available))))
            }
            if let format = values.volumeLocalizedFormatDescription {
                info.append(("文件系统".localized, format))
            }
            if let removable = values.volumeIsRemovable {
                info.append(("可移除".localized, removable ? "是".localized : "否".localized))
            }
            if let ejectable = values.volumeIsEjectable {
                info.append(("可弹出".localized, ejectable ? "是".localized : "否".localized))
            }
        } catch {
            info.append(("错误".localized, error.localizedDescription))
        }
        
        return info
    }
    
    nonisolated private func getDiskInterfaceInfo(at url: URL) -> [(String, String)] {
        var info: [(String, String)] = []
        
        // 1. 使用 diskutil info -plist 获取基础信息
        var diskName = ""
        var physicalStore = ""
        
        do {
            let data = try Self.runDiagnosticCommand(
                executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
                arguments: ["info", "-plist", url.path]
            )
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                
                // 提取基本信息
                if let location = plist["DeviceLocation"] as? String {
                    info.append(("设备位置".localized, location))
                } else if let mediaName = plist["MediaName"] as? String {
                    info.append(("设备名称".localized, mediaName))
                }
                
                if let blockSize = plist["DeviceBlockSize"] as? Int {
                    info.append(("块大小".localized, String(format: "%d Bytes", blockSize)))
                }
                
                if let protocolName = plist["BusProtocol"] as? String {
                    info.append(("接口协议".localized, protocolName))
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
            info.append(("diskutil错误".localized, error.localizedDescription))
        }
        
        // 2. 使用 system_profiler 获取更详细的速率信息
        // 我们会尝试使用卷名称、设备标识符 (diskX) 和物理存储标识符
        let volumeName = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
        let speedInfo = getConnectionSpeedInfo(volumeName: volumeName, diskIdentifier: diskName, physicalStore: physicalStore)
        info.append(contentsOf: speedInfo)
        
        return info
    }
    
    nonisolated private func getConnectionSpeedInfo(volumeName: String, diskIdentifier: String, physicalStore: String) -> [(String, String)] {
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
            info.append(("接口速率".localized, "未检测到或内置存储".localized))
        }
        
        return info
    }
    
    nonisolated private func runSystemProfiler(dataType: String) -> [String: Any]? {
        guard let data = try? Self.runDiagnosticCommand(
            executableURL: URL(fileURLWithPath: "/usr/sbin/system_profiler"),
            arguments: [dataType, "-json"]
        ) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    enum DiagnosticCommandError: Error, Equatable {
        case timedOut
        case outputLimitExceeded
        case unsuccessfulExit(Int32)
    }

    /// 持续排空 stdout；即使子进程不退出或不关闭管道，也会在期限内返回。
    nonisolated static func runDiagnosticCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 5,
        maximumOutputBytes: Int = 16 * 1024 * 1024
    ) throws -> Data {
        guard timeout.isFinite, timeout > 0 else { throw DiagnosticCommandError.timedOut }
        guard maximumOutputBytes >= 0 else { throw DiagnosticCommandError.outputLimitExceeded }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        defer {
            if process.isRunning {
                process.terminate()
                if terminated.wait(timeout: .now() + .milliseconds(200)) == .timedOut,
                   process.isRunning {
                    // 某些设备工具可能忽略 SIGTERM；只终止本次启动的进程。
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = terminated.wait(timeout: .now() + .milliseconds(200))
                }
            }
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let deadline = DispatchTime.now() + timeout
        try process.run()
        try? pipe.fileHandleForWriting.close()

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw DiagnosticCommandError.timedOut }

            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                guard output.count <= maximumOutputBytes - count else {
                    throw DiagnosticCommandError.outputLimitExceeded
                }
                output.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { break }

            let readError = errno
            if readError == EINTR { continue }
            guard readError == EAGAIN else {
                throw POSIXError(POSIXErrorCode(rawValue: readError) ?? .EIO)
            }

            // 非阻塞读取保证 read 不会越过期限；poll 避免无输出时忙等。
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remainingMilliseconds = (deadline.uptimeNanoseconds - now + 999_999) / 1_000_000
            if poll(&pollDescriptor, 1, Int32(min(remainingMilliseconds, 50))) < 0, errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        guard terminated.wait(timeout: deadline) == .success else { throw DiagnosticCommandError.timedOut }
        guard process.terminationStatus == 0 else {
            throw DiagnosticCommandError.unsuccessfulExit(process.terminationStatus)
        }
        return output
    }
    
    // 通用递归搜索
    nonisolated private func searchDeviceRecursive(in devices: [[String: Any]], searchTerms: [String], type: String) -> [(String, String)]? {
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
                    if let speed = device["device_speed"] as? String { info.append(("设备速率".localized, speed)) }
                    if let busSpeed = device["host_controller_speed"] as? String { info.append(("总线速率".localized, busSpeed)) }
                } else if type == "Thunderbolt" {
                    if let speed = device["link_speed"] as? String { info.append(("链接速率".localized, speed)) }
                    if let width = device["link_width"] as? String { info.append(("链接带宽".localized, width)) }
                } else if type == "NVMe" {
                    if let width = device["link_width"] as? String { info.append(("链接宽度".localized, width)) }
                    if let speed = device["link_speed"] as? String { info.append(("链接速率".localized, speed)) }
                }
                
                info.append(("连接类型".localized, type))
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
    
    nonisolated private func formatBytes(_ bytes: Int64) -> String {
        LocalizedByteCountFormatter.string(fromByteCount: bytes)
    }

    nonisolated private func timestampString(for date: Date) -> String {
        dateFormatter.string(from: date)
    }

    nonisolated private func logLevel(forOperationResult result: String) -> String {
        switch result {
        case "success":
            return "INFO"
        case "success_with_warning", "rolled_back":
            return "WARN"
        default:
            return "ERROR"
        }
    }

    nonisolated private func selectedAppLanguageCode() -> String {
        userDefaults.string(forKey: "selectedLanguage") ?? "system"
    }

    nonisolated private func selectedAppLocaleIdentifier() -> String {
        let selectedLanguage = selectedAppLanguageCode()
        if selectedLanguage == "system" {
            return Locale.current.identifier
        }
        return Locale(identifier: selectedLanguage).identifier
    }

    nonisolated private func defaultDiagnosticArchiveName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "AppPorts-Diagnostic-\(formatter.string(from: Date())).zip"
    }

    nonisolated private func createDiagnosticArchive() throws -> URL {
        let tempRootURL = fileManager.temporaryDirectory.appendingPathComponent("AppPorts-Diagnostic-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)

        let packageURL = try buildDiagnosticPackage(in: tempRootURL)
        let archiveURL = tempRootURL.appendingPathComponent("\(packageURL.lastPathComponent).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", packageURL.path, archiveURL.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AppPorts.AppLogger",
                code: 7001,
                userInfo: [NSLocalizedDescriptionKey: "无法压缩诊断包".localized]
            )
        }

        return archiveURL
    }

    nonisolated func buildDiagnosticPackage(in rootURL: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let packageURL = rootURL.appendingPathComponent("AppPorts-Diagnostic-\(formatter.string(from: Date()))", isDirectory: true)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let (currentLogContent, operationSummaries) = writeQueue.sync {
            (
                (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? "日志文件不存在或暂时不可读取".localized,
                recentOperationSummaries
            )
        }
        let redactedLogContent = redactedDiagnosticText(from: currentLogContent)
        let recentFailures = operationSummaries.filter { ["failed", "rolled_back", "success_with_warning"].contains($0.result) }

        let metadata: [String: String] = [
            "generated_at": timestampString(for: Date()),
            "session_id": sessionID,
            "pid": String(processID),
            "app_version": getAppVersion(),
            "bundle_id": Bundle.main.bundleIdentifier ?? "未知".localized,
            "app_language": selectedAppLanguageCode(),
            "app_locale": selectedAppLocaleIdentifier(),
            "system_locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "log_file_name": logFileURL.lastPathComponent,
            "log_file_size": getLogSizeString(),
            "redaction_mode": "share_safe",
            "recent_operation_count": String(operationSummaries.count),
            "recent_failure_count": String(recentFailures.count)
        ]

        try writeJSON(metadata, to: packageURL.appendingPathComponent("diagnostic-summary.json"))
        try writeJSON(operationSummaries, to: packageURL.appendingPathComponent("recent-operations.json"))
        try writeJSON(recentFailures.suffix(20), to: packageURL.appendingPathComponent("recent-failures.json"))

        let summaryText = redactedDiagnosticText(from: buildDiagnosticSummaryText(
            metadata: metadata,
            lastFailure: recentFailures.last,
            operationCount: operationSummaries.count
        ))
        try summaryText.write(
            to: packageURL.appendingPathComponent("diagnostic-summary.txt"),
            atomically: true,
            encoding: .utf8
        )
        try redactedLogContent.write(
            to: packageURL.appendingPathComponent("AppPorts_Log.share-safe.txt"),
            atomically: true,
            encoding: .utf8
        )

        return packageURL
    }

    nonisolated func redactedDiagnosticText(from rawText: String) -> String {
        var sanitized = rawText
        let homeDirectory = NSHomeDirectory()

        if !homeDirectory.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: homeDirectory + "/", with: "~/")
            if sanitized == homeDirectory { sanitized = "~" }
        }

        // 路径组件允许空格；不能在第一个空格处结束，否则仍会泄露卷名称后半段。
        // 先对字符串值脱敏，再编码 JSON，避免破坏 JSON 转义和类型。
        let volumeLabels = Self.volumeNameLabels.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let redactionRules: [(pattern: String, replacement: String)] = [
            (#"/Users/[^/\r\n]+"#, "/Users/<redacted-user>"),
            (#"/Volumes/[^/\r\n]+"#, "/Volumes/<redacted-volume>"),
            (#"(?m)^((?:\[[^\]\r\n]*\][ \t]*)*[ \t]*(?:"# + volumeLabels + #"):[ \t]*)[^\r\n]+"#, "$1<redacted-volume>")
        ]

        for rule in redactionRules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = regex.stringByReplacingMatches(in: sanitized, range: range, withTemplate: rule.replacement)
        }

        return sanitized
    }

    /// 包含旧日志可能使用的语言，切换应用语言后导出仍能识别独立卷名称字段。
    nonisolated private static let volumeNameLabels: Set<String> = {
        var labels: Set<String> = ["volume", "volume_name", "卷名称", "Volume Name"]
        for localization in Bundle.main.localizations {
            if let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                labels.insert(bundle.localizedString(forKey: "卷名称", value: nil, table: nil))
            }
        }
        return labels
    }()

    nonisolated func recentOperationSummariesSnapshot() -> [OperationSummaryRecord] {
        writeQueue.sync { recentOperationSummaries }
    }

    nonisolated func resetDiagnosticStateForTesting() {
        writeQueue.sync {
            recentOperationSummaries.removeAll()
        }
    }

    nonisolated private func buildLogLine(message: String, level: String) -> String {
        let timestamp = dateFormatter.string(from: Date())
        return "[\(timestamp)] [\(level)] [session:\(sessionID)] [pid:\(processID)] \(message)\n"
    }

    nonisolated private func writeLogLine(_ logLine: String) {
        guard let data = logLine.data(using: .utf8) else { return }

        let url = logFileURL
        do {
            if fileManager.fileExists(atPath: url.path) {
                let fileHandle = try FileHandle(forWritingTo: url)
                defer { try? fileHandle.close() }
                try Self.appendLogData(data, to: fileHandle)
            } else {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        } catch {
            reportLogWriteFailure(error)
        }
    }

    nonisolated static func appendLogData(_ data: Data, to fileHandle: FileHandle) throws {
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: data)
    }

    nonisolated private func reportLogWriteFailure(_ error: Error) {
        // 不再次调用 log，以免日志磁盘写满或被卸载时递归失败。
        print(buildLogLine(message: "日志文件写入失败: \(error)", level: "WARN"), terminator: "")
    }

    nonisolated private func pathStateDetails(for url: URL) -> [(String, String?)] {
        let standardizedURL = url.standardizedFileURL
        let exists = fileManager.fileExists(atPath: standardizedURL.path)
        var details: [(String, String?)] = [
            ("path", url.path),
            ("standardized_path", standardizedURL.path),
            ("exists", exists ? "true" : "false")
        ]

        guard exists else {
            let parentURL = standardizedURL.deletingLastPathComponent()
            details.append(("parent_path", parentURL.path))
            details.append(("parent_exists", fileManager.fileExists(atPath: parentURL.path) ? "true" : "false"))
            details.append(("parent_writable", fileManager.isWritableFile(atPath: parentURL.path) ? "true" : "false"))
            return details
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .volumeNameKey,
            .isWritableKey
        ]
        let values = try? standardizedURL.resourceValues(forKeys: resourceKeys)
        details.append(("kind", describeFileKind(values)))
        details.append(("writable", (values?.isWritable ?? fileManager.isWritableFile(atPath: standardizedURL.path)) ? "true" : "false"))

        if let fileSize = values?.fileSize {
            details.append(("size", formatBytes(Int64(fileSize))))
        }
        if let volumeName = values?.volumeName {
            details.append(("volume", volumeName))
        }
        if let createdAt = values?.creationDate {
            details.append(("created_at", dateFormatter.string(from: createdAt)))
        }
        if let modifiedAt = values?.contentModificationDate {
            details.append(("modified_at", dateFormatter.string(from: modifiedAt)))
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: standardizedURL.path) {
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                details.append(("posix_permissions", String(format: "%#o", permissions.intValue)))
            }
            if let immutable = attributes[.immutable] as? Bool {
                details.append(("immutable", immutable ? "true" : "false"))
            }
        }

        if let symlinkTarget = resolveSymlinkDestination(at: standardizedURL) {
            details.append(("symlink_target", symlinkTarget.path))
        }

        let contentsURL = standardizedURL.appendingPathComponent("Contents")
        if let contentsTarget = resolveSymlinkDestination(at: contentsURL) {
            details.append(("contents_symlink_target", contentsTarget.path))
        }

        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        if let macOSTarget = resolveSymlinkDestination(at: macOSURL) {
            details.append(("macos_symlink_target", macOSTarget.path))
        }

        return details
    }

    nonisolated private func describeFileKind(_ values: URLResourceValues?) -> String {
        if values?.isSymbolicLink == true { return "symlink" }
        if values?.isDirectory == true { return "directory" }
        if values?.isRegularFile == true { return "file" }
        return "unknown"
    }

    nonisolated private func resolveSymlinkDestination(at url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let rawPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }

        return URL(fileURLWithPath: rawPath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    nonisolated private func errorDetails(for error: Error, prefix: String = "error") -> [(String, String?)] {
        let nsError = error as NSError
        var details: [(String, String?)] = [
            ("\(prefix)_description", error.localizedDescription),
            ("\(prefix)_type", String(describing: type(of: error))),
            ("\(prefix)_domain", nsError.domain),
            ("\(prefix)_code", String(nsError.code))
        ]

        if let failureReason = nsError.localizedFailureReason, !failureReason.isEmpty {
            details.append(("\(prefix)_failure_reason", failureReason))
        }
        if let recoverySuggestion = nsError.localizedRecoverySuggestion, !recoverySuggestion.isEmpty {
            details.append(("\(prefix)_recovery_suggestion", recoverySuggestion))
        }
        if let helpAnchor = nsError.helpAnchor, !helpAnchor.isEmpty {
            details.append(("\(prefix)_help_anchor", helpAnchor))
        }
        if let filePath = nsError.userInfo[NSFilePathErrorKey] as? String {
            details.append(("\(prefix)_file_path", filePath))
        }
        if let url = nsError.userInfo[NSURLErrorKey] as? URL {
            details.append(("\(prefix)_url", url.path))
        }

        let interestingUserInfoKeys = [
            "NSSourceFilePathErrorKey",
            "NSDestinationFilePath",
            "NSURLPathKey",
            "NSDebugDescription"
        ]
        for key in interestingUserInfoKeys {
            if let value = nsError.userInfo[key] {
                details.append(("\(prefix)_\(key)", String(describing: value)))
            }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            details.append(contentsOf: errorDetails(for: underlying, prefix: "\(prefix)_underlying"))
        }

        if let detailedErrors = nsError.userInfo[NSDetailedErrorsKey] as? [NSError] {
            for (index, nestedError) in detailedErrors.enumerated() {
                details.append(contentsOf: errorDetails(for: nestedError, prefix: "\(prefix)_detailed_\(index)"))
            }
        }

        return details
    }

    nonisolated private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        let jsonValue = try JSONSerialization.jsonObject(with: encoder.encode(value))
        let data = try JSONSerialization.data(
            withJSONObject: redactedDiagnosticValue(jsonValue),
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    nonisolated private func redactedDiagnosticValue(_ value: Any) -> Any {
        if let text = value as? String { return redactedDiagnosticText(from: text) }
        if let values = value as? [Any] { return values.map(redactedDiagnosticValue) }
        if let fields = value as? [String: Any] {
            return fields.reduce(into: [String: Any]()) { result, field in
                result[field.key] = Self.volumeNameLabels.contains(field.key) && field.value is String
                    ? "<redacted-volume>"
                    : redactedDiagnosticValue(field.value)
            }
        }
        return value
    }

    nonisolated private func buildDiagnosticSummaryText(
        metadata: [String: String],
        lastFailure: OperationSummaryRecord?,
        operationCount: Int
    ) -> String {
        var lines: [String] = [
            "AppPorts 诊断摘要".localized,
            "generated_at: \(metadata["generated_at"] ?? "unknown")",
            "session_id: \(metadata["session_id"] ?? "unknown")",
            "app_version: \(metadata["app_version"] ?? "unknown")",
            "app_language: \(metadata["app_language"] ?? "unknown")",
            "app_locale: \(metadata["app_locale"] ?? "unknown")",
            "system_locale: \(metadata["system_locale"] ?? "unknown")",
            "timezone: \(metadata["timezone"] ?? "unknown")",
            "log_file_size: \(metadata["log_file_size"] ?? "unknown")",
            "redaction_mode: share_safe",
            "recent_operation_count: \(operationCount)"
        ]

        if let lastFailure {
            lines.append("last_failure_operation_id: \(lastFailure.operationID)")
            lines.append("last_failure_category: \(lastFailure.category)")
            lines.append("last_failure_result: \(lastFailure.result)")
            lines.append("last_failure_error_code: \(lastFailure.errorCode ?? "none")")
            if let durationMs = lastFailure.durationMs {
                lines.append("last_failure_duration_ms: \(durationMs)")
            }
        } else {
            lines.append("last_failure: none")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
