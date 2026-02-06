//
//  AppLogger.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation
import AppKit

class AppLogger {
    static let shared = AppLogger()
    
    private let dateFormatter: DateFormatter
    private let fileManager = FileManager.default
    
    // 用户设置键
    private let logPathKey = "LogFilePath"
    private let maxLogSizeKey = "MaxLogSizeBytes"
    
    // 默认最大日志大小: 2MB
    private let defaultMaxSize: Int64 = 2 * 1024 * 1024
    
    /// 当前日志文件路径
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
    var maxLogSize: Int64 {
        get {
            let saved = UserDefaults.standard.integer(forKey: maxLogSizeKey)
            return saved > 0 ? Int64(saved) : defaultMaxSize
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: maxLogSizeKey)
        }
    }
    
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
}
