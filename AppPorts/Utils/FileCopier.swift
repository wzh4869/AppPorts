//
//  FileCopier.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation

// MARK: - 文件复制工具

/// 支持进度回调的异步文件复制工具
///
/// 使用 Swift Actor 模型确保线程安全的文件复制操作。提供实时进度回调，
/// 支持复制大型目录结构，正确处理符号链接、扩展属性（xattr）和文件权限。
///
/// ## 主要特性
/// - ✅ 异步操作，不阻塞主线程
/// - ✅ 实时进度报告（字节级和文件计数）
/// - ✅ 保留文件元数据（权限、扩展属性、创建/修改时间）
/// - ✅ 正确处理符号链接
/// - ✅ 智能进度更新（减少回调频率，提升性能）
///
/// ## 使用示例
/// ```swift
/// let copier = FileCopier()
/// try await copier.copyDirectory(
///     from: sourceURL,
///     to: destinationURL,
///     progressHandler: { progress in
///         print("进度: \(progress.percentage)% - \(progress.currentFile)")
///     }
/// )
/// ```
///
/// - Note: 使用 Actor 确保所有方法在隔离的执行上下文中运行，保证线程安全
actor FileCopier {
    
    // MARK: - 公共类型
    
    /// 文件复制进度信息
    ///
    /// 包含当前复制的字节数、总字节数和正在处理的文件名
    struct Progress: Sendable {
        /// 已复制的字节数
        let copiedBytes: Int64
        
        /// 总字节数（源目录总大小）
        let totalBytes: Int64
        
        /// 当前正在复制的文件名
        let currentFile: String
        
        /// 复制进度百分比（0.0 到 1.0）
        var percentage: Double {
            totalBytes > 0 ? Double(copiedBytes) / Double(totalBytes) : 0
        }
    }
    
    /// 进度回调函数类型
    /// - Parameter progress: 当前复制进度信息
    typealias ProgressHandler = @Sendable (Progress) async -> Void
    
    // MARK: - 私有属性
    
    /// 文件管理器实例
    private let fileManager = FileManager.default
    
    /// 进度更新阈值：每复制 5MB 更新一次进度
    /// - Note: 减少回调频率可以显著提升大文件复制性能
    private let progressUpdateThreshold: Int64 = 5 * 1024 * 1024  // 5 MB
    
    /// 文件计数阈值：每复制 50 个文件更新一次进度
    private let fileCountThreshold: Int = 50
    
    // MARK: - 公共 API
    
    /// 递归复制目录，并通过回调报告进度
    ///
    /// 该方法会：
    /// 1. 计算源目录的总大小（用于进度计算）
    /// 2. 创建目标目录
    /// 3. 递归复制所有文件和子目录
    /// 4. 保留文件权限、扩展属性和时间戳
    /// 5. 定期通过回调报告进度
    ///
    /// - Parameters:
    ///   - source: 源目录 URL（必须是目录）
    ///   - destination: 目标目录 URL（如果不存在会自动创建）
    ///   - progressHandler: 进度回调（可选）。在后台线程调用，可安全更新 UI
    ///
    /// - Throws:
    ///   - 文件系统错误（权限不足、磁盘空间不足等）
    ///   - 源路径不存在或不是目录
    ///
    /// - Note: 此方法在 Actor 上下文中执行，自动序列化所有文件操作
    func copyDirectory(
        from source: URL,
        to destination: URL,
        progressHandler: ProgressHandler?
    ) async throws {
        // 1. 计算源目录总大小（用于进度百分比计算）
        let totalBytes = calculateDirectorySize(at: source)
        
        // 报告初始进度（0%）
        if let handler = progressHandler {
            await handler(Progress(copiedBytes: 0, totalBytes: totalBytes, currentFile: ""))
        }
        
        // 2. 创建目标目录（包括必要的中间目录）
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: nil)
        
        // 3. 递归复制文件内容
        var state = CopyState(totalBytes: totalBytes)
        try await copyContents(
            from: source,
            to: destination,
            state: &state,
            progressHandler: progressHandler
        )
        
        // 4. 报告最终进度（100%）
        if let handler = progressHandler {
            await handler(Progress(copiedBytes: state.copiedBytes, totalBytes: totalBytes, currentFile: ""))
        }
    }
    
    // MARK: - 私有类型
    
    /// 复制状态追踪
    ///
    /// 用于在递归复制过程中跟踪进度和优化回调频率
    private struct CopyState {
        /// 已复制的总字节数
        var copiedBytes: Int64 = 0
        
        /// 上次报告进度时的字节数
        var lastReportedBytes: Int64 = 0
        
        /// 自上次报告以来复制的文件数
        var filesSinceLastReport: Int = 0
        
        /// 源目录的总字节数
        let totalBytes: Int64
    }
    
    // MARK: - 私有辅助方法
    
    /// 计算目录总大小（字节）
    ///
    /// 递归遍历目录树，累加所有常规文件的大小。
    /// 符号链接不计入大小（避免重复计算或无限循环）。
    ///
    /// - Parameter url: 目录 URL
    /// - Returns: 目录总大小（字节）
    ///
    /// - Note: 使用 FileManager.DirectoryEnumerator 进行深度优先遍历
    private func calculateDirectorySize(at url: URL) -> Int64 {
        var size: Int64 = 0
        
        // 需要获取的资源键
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        
        // 创建目录枚举器
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: nil
        ) else { return 0 }
        
        // 遍历所有文件
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            
            // 跳过符号链接（避免重复计算）
            if resourceValues.isSymbolicLink == true {
                continue
            }
            
            // 累加常规文件的大小
            if resourceValues.isRegularFile == true, let fileSize = resourceValues.fileSize {
                size += Int64(fileSize)
            }
        }
        
        return size
    }
    
    /// 复制扩展属性（xattr）
    ///
    /// 扩展属性包含重要的元数据，如：
    /// - 文件标签颜色
    /// - Finder 注释
    /// - 自定义图标
    /// - Spotlight 元数据
    ///
    /// - Parameters:
    ///   - source: 源文件/目录 URL
    ///   - destination: 目标文件/目录 URL
    ///
    /// - Note: 使用 POSIX xattr API（listxattr、getxattr、setxattr）
    private func copyExtendedAttributes(from source: URL, to destination: URL) {
        let sourcePath = source.path
        let destPath = destination.path
        
        // 1. 获取所有扩展属性名的总长度
        let bufferSize = listxattr(sourcePath, nil, 0, 0)
        guard bufferSize > 0 else { return }
        
        // 2. 读取所有属性名（以 null 分隔的字符串列表）
        var nameBuffer = [CChar](repeating: 0, count: bufferSize)
        let result = listxattr(sourcePath, &nameBuffer, bufferSize, 0)
        guard result > 0 else { return }
        
        // 3. 解析属性名并逐个复制
        nameBuffer.withUnsafeBufferPointer { buffer in
            var ptr = buffer.baseAddress!
            let end = ptr.advanced(by: result)
            
            while ptr < end {
                // 读取一个属性名（null 结尾的 C 字符串）
                let name = String(cString: ptr)
                ptr = ptr.advanced(by: name.utf8.count + 1)
                
                // 获取属性值大小
                let valueSize = getxattr(sourcePath, name, nil, 0, 0, 0)
                guard valueSize > 0 else { continue }
                
                // 读取属性值
                var valueBuffer = [UInt8](repeating: 0, count: valueSize)
                let readSize = getxattr(sourcePath, name, &valueBuffer, valueSize, 0, 0)
                guard readSize > 0 else { continue }
                
                // 写入属性值到目标文件
                setxattr(destPath, name, valueBuffer, readSize, 0, 0)
            }
        }
    }
    
    /// 递归复制目录内容
    ///
    /// 深度优先遍历源目录，逐个复制文件和子目录。
    /// 正确处理符号链接、目录和常规文件，保留所有元数据。
    ///
    /// - Parameters:
    ///   - source: 源目录 URL
    ///   - destination: 目标目录 URL
    ///   - state: 复制状态（in-out 参数，用于追踪进度）
    ///   - progressHandler: 进度回调
    ///
    /// - Throws: 文件操作错误
    private func copyContents(
        from source: URL,
        to destination: URL,
        state: inout CopyState,
        progressHandler: ProgressHandler?
    ) async throws {
        // 获取目录内容
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )
        
        // 遍历每个项目
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
            
            // 处理目录（递归复制）
            if resourceValues.isDirectory == true {
                // 获取原目录的属性（权限、时间戳等）
                let sourceAttributes = try fileManager.attributesOfItem(atPath: itemURL.path)
                try fileManager.createDirectory(at: destItemURL, withIntermediateDirectories: false, attributes: sourceAttributes)
                
                // 复制扩展属性（包括 Finder 图标、标签等）
                copyExtendedAttributes(from: itemURL, to: destItemURL)
                
                // 递归复制子目录内容
                try await copyContents(
                    from: itemURL,
                    to: destItemURL,
                    state: &state,
                    progressHandler: progressHandler
                )
                continue
            }
            
            // 处理常规文件
            try fileManager.copyItem(at: itemURL, to: destItemURL)
            
            // 更新进度统计
            if let fileSize = resourceValues.fileSize {
                state.copiedBytes += Int64(fileSize)
                state.filesSinceLastReport += 1
                
                // 只在达到阈值时才回调（减少开销，提升性能）
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
