//
//  DataDirMover.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/3/4.
//

import Foundation

// MARK: - 数据目录迁移器

/// 负责数据目录的迁移、还原和链接操作
///
/// 使用 Actor 模型确保所有文件操作线程安全。
/// 与应用本体迁移不同，数据目录使用**整体符号链接**策略：
/// 原路径整体变为符号链接，指向外部存储中的目录。
///
/// ## 操作流程
/// - **迁移**：复制 → 删除原目录 → 创建符号链接
/// - **还原**：复制回来 → 删除外部目录 → 删除符号链接
/// - **仅链接**：直接在原路径创建符号链接（适用于已手动迁移的情况）
actor DataDirMover {

    private let fileManager = FileManager.default
    private let homeDir = URL(fileURLWithPath: NSHomeDirectory())
    private let managedLinkMarkerFileName = ".appports-link-metadata.plist"
    private let managedLinkMetadataSidecarSuffix = ".appports-link-metadata.plist"
    private let managedLinkIdentifier = "com.shimoko.AppPorts"
    private let managedLinkSchemaVersion = 1

    private struct ManagedLinkMetadata: Codable, Sendable {
        let schemaVersion: Int
        let managedBy: String
        let sourcePath: String
        let destinationPath: String
        let dataDirType: String
    }

    // MARK: - 迁移

    /// 将数据目录迁移到外部存储
    ///
    /// 执行步骤：
    /// 1. 权限检查（确认能写入目标路径的父目录）
    /// 2. 检测目标冲突
    /// 3. 使用 FileCopier 复制（带进度回调）
    /// 4. 删除原目录
    /// 5. 在原路径创建指向外部的符号链接
    ///
    /// - Parameters:
    ///   - item: 要迁移的数据目录项
    ///   - externalBaseURL: 外部存储的根目录（在其下创建同名子目录）
    ///   - progressHandler: 进度回调
    ///
    /// - Throws: 文件系统错误、权限错误
    func migrate(
        item: DataDirItem,
        to externalBaseURL: URL,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws {
        let sourcePath = item.path
        let destPath = externalBaseURL.appendingPathComponent(sourcePath.lastPathComponent)

        AppLogger.shared.log("===== 开始迁移数据目录 =====")
        AppLogger.shared.log("目录名称: \(item.name)")
        AppLogger.shared.log("源路径: \(sourcePath.path)")
        AppLogger.shared.log("目标路径: \(destPath.path)")

        // 1. 确保目标父目录可写
        try checkWritePermission(at: externalBaseURL)

        // 2. 冲突检测
        if fileManager.fileExists(atPath: destPath.path) {
            let values = try? destPath.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true {
                // 已有符号链接 → 删除后继续
                try fileManager.removeItem(at: destPath)
                AppLogger.shared.log("已删除目标位置旧符号链接")
            } else {
                // 真实目录/文件 → 拒绝
                AppLogger.shared.logError("目标路径已存在真实目录，无法覆盖")
                throw DataDirError.destinationExists(destPath)
            }
        }

        // 3. 复制到外部存储（带进度）
        AppLogger.shared.log("步骤1: 开始复制数据目录...")
        let copier = FileCopier()
        try await copier.copyDirectory(from: sourcePath, to: destPath, progressHandler: progressHandler)
        AppLogger.shared.log("步骤1: 复制完成")

        // 3.5 写入 AppPorts 管理标记，用于后续精准识别受管链接
        do {
            try writeManagedLinkMetadata(sourcePath: sourcePath, destinationPath: destPath, type: item.type)
            AppLogger.shared.log("步骤1.5: 已写入 AppPorts 链接标记")
        } catch {
            AppLogger.shared.logError("步骤1.5: 写入 AppPorts 链接标记失败，执行回滚", error: error)
            try? removeManagedLinkMetadata(in: destPath)
            try? fileManager.removeItem(at: destPath)
            throw DataDirError.metadataWriteFailed(error)
        }

        // 4. 删除原目录（先尝试普通删除）
        AppLogger.shared.log("步骤2: 删除原目录...")
        do {
            try fileManager.removeItem(at: sourcePath)
            AppLogger.shared.log("步骤2: 删除成功")
        } catch {
            // 回滚：删除外部已复制的目录
            AppLogger.shared.logError("步骤2: 删除失败，执行回滚", error: error)
            try? removeManagedLinkMetadata(in: destPath)
            try? fileManager.removeItem(at: destPath)
            AppLogger.shared.log("回滚：已删除外部副本")
            throw DataDirError.deletionFailed(error)
        }

        // 5. 在原路径创建符号链接
        AppLogger.shared.log("步骤3: 创建符号链接...")
        do {
            try fileManager.createSymbolicLink(at: sourcePath, withDestinationURL: destPath)
            AppLogger.shared.log("步骤3: 符号链接创建成功: \(sourcePath.path) → \(destPath.path)")
        } catch {
            // 符号链接创建失败是严重错误：数据已在外部，但原路径为空
            // 尝试把数据复制回来作为应急回滚
            AppLogger.shared.logError("步骤3: 符号链接创建失败，紧急回滚", error: error)
            let emergencyCopier = FileCopier()
            try? await emergencyCopier.copyDirectory(from: destPath, to: sourcePath, progressHandler: nil)
            try? removeManagedLinkMetadata(in: sourcePath)
            try? removeManagedLinkMetadata(in: destPath)
            try? fileManager.removeItem(at: destPath)
            AppLogger.shared.log("紧急回滚完成：数据已恢复到本地")
            throw DataDirError.symlinkFailed(error)
        }

        AppLogger.shared.log("===== 数据目录迁移完成 =====")
    }

    // MARK: - 还原

    /// 将已迁移的数据目录还原到本地
    ///
    /// 执行步骤：
    /// 1. 确认当前路径是符号链接
    /// 2. 获取外部路径（链接目标）
    /// 3. 复制外部目录回本地
    /// 4. 删除本地符号链接
    /// 5. 删除外部目录
    ///
    /// - Parameters:
    ///   - item: 要还原的数据目录项（status 应为 "已链接"）
    ///   - progressHandler: 进度回调
    ///
    /// - Throws: 文件系统错误
    func restore(
        item: DataDirItem,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws {
        let localPath = item.path

        AppLogger.shared.log("===== 开始还原数据目录 =====")
        AppLogger.shared.log("目录名称: \(item.name)")
        AppLogger.shared.log("本地路径: \(localPath.path)")

        // 确认是符号链接
        guard let values = try? localPath.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true else {
            throw DataDirError.notASymlink(localPath)
        }

        // 获取外部路径
        guard let externalPathStr = try? fileManager.destinationOfSymbolicLink(atPath: localPath.path) else {
            throw DataDirError.invalidSymlink(localPath)
        }
        let externalPath = URL(fileURLWithPath: externalPathStr)
        AppLogger.shared.log("外部路径: \(externalPath.path)")

        // 确认外部目录存在
        guard fileManager.fileExists(atPath: externalPath.path) else {
            throw DataDirError.externalNotFound(externalPath)
        }

        // 1. 先删除本地符号链接（腾出原路径）
        AppLogger.shared.log("步骤1: 删除本地符号链接...")
        try fileManager.removeItem(at: localPath)
        AppLogger.shared.log("步骤1: 完成")

        // 2. 复制外部目录回本地
        AppLogger.shared.log("步骤2: 复制数据回本地...")
        do {
            let copier = FileCopier()
            try await copier.copyDirectory(from: externalPath, to: localPath, progressHandler: progressHandler)
            try? removeManagedLinkMetadata(in: localPath)
            AppLogger.shared.log("步骤2: 复制完成")
        } catch {
            // 复制失败：尝试把符号链接恢复
            AppLogger.shared.logError("步骤2: 复制失败，尝试恢复符号链接", error: error)
            try? fileManager.createSymbolicLink(at: localPath, withDestinationURL: externalPath)
            throw DataDirError.copyFailed(error)
        }

        // 3. 删除外部目录
        AppLogger.shared.log("步骤3: 删除外部目录...")
        do {
            try? removeManagedLinkMetadata(in: externalPath)
            try fileManager.removeItem(at: externalPath)
            AppLogger.shared.log("步骤3: 完成")
        } catch {
            // 删除外部失败不回滚（本地数据已安全），只记录警告
            AppLogger.shared.logError("步骤3: 删除外部目录失败（本地还原已完成，可手动清理）", error: error)
        }

        AppLogger.shared.log("===== 数据目录还原完成 =====")
    }

    // MARK: - 仅创建链接

    /// 为已手动迁移的目录创建符号链接
    ///
    /// 适用场景：用户已手动将目录移至外部存储，需要 AppPorts 补建符号链接。
    ///
    /// - Parameters:
    ///   - localPath: 本地原路径（用于创建符号链接）
    ///   - externalPath: 外部存储中已存在的真实目录路径
    ///
    /// - Throws: 文件系统错误
    func createLink(localPath: URL, externalPath: URL) throws {
        AppLogger.shared.log("创建符号链接: \(localPath.path) → \(externalPath.path)")

        // 确认外部目录存在
        guard fileManager.fileExists(atPath: externalPath.path) else {
            throw DataDirError.externalNotFound(externalPath)
        }

        let parentURL = localPath.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        // 如果本地路径已存在符号链接，先删除
        if let values = try? localPath.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            try fileManager.removeItem(at: localPath)
        }

        // 确认本地路径不存在真实内容
        if fileManager.fileExists(atPath: localPath.path) {
            throw DataDirError.destinationExists(localPath)
        }

        if let inferredType = inferType(for: localPath) {
            do {
                try writeManagedLinkMetadata(sourcePath: localPath, destinationPath: externalPath, type: inferredType)
            } catch {
                throw DataDirError.metadataWriteFailed(error)
            }
        }

        do {
            try fileManager.createSymbolicLink(at: localPath, withDestinationURL: externalPath)
            AppLogger.shared.log("符号链接创建成功")
        } catch {
            try? removeManagedLinkMetadata(in: externalPath)
            throw DataDirError.symlinkFailed(error)
        }
    }

    /// 将现有软链接纳入 AppPorts 管理，并在需要时迁移到规范路径。
    ///
    /// 如果当前外部路径与规范路径不同，会先移动外部目录/文件，再重建本地软链接。
    func normalizeManagedLink(
        localPath: URL,
        currentExternalPath: URL,
        normalizedExternalPath: URL
    ) throws {
        let standardizedCurrent = currentExternalPath.standardizedFileURL
        let standardizedNormalized = normalizedExternalPath.standardizedFileURL

        AppLogger.shared.log("开始规范化管理: \(localPath.path)")
        AppLogger.shared.log("当前外部路径: \(standardizedCurrent.path)")
        AppLogger.shared.log("规范目标路径: \(standardizedNormalized.path)")

        guard fileManager.fileExists(atPath: standardizedCurrent.path) else {
            throw DataDirError.externalNotFound(standardizedCurrent)
        }

        if standardizedCurrent == standardizedNormalized {
            try createLink(localPath: localPath, externalPath: standardizedCurrent)
            return
        }

        let normalizedParent = standardizedNormalized.deletingLastPathComponent()
        try checkWritePermission(at: normalizedParent)

        if fileManager.fileExists(atPath: standardizedNormalized.path) {
            throw DataDirError.destinationExists(standardizedNormalized)
        }

        do {
            try fileManager.moveItem(at: standardizedCurrent, to: standardizedNormalized)
            AppLogger.shared.log("规范化管理: 已移动外部数据到规范路径")
        } catch {
            AppLogger.shared.logError("规范化管理: 移动外部数据失败", error: error)
            throw DataDirError.copyFailed(error)
        }

        do {
            try createLink(localPath: localPath, externalPath: standardizedNormalized)
            AppLogger.shared.log("规范化管理: 已重建本地软链接")
        } catch {
            AppLogger.shared.logError("规范化管理: 重建本地软链接失败，尝试回滚外部路径", error: error)

            if !fileManager.fileExists(atPath: standardizedCurrent.path),
               fileManager.fileExists(atPath: standardizedNormalized.path) {
                try? fileManager.moveItem(at: standardizedNormalized, to: standardizedCurrent)
            }

            try? createLink(localPath: localPath, externalPath: standardizedCurrent)
            throw error
        }
    }

    // MARK: - 私有辅助

    /// 检查目录的写入权限
    private func checkWritePermission(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            // 如果目录不存在，尝试创建
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return
        }
        guard fileManager.isWritableFile(atPath: url.path) else {
            throw DataDirError.permissionDenied(url)
        }
    }

    private func writeManagedLinkMetadata(sourcePath: URL, destinationPath: URL, type: DataDirType) throws {
        let metadata = ManagedLinkMetadata(
            schemaVersion: managedLinkSchemaVersion,
            managedBy: managedLinkIdentifier,
            sourcePath: sourcePath.standardizedFileURL.path,
            destinationPath: destinationPath.standardizedFileURL.path,
            dataDirType: type.rawValue
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        let markerURL = markerURL(for: destinationPath)
        let data = try encoder.encode(metadata)
        try data.write(to: markerURL, options: .atomic)
    }

    private func removeManagedLinkMetadata(in directoryURL: URL) throws {
        let markerURL = markerURL(for: directoryURL)
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        try fileManager.removeItem(at: markerURL)
    }

    private func markerURL(for directoryURL: URL) -> URL {
        let standardizedURL = directoryURL.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])

        if values?.isDirectory == true {
            return standardizedURL.appendingPathComponent(managedLinkMarkerFileName)
        }

        return standardizedURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(standardizedURL.lastPathComponent)\(managedLinkMetadataSidecarSuffix)")
    }

    private func inferType(for localPath: URL) -> DataDirType? {
        let path = localPath.standardizedFileURL.path
        let libraryRoot = homeDir.appendingPathComponent("Library")

        let mappings: [(URL, DataDirType)] = [
            (libraryRoot.appendingPathComponent("Application Support"), .applicationSupport),
            (libraryRoot.appendingPathComponent("Preferences"), .preferences),
            (libraryRoot.appendingPathComponent("Containers"), .containers),
            (libraryRoot.appendingPathComponent("Group Containers"), .groupContainers),
            (libraryRoot.appendingPathComponent("Application Scripts"), .applicationScripts),
            (libraryRoot.appendingPathComponent("Caches"), .caches),
            (libraryRoot.appendingPathComponent("WebKit"), .webKit),
            (libraryRoot.appendingPathComponent("HTTPStorages"), .httpStorages),
            (libraryRoot.appendingPathComponent("Logs"), .logs),
            (libraryRoot.appendingPathComponent("Saved Application State"), .savedState)
        ]

        for (baseURL, type) in mappings where path.hasPrefix(baseURL.standardizedFileURL.path + "/") {
            return type
        }

        if path.hasPrefix(homeDir.standardizedFileURL.path + "/.") {
            return .dotFolder
        }

        return .custom
    }
}

