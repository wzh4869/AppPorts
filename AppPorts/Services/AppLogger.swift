//
//  AppLogger.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation
import AppKit
import Darwin
import OSLog
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

    struct AppInventoryEntry: Codable, Sendable, Equatable {
        let scope: String
        let name: String
        let status: String
        let version: String?
        let containerKind: String
        let isSystemApp: Bool
        let isAppStoreApp: Bool
        let isRunning: Bool
    }

    private enum LogStreamKind {
        case main
        case trace
    }

    private struct LogFileSet {
        let mainCurrent: URL
        let mainArchive: URL
        let traceCurrent: URL
        let traceArchive: URL
        let lockFile: URL
        let operationSummariesFile: URL
    }

    /// 默认最大日志总配额：10 MB（主日志与追踪日志按 6:4 共享该总配额）
    nonisolated static let defaultMaxLogSizeBytes: Int64 = 10 * 1024 * 1024

    /// 日志大小不限标记值（不执行轮转，永不自动删除或覆盖旧日志）
    nonisolated static let unlimitedMaxLogSizeBytes: Int64 = -1

    /// 设置与菜单栏共享的可选日志大小档位（MB）
    nonisolated static let selectableLogSizeMBOptions: [Int] = [1, 2, 5, 10, 20, 50, 100]

    nonisolated private static let maxLogSizeDefaultVersionKey = "MaxLogSizeDefaultVersion"
    nonisolated private static let currentMaxLogSizeDefaultVersion = 1
    nonisolated private static let maxDiagnosticExportMainLogBytes: Int64 = 16 * 1024 * 1024
    nonisolated private static let maxDiagnosticExportTraceLogBytes: Int64 = 8 * 1024 * 1024

    /// 单例实例
    static let shared = AppLogger(userDefaults: .standard,
        usesTestLogDirectory: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    
    // MARK: - 私有属性
    
    /// 线程安全的 POSIX 日期格式化锁与格式化器
    private let timestampLock = NSLock()
    private let timestampFormatter: DateFormatter
    private let archiveNameFormatter: DateFormatter

    /// Apple Unified Logging 通道，支撑系统日志与 `--telemetry`
    private let mainOSLogger = Logger(subsystem: "com.shimoko.AppPorts", category: "general")
    private let traceOSLogger = Logger(subsystem: "com.shimoko.AppPorts", category: "trace")
    
    /// 文件管理器
    nonisolated(unsafe) private let fileManager = FileManager.default

    /// 串行日志队列，避免多线程写文件交错且不阻塞主线程
    private let writeQueue = DispatchQueue(label: "com.shimoko.AppPorts.logger", qos: .utility)

    /// 磁盘查询可能等待设备响应，不占用调用者（尤其是主线程）。
    private let diagnosticQueue = DispatchQueue(label: "com.shimoko.AppPorts.logger.diagnostics", qos: .utility)
    @MainActor private var diagnosticExportInProgress = false

    nonisolated(unsafe) private let userDefaults: UserDefaults
    nonisolated private let usesTestLogDirectory: Bool
    nonisolated private let trashItemHandler: (@Sendable (URL) throws -> Void)?

    /// 当前启动会话 ID，便于用户粘贴日志后快速关联一次运行
    nonisolated private let sessionID: String

    /// 当前进程 ID
    nonisolated private let processID: Int32 = ProcessInfo.processInfo.processIdentifier

    /// 最近操作摘要缓存（同时持久化到磁盘，跨重启与后台代理可见）
    nonisolated(unsafe) private var recentOperationSummaries: [OperationSummaryRecord] = []

    /// 最近一次扫描得到的应用清单快照（仅保存在内存，仅在用户勾选时写入诊断包）
    nonisolated(unsafe) private var latestAppInventoryByScope: [String: [AppInventoryEntry]] = [:]
    
    /// UserDefaults 存储键
    nonisolated private let logPathKey = "LogFilePath"         // 日志文件路径
    nonisolated private let maxLogSizeKey = "MaxLogSizeBytes"  // 最大日志大小
    nonisolated private let logEnabledKey = "LogEnabled"       // 日志启用状态

    /// 最多保留最近 100 条操作摘要，避免无限增长
    nonisolated private let maxOperationSummaryCount = 100
    
    // MARK: - 公共属性
    
    /// 日志是否启用
    ///
    /// 控制日志是否写入文件。关闭后：
    /// - 日志仍会写入系统统一日志通道（便于实时遥测/调试）
    /// - 不会写入本地日志文件（节省磁盘空间）
    ///
    /// - Note: 默认为启用状态
    nonisolated var isLoggingEnabled: Bool {
        get {
            // 默认为开启 (true)
            userDefaults.object(forKey: logEnabledKey) == nil ? true : userDefaults.bool(forKey: logEnabledKey)
        }
        set {
            if newValue {
                userDefaults.set(true, forKey: logEnabledKey)
                log("日志记录已启用".localized)
            } else {
                log("日志记录已禁用".localized)
                flush()
                userDefaults.set(false, forKey: logEnabledKey)
            }
        }
    }

    /// 默认主日志文件路径
    nonisolated var defaultLogFileURL: URL {
        if usesTestLogDirectory {
            let directory = fileManager.temporaryDirectory.appendingPathComponent("AppPortsTestLogs-\(ProcessInfo.processInfo.processIdentifier)")
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("AppPorts_Log.txt")
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AppPorts")
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("AppPorts_Log.txt")
    }

    /// 是否正在使用用户自定义日志路径
    nonisolated var isUsingCustomLogPath: Bool {
        guard !usesTestLogDirectory,
              let savedPath = userDefaults.string(forKey: logPathKey),
              !savedPath.isEmpty else {
            return false
        }
        return URL(fileURLWithPath: savedPath).standardizedFileURL != defaultLogFileURL.standardizedFileURL
    }
    
    /// 当前主日志文件路径
    ///
    /// 返回主日志文件的完整 URL。路径来源优先级：
    /// 1. 用户自定义路径（通过 `setLogPath(_:)` 设置）
    /// 2. 默认路径：`~/Library/Application Support/AppPorts/AppPorts_Log.txt`
    nonisolated var logFileURL: URL {
        if usesTestLogDirectory {
            return defaultLogFileURL
        }
        if let savedPath = userDefaults.string(forKey: logPathKey), !savedPath.isEmpty {
            return URL(fileURLWithPath: savedPath)
        }
        return defaultLogFileURL
    }

    /// 当前追踪日志文件路径（与主日志位于同一目录）
    nonisolated var traceLogFileURL: URL {
        logFileSet(for: logFileURL).traceCurrent
    }
    
    /// 是否启用不限大小模式（不执行自动轮转，永不删除或覆盖旧日志）
    nonisolated var isLogSizeUnlimited: Bool {
        maxLogSize == Self.unlimitedMaxLogSizeBytes
    }

    /// 最大日志总大小（字节），由主日志（60%）与追踪日志（40%）共同分摊。
    ///
    /// - Note: 默认为 10 MB；已高于 10 MB 或已设为不限（`-1`）的历史配置保持不变。
    nonisolated var maxLogSize: Int64 {
        get {
            let saved = userDefaults.integer(forKey: maxLogSizeKey)
            if saved == Int(Self.unlimitedMaxLogSizeBytes) {
                return Self.unlimitedMaxLogSizeBytes
            }
            return saved > 0 ? Int64(saved) : Self.defaultMaxLogSizeBytes
        }
        set {
            userDefaults.set(Int(newValue), forKey: maxLogSizeKey)
            userDefaults.set(Self.currentMaxLogSizeDefaultVersion, forKey: Self.maxLogSizeDefaultVersionKey)
        }
    }
    
    // MARK: - 初始化
    
    /// 应用使用标准设置；独立设置可用于隔离诊断测试。
    nonisolated init(
        userDefaults: UserDefaults,
        usesTestLogDirectory: Bool = false,
        trashItemHandler: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.usesTestLogDirectory = usesTestLogDirectory
        self.userDefaults = userDefaults
        self.trashItemHandler = trashItemHandler

        let posixLocale = Locale(identifier: "en_US_POSIX")
        let logFormatter = DateFormatter()
        logFormatter.locale = posixLocale
        logFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.timestampFormatter = logFormatter

        let fileFormatter = DateFormatter()
        fileFormatter.locale = posixLocale
        fileFormatter.dateFormat = "yyyyMMdd-HHmmss"
        self.archiveNameFormatter = fileFormatter

        self.sessionID = String(UUID().uuidString.prefix(8))
        migrateDefaultMaxLogSizeIfNeeded()
    }

    /// 一次性将旧版 `< 10 MB` 配置平滑提升到新默认 10 MB；高于 10 MB 的用户配置保持不动。
    nonisolated private func migrateDefaultMaxLogSizeIfNeeded() {
        let migratedVersion = userDefaults.integer(forKey: Self.maxLogSizeDefaultVersionKey)
        guard migratedVersion < Self.currentMaxLogSizeDefaultVersion else { return }
        let saved = Int64(userDefaults.integer(forKey: maxLogSizeKey))
        if saved > 0 && saved < Self.defaultMaxLogSizeBytes {
            userDefaults.set(Int(Self.defaultMaxLogSizeBytes), forKey: maxLogSizeKey)
        }
        userDefaults.set(Self.currentMaxLogSizeDefaultVersion, forKey: Self.maxLogSizeDefaultVersionKey)
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
                ("max_log_size", formattedMaxLogSize()),
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
    
    /// 设置日志文件路径（主日志、追踪日志与轮转卷自动位于同目录）
    nonisolated func setLogPath(_ url: URL) {
        writeQueue.sync {
            userDefaults.set(url.path, forKey: logPathKey)
        }
        logContext("日志路径已更改", details: [("path", url.path)])
    }

    /// 恢复默认日志路径
    nonisolated func resetLogPathToDefault() {
        let defaultURL = writeQueue.sync { () -> URL in
            userDefaults.removeObject(forKey: logPathKey)
            return defaultLogFileURL
        }
        logContext("日志路径已恢复默认", details: [("path", defaultURL.path)])
    }

    /// 排空异步日志写入队列，确保进程退出或测试读取前所有记录已落盘
    nonisolated func flush() {
        writeQueue.sync {}
    }

    /// 更新内存中最新一次应用扫描清单（仅在用户主动勾选包含应用列表时写入诊断包）
    nonisolated func updateAppInventorySnapshot(scope: String, entries: [AppInventoryEntry]) {
        writeQueue.async { [self] in
            latestAppInventoryByScope[scope] = entries
        }
    }
    
    /// 在 Finder 中打开日志文件
    @MainActor
    func openLogInFinder() {
        flush()
        let files = logFileSet(for: logFileURL)
        if fileManager.fileExists(atPath: files.mainCurrent.path) {
            NSWorkspace.shared.activateFileViewerSelecting([files.mainCurrent])
        } else if fileManager.fileExists(atPath: files.traceCurrent.path) {
            NSWorkspace.shared.activateFileViewerSelecting([files.traceCurrent])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([files.mainCurrent.deletingLastPathComponent()])
        }
    }
    
    /// 弹出二次确认框后再清空日志；默认按回车为取消，避免误点。
    @MainActor
    @discardableResult
    func confirmAndClearLog() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确定要清空日志吗？".localized
        alert.informativeText = "现有日志文件将移至废纸篓，可在需要时从废纸篓恢复。".localized
        if LanguageManager.shared.layoutDirection == .rightToLeft {
            alert.window.contentView?.userInterfaceLayoutDirection = .rightToLeft
        }
        let confirmButton = alert.addButton(withTitle: "清空日志".localized)
        confirmButton.hasDestructiveAction = true
        confirmButton.keyEquivalent = ""
        let cancelButton = alert.addButton(withTitle: "取消".localized)
        cancelButton.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        clearLog()
        return true
    }

    /// 清空全部主日志、追踪日志、滚动卷及操作摘要缓存（日志文件优先移至废纸篓以便误操作恢复）
    nonisolated func clearLog() {
        let timestamp = timestampString(for: Date())
        writeQueue.sync {
            let files = logFileSet(for: logFileURL)
            recentOperationSummaries.removeAll()
            withFileLock(at: files.lockFile) {
                for url in [files.mainCurrent, files.mainArchive, files.traceCurrent, files.traceArchive] {
                    if fileManager.fileExists(atPath: url.path) && !isDirectoryPath(url) {
                        do {
                            try moveLogFileToTrashOrRemove(at: url)
                        } catch {
                            reportLogWriteFailure(error)
                        }
                    }
                }
                if fileManager.fileExists(atPath: files.operationSummariesFile.path) && !isDirectoryPath(files.operationSummariesFile) {
                    do {
                        try fileManager.removeItem(at: files.operationSummariesFile)
                    } catch {
                        reportLogWriteFailure(error)
                    }
                }
            }
            writeLogMessages(["日志已清空".localized], level: "INFO", timestamp: timestamp, titleForTelemetry: "日志已清空")
        }
    }

    nonisolated private func moveLogFileToTrashOrRemove(at url: URL) throws {
        if let trashItemHandler {
            do {
                try trashItemHandler(url)
                return
            } catch {
                try fileManager.removeItem(at: url)
                return
            }
        }
        let isRunningUnderTests = usesTestLogDirectory || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isRunningUnderTests {
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                return
            } catch {
                // 不支持废纸篓的卷/网络路径回退为直接删除
            }
        }
        try fileManager.removeItem(at: url)
    }

    @MainActor
    func exportDiagnosticPackageInteractively() {
        guard !diagnosticExportInProgress else { return }
        diagnosticExportInProgress = true
        guard let options = DiagnosticExportDialog.run(defaultFileName: defaultDiagnosticArchiveName()) else {
            diagnosticExportInProgress = false
            return
        }
        let destinationURL = options.destinationURL
        let includeAppInventory = options.includeAppInventory
        Task { @MainActor in
            defer { diagnosticExportInProgress = false }
            do {
                try await Task.detached(priority: .utility) { [self] in
                    try exportDiagnosticArchive(to: destinationURL, includeAppInventory: includeAppInventory)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出诊断包失败".localized
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好的".localized)
                alert.runModal()
            }
        }
    }

    nonisolated private func exportDiagnosticArchive(to destinationURL: URL, includeAppInventory: Bool) throws {
        do {
            let archiveURL = try createDiagnosticArchive(includeAppInventory: includeAppInventory)
            defer { try? fileManager.removeItem(at: archiveURL.deletingLastPathComponent()) }
            // Foundation writes a temporary sibling first and atomically
            // replaces the destination only when the new archive is complete.
            // A failed read/write leaves an existing export untouched.
            try Data(contentsOf: archiveURL, options: .mappedIfSafe).write(to: destinationURL, options: .atomic)
            logContext(
                "诊断包导出完成".localized,
                details: [
                    ("destination", destinationURL.path),
                    ("redaction_mode", "share_safe"),
                    ("app_inventory_included", String(includeAppInventory))
                ],
                level: "DIAG"
            )
        } catch {
            logError("导出诊断包失败".localized, error: error, errorCode: "LOG-EXPORT-FAILED")
            throw error
        }
    }

    nonisolated func log(_ message: String, level: String = "INFO") {
        let timestamp = timestampString(for: Date())
        writeQueue.async { [self] in
            writeLogMessages([message], level: level, timestamp: timestamp, titleForTelemetry: nil)
        }
    }

    nonisolated func logContext(_ title: String, details: [(String, String?)], level: String = "INFO") {
        let timestamp = timestampString(for: Date())
        var messages = [title]
        for (key, value) in details.sorted(by: { $0.0 < $1.0 }) {
            guard let value, !value.isEmpty else { continue }
            messages.append("  \(key): \(value)")
        }
        writeQueue.async { [self] in
            writeLogMessages(messages, level: level, timestamp: timestamp, titleForTelemetry: title)
        }
    }

    /// 仅在 writeQueue 内调用，使跨进程加锁、O(1) 滚动轮转和整组上下文写入保持在同一事务中。
    nonisolated private func writeLogMessages(_ messages: [String], level: String, timestamp: String, titleForTelemetry: String?) {
        let normalizedLevel = level.uppercased()
        let logLines = messages.map { buildLogLine(message: $0, level: normalizedLevel, timestamp: timestamp) }.joined()
        emitToUnifiedLog(messages: messages, level: normalizedLevel, title: titleForTelemetry)
        guard isLoggingEnabled else { return }

        let stream: LogStreamKind = normalizedLevel == "TRACE" ? .trace : .main
        writeStreamPayload(logLines, stream: stream, timestamp: timestamp)
    }

    nonisolated func logPathState(_ label: String, url: URL, level: String = "DIAG") {
        logContext("路径状态[\(label)]", details: pathStateDetails(for: url), level: level)
    }

    nonisolated private func logFileSet(for mainURL: URL) -> LogFileSet {
        let directory = mainURL.deletingLastPathComponent()
        let fileName = mainURL.lastPathComponent
        let ext = mainURL.pathExtension
        let stem = ext.isEmpty ? fileName : String(fileName.dropLast(ext.count + 1))
        let archiveName: (String) -> String = { base in
            ext.isEmpty ? "\(base).1" : "\(base).1.\(ext)"
        }
        let traceStem = stem == "AppPorts_Log" ? "AppPorts_Trace" : "\(stem)_Trace"
        let traceFileName = ext.isEmpty ? traceStem : "\(traceStem).\(ext)"
        return LogFileSet(
            mainCurrent: mainURL,
            mainArchive: directory.appendingPathComponent(archiveName(stem)),
            traceCurrent: directory.appendingPathComponent(traceFileName),
            traceArchive: directory.appendingPathComponent(archiveName(traceStem)),
            lockFile: directory.appendingPathComponent(".\(stem).lock"),
            operationSummariesFile: directory.appendingPathComponent(".\(stem).operations.json")
        )
    }

    nonisolated private func singleVolumeLimitBytes(for stream: LogStreamKind) -> Int64 {
        let total = max(maxLogSize, 4 * 1024)
        let mainTotal = (total * 60) / 100
        let traceTotal = total - mainTotal
        switch stream {
        case .main:
            return max(mainTotal / 2, 1024)
        case .trace:
            return max(traceTotal / 2, 1024)
        }
    }

    nonisolated private func emitToUnifiedLog(messages: [String], level: String, title: String?) {
        let joined = messages.joined(separator: " | ")
        #if DEBUG
        switch level {
        case "ERROR":
            mainOSLogger.error("[\(self.sessionID, privacy: .public)] \(joined, privacy: .public)")
        case "WARN":
            mainOSLogger.warning("[\(self.sessionID, privacy: .public)] \(joined, privacy: .public)")
        case "TRACE":
            traceOSLogger.debug("[\(self.sessionID, privacy: .public)] \(joined, privacy: .public)")
        default:
            mainOSLogger.info("[\(self.sessionID, privacy: .public)] [\(level, privacy: .public)] \(joined, privacy: .public)")
        }
        #else
        switch level {
        case "ERROR":
            if let title {
                mainOSLogger.error("[\(self.sessionID, privacy: .public)] \(title, privacy: .public) \(joined, privacy: .private)")
            } else {
                mainOSLogger.error("[\(self.sessionID, privacy: .public)] \(joined, privacy: .private)")
            }
        case "WARN":
            if let title {
                mainOSLogger.warning("[\(self.sessionID, privacy: .public)] \(title, privacy: .public) \(joined, privacy: .private)")
            } else {
                mainOSLogger.warning("[\(self.sessionID, privacy: .public)] \(joined, privacy: .private)")
            }
        case "TRACE":
            if let title {
                traceOSLogger.debug("[\(self.sessionID, privacy: .public)] \(title, privacy: .public) \(joined, privacy: .private)")
            } else {
                traceOSLogger.debug("[\(self.sessionID, privacy: .public)] \(joined, privacy: .private)")
            }
        default:
            if let title {
                mainOSLogger.info("[\(self.sessionID, privacy: .public)] [\(level, privacy: .public)] \(title, privacy: .public) \(joined, privacy: .private)")
            } else {
                mainOSLogger.info("[\(self.sessionID, privacy: .public)] [\(level, privacy: .public)] \(joined, privacy: .private)")
            }
        }
        #endif
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

    /// Preserve typed causes before callers reduce failures to user-facing strings.
    nonisolated func logOperationFailure(category: String, operationID: String, error: Error,
                                         stage: String? = nil, startedAt: Date? = nil,
                                         details: [(String, String?)] = [], relatedURLs: [(String, URL)] = [], result: String = "failed") {
        var current: NSError? = error as NSError
        var diagnosticCode: String?
        for _ in 0..<6 {
            guard let cause = current else { break }
            if let fields = cause.userInfo[OperationBlockage.diagnosticFieldsKey] as? [String: String],
               let code = fields["diagnostic_code"] { diagnosticCode = code; break }
            current = (cause.userInfo[NSUnderlyingErrorKey] as? Error).map { $0 as NSError }
        }
        let code = diagnosticCode ?? "OPERATION-FAILED"
        let facts = details + [("failure_stage", stage)] + errorDetails(for: error, prefix: "cause")
        logError(result == "success_with_warning" ? "操作收尾未完成" : "操作执行失败", error: error,
                 context: [("operation_id", operationID), ("category", category), ("diagnostic_code", code),
                           ("failure_stage", stage)] + details,
                 relatedURLs: relatedURLs)
        logOperationSummary(category: category, operationID: operationID, result: result, startedAt: startedAt,
                            errorCode: code, details: facts)
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

        writeQueue.async { [self] in
            appendOperationSummaryRecord(record)
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

    /// 获取全部主日志与追踪日志分卷的总大小（字节）
    nonisolated func totalLogSizeBytes() -> Int64 {
        writeQueue.sync {
            let files = logFileSet(for: logFileURL)
            return fileSizeBytes(at: files.mainCurrent)
                + fileSizeBytes(at: files.mainArchive)
                + fileSizeBytes(at: files.traceCurrent)
                + fileSizeBytes(at: files.traceArchive)
        }
    }

    /// 获取日志总大小的可读字符串
    nonisolated func getLogSizeString() -> String {
        let totalBytes = totalLogSizeBytes()
        guard totalBytes > 0 else { return "0 KB" }
        return LocalizedByteCountFormatter.string(fromByteCount: totalBytes, allowedUnits: [.kb, .mb])
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
        
        let macOSName: String
        switch version.majorVersion {
        case 26: macOSName = "macOS Tahoe"
        case 15: macOSName = "macOS Sequoia"
        case 14: macOSName = "macOS Sonoma"
        case 13: macOSName = "macOS Ventura"
        case 12: macOSName = "macOS Monterey"
        default: macOSName = "macOS"
        }
        
        return "\(macOSName) \(versionString)"
    }
    
    nonisolated private func getDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model)
        
        if let friendlyName = getMarketingModelName(modelString) {
            return "\(friendlyName) (\(modelString))"
        }
        return modelString
    }
    
    nonisolated private func getMarketingModelName(_ identifier: String) -> String? {
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
            "Mac15,14": "Mac Studio (M3 Ultra, 2025)",
            "Mac16,1": "MacBook Pro (14-inch, M4, 2024)",
            "Mac16,2": "iMac (24-inch, M4, 2024)",
            "Mac16,3": "iMac (24-inch, M4, 2024)",
            "Mac16,5": "MacBook Pro (16-inch, M4 Max, 2024)",
            "Mac16,6": "MacBook Pro (14-inch, M4 Max, 2024)",
            "Mac16,7": "MacBook Pro (16-inch, M4 Pro, 2024)",
            "Mac16,8": "MacBook Pro (14-inch, M4 Pro, 2024)",
            "Mac16,9": "Mac Studio (M4 Max, 2025)",
            "Mac16,10": "Mac mini (M4, 2024)",
            "Mac16,11": "Mac mini (M4 Pro, 2024)",
            "Mac16,12": "MacBook Air (13-inch, M4, 2025)",
            "Mac16,13": "MacBook Air (15-inch, M4, 2025)",
            "MacBookPro18,3": "MacBook Pro (14-inch, M1 Pro, 2021)",
            "MacBookPro18,4": "MacBook Pro (14-inch, M1 Max, 2021)",
            "MacBookPro18,1": "MacBook Pro (16-inch, M1 Pro, 2021)",
            "MacBookPro18,2": "MacBook Pro (16-inch, M1 Max, 2021)",
            "MacBookAir10,1": "MacBook Air (M1, 2020)",
            "Macmini9,1": "Mac mini (M1, 2020)",
            "iMac21,1": "iMac (24-inch, M1, 2021)",
            "iMac21,2": "iMac (24-inch, M1, 2021)"
        ]
        return models[identifier]
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
                info.append(("volume_name", name))
            }
            if let total = values.volumeTotalCapacity {
                info.append(("total_capacity", formatBytes(Int64(total))))
            }
            if let available = values.volumeAvailableCapacity {
                info.append(("available_capacity", formatBytes(Int64(available))))
            }
            if let format = values.volumeLocalizedFormatDescription {
                info.append(("file_system", format))
            }
            if let removable = values.volumeIsRemovable {
                info.append(("removable", removable ? "true" : "false"))
            }
            if let ejectable = values.volumeIsEjectable {
                info.append(("ejectable", ejectable ? "true" : "false"))
            }
        } catch {
            info.append(("volume_info_error", error.localizedDescription))
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
                    info.append(("device_location", location))
                } else if let mediaName = plist["MediaName"] as? String {
                    info.append(("media_name", mediaName))
                }
                
                if let blockSize = plist["DeviceBlockSize"] as? Int {
                    info.append(("block_size", String(format: "%d Bytes", blockSize)))
                }
                
                if let protocolName = plist["BusProtocol"] as? String {
                    info.append(("bus_protocol", protocolName))
                }
                
                if let uuid = plist["VolumeUUID"] as? String {
                    info.append(("volume_uuid", uuid))
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
            info.append(("diskutil_error", error.localizedDescription))
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
            info.append(("interface_speed", "undetected_or_internal"))
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
                    if let speed = device["device_speed"] as? String { info.append(("device_speed", speed)) }
                    if let busSpeed = device["host_controller_speed"] as? String { info.append(("host_controller_speed", busSpeed)) }
                } else if type == "Thunderbolt" {
                    if let speed = device["link_speed"] as? String { info.append(("link_speed", speed)) }
                    if let width = device["link_width"] as? String { info.append(("link_width", width)) }
                } else if type == "NVMe" {
                    if let width = device["link_width"] as? String { info.append(("link_width", width)) }
                    if let speed = device["link_speed"] as? String { info.append(("link_speed", speed)) }
                }
                
                info.append(("connection_type", type))
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

    nonisolated private func formattedMaxLogSize() -> String {
        isLogSizeUnlimited ? "unlimited" : formatBytes(maxLogSize)
    }

    nonisolated private func timestampString(for date: Date) -> String {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        return timestampFormatter.string(from: date)
    }

    nonisolated private func archiveTimestampString(for date: Date) -> String {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        return archiveNameFormatter.string(from: date)
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
        "AppPorts-Diagnostic-\(archiveTimestampString(for: Date())).zip"
    }

    nonisolated func createDiagnosticArchive(includeAppInventory: Bool) throws -> URL {
        let tempRootURL = fileManager.temporaryDirectory.appendingPathComponent("AppPorts-Diagnostic-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRootURL, withIntermediateDirectories: true)

        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: tempRootURL) } }
        let packageURL = try buildDiagnosticPackage(in: tempRootURL, includeAppInventory: includeAppInventory)
        let archiveURL = tempRootURL.appendingPathComponent("\(packageURL.lastPathComponent).zip")

        do {
            _ = try Self.runDiagnosticCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", packageURL.path, archiveURL.path],
                timeout: 30,
                maximumOutputBytes: 4 * 1024 * 1024
            )
        } catch {
            throw NSError(
                domain: "AppPorts.AppLogger",
                code: 7001,
                userInfo: [
                    NSLocalizedDescriptionKey: "无法压缩诊断包".localized,
                    NSUnderlyingErrorKey: error
                ]
            )
        }

        completed = true
        return archiveURL
    }

    nonisolated func buildDiagnosticPackage(
        in rootURL: URL,
        includeAppInventory: Bool = false,
        guardianSummary: [String]? = nil
    ) throws -> URL {
        let packageURL = rootURL.appendingPathComponent("AppPorts-Diagnostic-\(archiveTimestampString(for: Date()))", isDirectory: true)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let snapshot = writeQueue.sync { () -> (
            mainLogContent: String,
            mainLogTruncated: Bool,
            traceLogContent: String?,
            traceLogTruncated: Bool,
            operationSummaries: [OperationSummaryRecord],
            appInventory: [AppInventoryEntry],
            mainBytes: Int64,
            traceBytes: Int64
        ) in
            let files = logFileSet(for: logFileURL)
            let mainRead = readCombinedLogContent(
                archiveURL: files.mainArchive,
                currentURL: files.mainCurrent,
                maxBytes: Self.maxDiagnosticExportMainLogBytes
            )
            let traceRead = readCombinedLogContent(
                archiveURL: files.traceArchive,
                currentURL: files.traceCurrent,
                maxBytes: Self.maxDiagnosticExportTraceLogBytes
            )
            let summaries = mergedOperationSummaries(for: files)
            let inventory = latestAppInventoryByScope.values
                .flatMap { $0 }
                .sorted { lhs, rhs in
                    if lhs.scope != rhs.scope { return lhs.scope < rhs.scope }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            let mainBytes = fileSizeBytes(at: files.mainCurrent) + fileSizeBytes(at: files.mainArchive)
            let traceBytes = fileSizeBytes(at: files.traceCurrent) + fileSizeBytes(at: files.traceArchive)
            return (
                mainRead?.content ?? "日志文件不存在或暂时不可读取".localized,
                mainRead?.truncated ?? false,
                traceRead?.content,
                traceRead?.truncated ?? false,
                summaries,
                inventory,
                mainBytes,
                traceBytes
            )
        }

        let exportMainContent = includeAppInventory
            ? snapshot.mainLogContent
            : removingAppInventoryEntries(from: snapshot.mainLogContent)
        let redactedMainContent = redactedDiagnosticText(from: exportMainContent)

        let redactedTraceContent: String? = snapshot.traceLogContent.map { rawTrace in
            let filtered = includeAppInventory ? rawTrace : removingAppInventoryEntries(from: rawTrace)
            return redactedDiagnosticText(from: filtered)
        }

        let operationSummaries = snapshot.operationSummaries
        let recentFailures = operationSummaries.filter { ["failed", "rolled_back", "success_with_warning"].contains($0.result) }
        let totalLogBytes = snapshot.mainBytes + snapshot.traceBytes

        let volumeInventory = VolumeStateReporting.diagnosticSection(VolumeStateReporting.lastInventory())
        let updateGuardian = guardianSummary ?? UpdateGuardianReporting.diagnosticSection()
        var metadata: [String: String] = [
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
            "trace_log_file_name": traceLogFileURL.lastPathComponent,
            "log_file_size": totalLogBytes > 0 ? LocalizedByteCountFormatter.string(fromByteCount: totalLogBytes, allowedUnits: [.kb, .mb]) : "0 KB",
            "main_log_size": snapshot.mainBytes > 0 ? LocalizedByteCountFormatter.string(fromByteCount: snapshot.mainBytes, allowedUnits: [.kb, .mb]) : "0 KB",
            "trace_log_size": snapshot.traceBytes > 0 ? LocalizedByteCountFormatter.string(fromByteCount: snapshot.traceBytes, allowedUnits: [.kb, .mb]) : "0 KB",
            "max_log_size": formattedMaxLogSize(),
            "main_log_export_truncated": String(snapshot.mainLogTruncated),
            "trace_log_export_truncated": String(snapshot.traceLogTruncated),
            "redaction_mode": "share_safe",
            "app_inventory_included": String(includeAppInventory),
            "recent_operation_count": String(operationSummaries.count),
            "recent_failure_count": String(recentFailures.count),
            "volume_state_inventory": volumeInventory.joined(separator: "\n"),
            "update_guardian": updateGuardian.joined(separator: "\n")
        ]
        if includeAppInventory {
            metadata["app_inventory_count"] = String(snapshot.appInventory.count)
        }

        try writeJSON(metadata, to: packageURL.appendingPathComponent("diagnostic-summary.json"))
        try writeJSON(operationSummaries, to: packageURL.appendingPathComponent("recent-operations.json"))
        try writeJSON(recentFailures.suffix(20), to: packageURL.appendingPathComponent("recent-failures.json"))

        if includeAppInventory {
            try writeJSON(snapshot.appInventory, to: packageURL.appendingPathComponent("app-inventory.json"))
        }

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
        try redactedMainContent.write(
            to: packageURL.appendingPathComponent("AppPorts_Log.share-safe.txt"),
            atomically: true,
            encoding: .utf8
        )
        if let redactedTraceContent, !redactedTraceContent.isEmpty {
            try redactedTraceContent.write(
                to: packageURL.appendingPathComponent("AppPorts_Trace.share-safe.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        return packageURL
    }

    /// 扫描日志逐条列出已安装应用；诊断包只保留操作记录和扫描汇总。
    /// 同时过滤已有日志，不要求用户清空日志或重新扫描。
    nonisolated private func removingAppInventoryEntries(from rawText: String) -> String {
        let prefix = try? NSRegularExpression(pattern: #"^(?:\[[^\]\r\n]*\][ \t]*)+"#)
        var omittingInventoryEntry = false
        return rawText.components(separatedBy: "\n").filter { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let match = prefix?.firstMatch(in: line, range: range)
            let message: String
            if let match, let prefixRange = Range(match.range, in: line) {
                message = String(line[prefixRange.upperBound...])
                omittingInventoryEntry = false
            } else {
                message = line.trimmingCharacters(in: .whitespaces)
            }
            if message.hasPrefix("扫描应用:") || message.hasPrefix("扫描应用：") || message.hasPrefix("Scanning app:") {
                omittingInventoryEntry = true
            }
            return !omittingInventoryEntry
        }.joined(separator: "\n")
    }

    nonisolated func redactedDiagnosticText(from rawText: String) -> String {
        var sanitized = rawText
        let homeDirectory = NSHomeDirectory()

        if !homeDirectory.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: homeDirectory + "/", with: "~/")
            if sanitized == homeDirectory { sanitized = "~" }
        }

        // 路径组件允许空格；在引号、逗号、分号、尖括号或下一个斜杠处停止，避免同行过度吞字或破坏 XML 标签。
        // 先对字符串值脱敏，再编码 JSON，避免破坏 JSON 转义和类型。
        let volumeLabels = Self.volumeNameLabels.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let redactionRules: [(pattern: String, replacement: String)] = [
            (#"(?i)\b(smb|afp|cifs|nfs)://[^\s"'<>]+"#, "$1://<redacted-share>"),
            (#"(<key>VolumeName</key>\s*<string>)[^<]*(</string>)"#, "$1<redacted-volume>$2"),
            (#"/Users/[^/\r\n"',;<>]+"#, "/Users/<redacted-user>"),
            (#"/Volumes/[^/\r\n"',;<>]+"#, "/Volumes/<redacted-volume>"),
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
        writeQueue.sync {
            let files = logFileSet(for: logFileURL)
            return mergedOperationSummaries(for: files)
        }
    }

    nonisolated private func buildLogLine(message: String, level: String, timestamp: String) -> String {
        "[\(timestamp)] [\(level)] [session:\(sessionID)] [pid:\(processID)] \(message)\n"
    }

    nonisolated private func writeStreamPayload(_ logLines: String, stream: LogStreamKind, timestamp: String) {
        guard let payloadData = logLines.data(using: .utf8) else { return }

        let files = logFileSet(for: logFileURL)
        let currentURL = stream == .main ? files.mainCurrent : files.traceCurrent
        let archiveURL = stream == .main ? files.mainArchive : files.traceArchive
        let unlimited = isLogSizeUnlimited
        let limit = unlimited ? Int64.max : singleVolumeLimitBytes(for: stream)

        if isDirectoryPath(currentURL) {
            reportLogWriteFailure(POSIXError(.EISDIR))
            return
        }

        do {
            try fileManager.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try withFileLock(at: files.lockFile) {
                var dataToWrite = payloadData
                if !unlimited {
                    let currentSize = fileSizeBytes(at: currentURL)
                    if currentSize > 0 && (currentSize >= limit || currentSize + Int64(payloadData.count) > limit) {
                        if Darwin.rename(currentURL.path, archiveURL.path) == 0 {
                            let rotationLine = buildLogLine(
                                message: "日志轮转已执行，上一卷大小: \(formatBytes(currentSize))，单卷阈值: \(formatBytes(limit))",
                                level: stream == .main ? "DIAG" : "TRACE",
                                timestamp: timestamp
                            )
                            if let headerData = rotationLine.data(using: .utf8) {
                                dataToWrite = headerData + payloadData
                            }
                        }
                    }
                }
                try Self.appendPOSIXData(dataToWrite, to: currentURL)
            }
        } catch {
            reportLogWriteFailure(error)
        }
    }

    nonisolated private func appendOperationSummaryRecord(_ record: OperationSummaryRecord) {
        recentOperationSummaries.append(record)
        if recentOperationSummaries.count > maxOperationSummaryCount {
            recentOperationSummaries.removeFirst(recentOperationSummaries.count - maxOperationSummaryCount)
        }

        guard isLoggingEnabled else { return }
        let files = logFileSet(for: logFileURL)
        guard !isDirectoryPath(files.mainCurrent) else { return }

        do {
            try fileManager.createDirectory(at: files.operationSummariesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try withFileLock(at: files.lockFile) {
                let merged = mergeSummaryRecords(
                    persisted: loadPersistedOperationSummaries(at: files.operationSummariesFile),
                    inMemory: [record]
                )
                let encoded = try JSONEncoder().encode(merged)
                try encoded.write(to: files.operationSummariesFile, options: .atomic)
            }
        } catch {
            reportLogWriteFailure(error)
        }
    }

    nonisolated private func mergedOperationSummaries(for files: LogFileSet) -> [OperationSummaryRecord] {
        guard !isDirectoryPath(files.mainCurrent) else {
            return Array(recentOperationSummaries.suffix(maxOperationSummaryCount))
        }
        let persisted: [OperationSummaryRecord] = withFileLock(at: files.lockFile) {
            loadPersistedOperationSummaries(at: files.operationSummariesFile)
        }
        return mergeSummaryRecords(persisted: persisted, inMemory: recentOperationSummaries)
    }

    nonisolated private func loadPersistedOperationSummaries(at url: URL) -> [OperationSummaryRecord] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([OperationSummaryRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    nonisolated private func mergeSummaryRecords(
        persisted: [OperationSummaryRecord],
        inMemory: [OperationSummaryRecord]
    ) -> [OperationSummaryRecord] {
        var result: [OperationSummaryRecord] = []
        var seen = Set<String>()
        for record in persisted + inMemory {
            let key = "\(record.operationID)|\(record.endedAt)|\(record.result)|\(record.sessionID)"
            if seen.insert(key).inserted {
                result.append(record)
            }
        }
        if result.count > maxOperationSummaryCount {
            return Array(result.suffix(maxOperationSummaryCount))
        }
        return result
    }

    nonisolated private func readCombinedLogContent(
        archiveURL: URL,
        currentURL: URL,
        maxBytes: Int64
    ) -> (content: String, truncated: Bool)? {
        guard !isDirectoryPath(currentURL) else { return nil }
        let files = logFileSet(for: logFileURL)
        return withFileLock(at: files.lockFile) {
            let archiveSize = fileSizeBytes(at: archiveURL)
            let currentSize = fileSizeBytes(at: currentURL)
            let totalSize = archiveSize + currentSize
            guard totalSize > 0 else { return nil }

            let truncated = totalSize > maxBytes
            var remainingBudget = min(totalSize, maxBytes)
            var currentText = ""
            var archiveText = ""

            if currentSize > 0 && remainingBudget > 0 {
                let bytesToRead = min(currentSize, remainingBudget)
                currentText = readTailUTF8String(at: currentURL, maxBytes: bytesToRead, snapToLineStart: bytesToRead < currentSize)
                remainingBudget -= bytesToRead
            }
            if archiveSize > 0 && remainingBudget > 0 {
                let bytesToRead = min(archiveSize, remainingBudget)
                archiveText = readTailUTF8String(at: archiveURL, maxBytes: bytesToRead, snapToLineStart: bytesToRead < archiveSize)
            }

            var chunks: [String] = []
            if !archiveText.isEmpty { chunks.append(archiveText) }
            if !currentText.isEmpty { chunks.append(currentText) }
            guard !chunks.isEmpty else { return nil }

            var combined = chunks.joined(separator: chunks.first?.hasSuffix("\n") == true ? "" : "\n")
            if truncated {
                let note = "[DIAG] 诊断包导出副本仅包含最近 \(formatBytes(maxBytes)) 日志（本地完整日志总计 \(formatBytes(totalSize))，未对本地文件作任何删减）。\n"
                combined = note + combined
            }
            return (combined, truncated)
        }
    }

    nonisolated private func readTailUTF8String(at url: URL, maxBytes: Int64, snapToLineStart: Bool) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let fileSize = fileSizeBytes(at: url)
        guard fileSize > 0 else { return "" }
        let offset = max(0, fileSize - maxBytes)
        if offset > 0 {
            try? handle.seek(toOffset: UInt64(offset))
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return "" }
        let effectiveData: Data
        if snapToLineStart, let newlineIndex = data.firstIndex(of: 0x0A), newlineIndex + 1 < data.endIndex {
            effectiveData = data[(newlineIndex + 1)...]
        } else {
            effectiveData = data
        }
        return String(decoding: effectiveData, as: UTF8.self)
    }

    nonisolated private func isDirectoryPath(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    nonisolated private func fileSizeBytes(at url: URL) -> Int64 {
        guard !isDirectoryPath(url),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return 0
        }
        return fileSize
    }

    nonisolated private func withFileLock<T>(at lockURL: URL, body: () throws -> T) rethrows -> T {
        let lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard lockFD >= 0 else {
            return try body()
        }
        defer {
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
        }
        while flock(lockFD, LOCK_EX) != 0 {
            if errno != EINTR { break }
        }
        return try body()
    }

    nonisolated private static func appendPOSIXData(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(fd) }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                remaining -= written
                offset += written
            }
        }
    }

    nonisolated static func appendLogData(_ data: Data, to fileHandle: FileHandle) throws {
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: data)
    }

    nonisolated private func reportLogWriteFailure(_ error: Error) {
        // 不再次调用 log，以免日志磁盘写满或被卸载时递归失败。
        mainOSLogger.warning("[\(self.sessionID, privacy: .public)] 日志文件写入失败: \(error.localizedDescription, privacy: .private)")
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
            details.append(("created_at", timestampString(for: createdAt)))
        }
        if let modifiedAt = values?.contentModificationDate {
            details.append(("modified_at", timestampString(for: modifiedAt)))
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

        if let diagnostic = nsError.userInfo[OperationBlockage.diagnosticFieldsKey] as? [String: String] {
            details += diagnostic.keys.sorted().map { ("\(prefix)_\($0)", diagnostic[$0]) }
        }

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
            "main_log_size: \(metadata["main_log_size"] ?? "unknown")",
            "trace_log_size: \(metadata["trace_log_size"] ?? "unknown")",
            "max_log_size: \(metadata["max_log_size"] ?? "unknown")",
            "redaction_mode: share_safe",
            "app_inventory_included: \(metadata["app_inventory_included"] ?? "false")",
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

        if let inventory = metadata["volume_state_inventory"] { lines.append(inventory) }
        if let guardian = metadata["update_guardian"] { lines.append(guardian) }
        return lines.joined(separator: "\n") + "\n"
    }
}
