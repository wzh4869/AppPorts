//
//  FileCopier.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation

/// 带进度回调的文件复制工具
actor FileCopier {
    
    /// 复制进度信息
    struct Progress: Sendable {
        let copiedBytes: Int64
        let totalBytes: Int64
        let currentFile: String
        
        var percentage: Double {
            totalBytes > 0 ? Double(copiedBytes) / Double(totalBytes) : 0
        }
    }
    
    typealias ProgressHandler = @Sendable (Progress) async -> Void
    
    private let fileManager = FileManager.default
    
    // 进度更新阈值：每复制 5MB 或 50 个文件更新一次进度
    private let progressUpdateThreshold: Int64 = 5 * 1024 * 1024  // 5 MB
    private let fileCountThreshold: Int = 50
    
    // MARK: - Public API
    
    /// 递归复制目录，并通过回调报告进度
    /// - Parameters:
    ///   - source: 源目录 URL
    ///   - destination: 目标目录 URL
    ///   - progressHandler: 进度回调（可选）
    func copyDirectory(
        from source: URL,
        to destination: URL,
        progressHandler: ProgressHandler?
    ) async throws {
        // 1. 计算源目录总大小
        let totalBytes = calculateDirectorySize(at: source)
        
        // 报告初始进度
        if let handler = progressHandler {
            await handler(Progress(copiedBytes: 0, totalBytes: totalBytes, currentFile: ""))
        }
        
        // 2. 创建目标目录
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: nil)
        
        // 3. 递归复制文件
        var state = CopyState(totalBytes: totalBytes)
        try await copyContents(
            from: source,
            to: destination,
            state: &state,
            progressHandler: progressHandler
        )
        
        // 4. 报告最终进度
        if let handler = progressHandler {
            await handler(Progress(copiedBytes: state.copiedBytes, totalBytes: totalBytes, currentFile: ""))
        }
    }
    
    // MARK: - Private Types
    
    private struct CopyState {
        var copiedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        var filesSinceLastReport: Int = 0
        let totalBytes: Int64
    }
    
    // MARK: - Private Helpers
    
    /// 计算目录总大小（字节）
    private func calculateDirectorySize(at url: URL) -> Int64 {
        var size: Int64 = 0
        
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: nil
        ) else { return 0 }
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            
            if resourceValues.isSymbolicLink == true {
                continue
            }
            
            if resourceValues.isRegularFile == true, let fileSize = resourceValues.fileSize {
                size += Int64(fileSize)
            }
        }
        
        return size
    }
    
    /// 复制扩展属性 (xattr) - 包括图标、标签等元数据
    private func copyExtendedAttributes(from source: URL, to destination: URL) {
        let sourcePath = source.path
        let destPath = destination.path
        
        // 获取所有扩展属性名
        let bufferSize = listxattr(sourcePath, nil, 0, 0)
        guard bufferSize > 0 else { return }
        
        var nameBuffer = [CChar](repeating: 0, count: bufferSize)
        let result = listxattr(sourcePath, &nameBuffer, bufferSize, 0)
        guard result > 0 else { return }
        
        // 解析属性名并逐个复制
        nameBuffer.withUnsafeBufferPointer { buffer in
            var ptr = buffer.baseAddress!
            let end = ptr.advanced(by: result)
            
            while ptr < end {
                let name = String(cString: ptr)
                ptr = ptr.advanced(by: name.utf8.count + 1)
                
                // 获取属性值大小
                let valueSize = getxattr(sourcePath, name, nil, 0, 0, 0)
                guard valueSize > 0 else { continue }
                
                // 读取属性值
                var valueBuffer = [UInt8](repeating: 0, count: valueSize)
                let readSize = getxattr(sourcePath, name, &valueBuffer, valueSize, 0, 0)
                guard readSize > 0 else { continue }
                
                // 写入属性值到目标
                setxattr(destPath, name, valueBuffer, readSize, 0, 0)
            }
        }
    }
    
    /// 递归复制目录内容
    private func copyContents(
        from source: URL,
        to destination: URL,
        state: inout CopyState,
        progressHandler: ProgressHandler?
    ) async throws {
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )
        
        for itemURL in contents {
            let itemName = itemURL.lastPathComponent
            let destItemURL = destination.appendingPathComponent(itemName)
            
            let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            
            // 处理符号链接
            if resourceValues.isSymbolicLink == true {
                let linkDest = try fileManager.destinationOfSymbolicLink(atPath: itemURL.path)
                try fileManager.createSymbolicLink(atPath: destItemURL.path, withDestinationPath: linkDest)
                continue
            }
            
            // 处理目录
            if resourceValues.isDirectory == true {
                // 获取原目录的属性
                let sourceAttributes = try fileManager.attributesOfItem(atPath: itemURL.path)
                try fileManager.createDirectory(at: destItemURL, withIntermediateDirectories: false, attributes: sourceAttributes)
                
                // 复制扩展属性 (xattr) - 重要：包含图标等元数据
                copyExtendedAttributes(from: itemURL, to: destItemURL)
                
                try await copyContents(
                    from: itemURL,
                    to: destItemURL,
                    state: &state,
                    progressHandler: progressHandler
                )
                continue
            }
            
            // 处理普通文件
            try fileManager.copyItem(at: itemURL, to: destItemURL)
            
            // 更新进度统计
            if let fileSize = resourceValues.fileSize {
                state.copiedBytes += Int64(fileSize)
                state.filesSinceLastReport += 1
                
                // 只在达到阈值时才回调（减少开销）
                let bytesDelta = state.copiedBytes - state.lastReportedBytes
                if bytesDelta >= progressUpdateThreshold || state.filesSinceLastReport >= fileCountThreshold {
                    if let handler = progressHandler {
                        let progress = Progress(
                            copiedBytes: state.copiedBytes,
                            totalBytes: state.totalBytes,
                            currentFile: itemName
                        )
                        await handler(progress)
                    }
                    state.lastReportedBytes = state.copiedBytes
                    state.filesSinceLastReport = 0
                }
            }
        }
    }
}