// MARK: - 错误类型

/// 数据目录迁移操作中的错误类型
enum DataDirError: LocalizedError {
    case permissionDenied(URL)
    case destinationExists(URL)
    case deletionFailed(Error)
    case symlinkFailed(Error)
    case copyFailed(Error)
    case metadataWriteFailed(Error)
    case notASymlink(URL)
    case invalidSymlink(URL)
    case externalNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let url):
            return "没有写入权限：\(url.path)"
        case .destinationExists(let url):
            return "目标路径已存在真实目录，无法覆盖：\(url.lastPathComponent)"
        case .deletionFailed(let error):
            return "删除原目录失败：\(error.localizedDescription)"
        case .symlinkFailed(let error):
            return "创建符号链接失败，数据已紧急还原：\(error.localizedDescription)"
        case .copyFailed(let error):
            return "复制失败：\(error.localizedDescription)"
        case .metadataWriteFailed(let error):
            return "写入 AppPorts 链接标记失败：\(error.localizedDescription)"
        case .notASymlink(let url):
            return "该目录不是符号链接，无法还原：\(url.lastPathComponent)"
        case .invalidSymlink(let url):
            return "无法读取符号链接目标：\(url.lastPathComponent)"
        case .externalNotFound(let url):
            return "外部存储目录不存在：\(url.path)"
        }
    }
}
