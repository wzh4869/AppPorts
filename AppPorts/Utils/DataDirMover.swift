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
/// - **迁移**：复制 → 将原目录改名为安全备份 → 创建符号链接 → 清理备份
/// - **还原**：复制回来 → 删除外部目录 → 删除符号链接
/// - **仅链接**：直接在原路径创建符号链接（适用于已手动迁移的情况）
actor DataDirMover {

    private let fileManager = FileManager.default
    private let homeDir: URL
    private let failSymlinkCreation: Bool
    private let failSourceBackupCleanup: Bool
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

    init(
        homeDir: URL = URL(fileURLWithPath: NSHomeDirectory()),
        failSymlinkCreation: Bool = false,
        failSourceBackupCleanup: Bool = false
    ) {
        self.homeDir = homeDir.standardizedFileURL
        self.failSymlinkCreation = failSymlinkCreation
        self.failSourceBackupCleanup = failSourceBackupCleanup
    }

    // MARK: - 迁移

    /// 将数据目录迁移到外部存储
    ///
    /// 执行步骤：
    /// 1. 权限检查（确认能写入目标路径的父目录）
    /// 2. 检测目标冲突
    /// 3. 使用 FileCopier 复制（带进度回调）
    /// 4. 将原目录改名为本地安全备份
    /// 5. 在原路径创建指向外部的符号链接
    /// 6. 清理本地安全备份
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
        let operationID = AppLogger.shared.makeOperationID(prefix: "data-migrate")
        let startedAt = Date()
        var operationResult = "failed"
        var operationErrorCode: String?

        defer {
            AppLogger.shared.logOperationSummary(
                category: "data_migrate",
                operationID: operationID,
                result: operationResult,
                startedAt: startedAt,
                errorCode: operationErrorCode,
                details: [
                    ("item_name", item.name),
                    ("type", item.type.rawValue),
                    ("source_path", sourcePath.path),
                    ("destination_path", destPath.path)
                ]
            )
        }

        AppLogger.shared.log("===== 开始迁移数据目录 =====")
        AppLogger.shared.logContext(
            "数据目录迁移上下文",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("type", item.type.rawValue),
                ("priority", item.priority.rawValue),
                ("status", item.status),
                ("source_path", sourcePath.path),
                ("destination_path", destPath.path)
            ]
        )
        AppLogger.shared.logPathState("数据目录迁移前-本地源[\(operationID)]", url: sourcePath)
        AppLogger.shared.logPathState("数据目录迁移前-外部目标[\(operationID)]", url: destPath)

        // 检查是否为 macOS 受保护路径（如 ~/Library/Containers/）
        // 这些目录不允许第三方应用创建新条目，迁移会导致数据丢失
        if isProtectedContainersPath(sourcePath) || isProtectedGroupContainerRootPath(sourcePath) {
            AppLogger.shared.logError(
                "无法迁移受 macOS 保护的顶层容器目录",
                errorCode: "DATA-MIGRATE-PROTECTED-PATH",
                context: [("path", sourcePath.path), ("item_name", item.name)],
                relatedURLs: [("source", sourcePath)]
            )
            operationErrorCode = "DATA-MIGRATE-PROTECTED-PATH"
            throw DataDirError.protectedPath(sourcePath)
        }

        // 1. 确保目标父目录可写
        do {
            try checkWritePermission(at: externalBaseURL)
        } catch {
            operationErrorCode = "DATA-MIGRATE-PERMISSION-DENIED"
            throw error
        }

        // 2. 冲突检测
        if fileManager.fileExists(atPath: destPath.path) {
            if isSymbolicLink(at: destPath) {
                // 已有符号链接 → 删除后继续
                try fileManager.removeItem(at: destPath)
                AppLogger.shared.log("已删除目标位置旧符号链接")
            } else if isSymbolicLink(at: sourcePath) {
                // 源已是符号链接，说明之前已迁移成功，属于状态不一致
                operationErrorCode = "DATA-MIGRATE-ALREADY-MIGRATED"
                throw DataDirError.destinationExists(destPath)
            } else {
                // 源是真实目录 + 目标也是真实目录：只有严格匹配的 AppPorts metadata 才能自动恢复。
                AppLogger.shared.log("目标已存在真实目录，检查 AppPorts 管理标记是否严格匹配...", level: "WARN")

                if hasMatchingManagedLinkMetadata(at: destPath, sourcePath: sourcePath, destinationPath: destPath, type: item.type) {
                    AppLogger.shared.log("目标目录包含匹配的 AppPorts 链接标记，视为上次迁移完成但未清理源，自动恢复...", level: "WARN")
                    do {
                        try writeManagedLinkMetadata(sourcePath: sourcePath, destinationPath: destPath, type: item.type)
                    } catch {
                        AppLogger.shared.logError(
                            "标记恢复模式：写入 AppPorts 链接标记失败",
                            error: error,
                            errorCode: "DATA-MIGRATE-RECOVERY-METADATA-WRITE-FAILED",
                            context: [("operation_id", operationID)],
                            relatedURLs: [("source", sourcePath), ("destination", destPath)]
                        )
                        operationErrorCode = "DATA-MIGRATE-RECOVERY-METADATA-WRITE-FAILED"
                        throw DataDirError.metadataWriteFailed(error)
                    }
                    let sourceBackupPath: URL
                    do {
                        sourceBackupPath = try moveSourceToMigrationBackup(sourcePath, operationID: operationID)
                    } catch {
                        AppLogger.shared.logError(
                            "标记恢复模式：移动源目录到安全备份失败，保留外部副本",
                            error: error,
                            errorCode: "DATA-MIGRATE-RECOVERY-BACKUP-MOVE-FAILED",
                            context: [("operation_id", operationID)],
                            relatedURLs: [("source", sourcePath), ("destination", destPath)]
                        )
                        operationErrorCode = "DATA-MIGRATE-RECOVERY-BACKUP-MOVE-FAILED"
                        throw DataDirError.deletionFailed(error)
                    }
                    do {
                        try createSymbolicLink(at: sourcePath, withDestinationURL: destPath)
                        AppLogger.shared.log("标记恢复模式：符号链接创建成功")
                        AppLogger.shared.logPathState("标记恢复完成-本地链接[\(operationID)]", url: sourcePath)
                        AppLogger.shared.logPathState("标记恢复完成-外部目标[\(operationID)]", url: destPath)
                    } catch {
                        AppLogger.shared.logError(
                            "标记恢复模式：创建符号链接失败，恢复本地安全备份，保留外部副本",
                            error: error,
                            errorCode: "DATA-MIGRATE-RECOVERY-LINK-FAILED",
                            context: [("operation_id", operationID)],
                            relatedURLs: [("source", sourcePath), ("destination", destPath), ("backup", sourceBackupPath)]
                        )
                        restoreMigrationBackup(sourceBackupPath, to: sourcePath, operationID: operationID)
                        try? removeManagedLinkMetadata(in: sourcePath)
                        operationErrorCode = "DATA-MIGRATE-RECOVERY-LINK-FAILED"
                        throw DataDirError.symlinkFailed(error)
                    }
                    do {
                        try cleanupMigrationBackup(sourceBackupPath, operationID: operationID)
                        operationResult = "success"
                    } catch {
                        AppLogger.shared.logError(
                            "标记恢复模式：迁移已完成，但本地安全备份清理失败，外部副本保持不变",
                            error: error,
                            errorCode: "DATA-MIGRATE-RECOVERY-BACKUP-CLEANUP-FAILED",
                            context: [("operation_id", operationID)],
                            relatedURLs: [("backup", sourceBackupPath), ("destination", destPath)]
                        )
                        operationResult = "success_with_warning"
                        operationErrorCode = "DATA-MIGRATE-RECOVERY-BACKUP-CLEANUP-FAILED"
                    }
                    return
                }

                AppLogger.shared.logError(
                    "目标位置存在真实目录且没有匹配的 AppPorts 管理标记，拒绝自动覆盖",
                    errorCode: "DATA-MIGRATE-DESTINATION-CONFLICT",
                    context: [("operation_id", operationID), ("destination_path", destPath.path)],
                    relatedURLs: [("source", sourcePath), ("destination", destPath)]
                )
                operationErrorCode = "DATA-MIGRATE-DESTINATION-CONFLICT"
                throw DataDirError.destinationExists(destPath)
            }
        }

        // 3. 复制到外部存储（带进度）
        AppLogger.shared.log("步骤1: 开始复制数据目录...")
        let copier = FileCopier()
        let totalBytes = fastDirectorySize(at: sourcePath, fileManager: fileManager)
        do {
            try await copier.copyDirectory(from: sourcePath, to: destPath, progressHandler: progressHandler)
            AppLogger.shared.log("步骤1: 复制完成")
            AppLogger.shared.logPathState("数据目录步骤1后-外部副本[\(operationID)]", url: destPath)
        } catch {
            AppLogger.shared.logError(
                "步骤1: 复制失败，清理外部半成品目录",
                error: error,
                errorCode: "DATA-MIGRATE-COPY-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("source", sourcePath), ("destination_root", externalBaseURL), ("destination", destPath)]
            )
            cleanupFailedMigrationDestination(at: destPath, within: externalBaseURL, operationID: operationID)
            operationErrorCode = "DATA-MIGRATE-COPY-FAILED"
            throw DataDirError.copyFailed(error)
        }

        // 3.5 写入 AppPorts 管理标记，用于后续精准识别受管链接
        await progressHandler?(FileCopier.Progress(copiedBytes: totalBytes, totalBytes: totalBytes, currentFile: "正在写入管理标记...".localized))
        do {
            try writeManagedLinkMetadata(sourcePath: sourcePath, destinationPath: destPath, type: item.type)
            AppLogger.shared.log("步骤1.5: 已写入 AppPorts 链接标记")
        } catch {
            AppLogger.shared.logError(
                "步骤1.5: 写入 AppPorts 链接标记失败，执行回滚",
                error: error,
                errorCode: "DATA-MIGRATE-METADATA-WRITE-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("source", sourcePath), ("destination", destPath)]
            )
            cleanupFailedMigrationDestination(at: destPath, within: externalBaseURL, operationID: operationID)
            operationErrorCode = "DATA-MIGRATE-METADATA-WRITE-FAILED"
            throw DataDirError.metadataWriteFailed(error)
        }

        // 4. 将原目录改名为同卷安全备份，避免递归删除失败造成源和目标双丢失
        AppLogger.shared.log("步骤2: 将原目录移动到本地安全备份...")
        await progressHandler?(FileCopier.Progress(copiedBytes: totalBytes, totalBytes: totalBytes, currentFile: "正在切换本地入口...".localized))
        let sourceBackupPath: URL
        do {
            sourceBackupPath = try moveSourceToMigrationBackup(sourcePath, operationID: operationID)
            AppLogger.shared.log("步骤2: 原目录已移动到本地安全备份")
            AppLogger.shared.logPathState("数据目录步骤2后-本地源[\(operationID)]", url: sourcePath)
            AppLogger.shared.logPathState("数据目录步骤2后-本地安全备份[\(operationID)]", url: sourceBackupPath)
        } catch {
            AppLogger.shared.logError(
                "步骤2: 移动原目录到本地安全备份失败，保留外部副本",
                error: error,
                errorCode: "DATA-MIGRATE-SOURCE-BACKUP-MOVE-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("source", sourcePath), ("destination", destPath)]
            )
            operationErrorCode = "DATA-MIGRATE-SOURCE-BACKUP-MOVE-FAILED"
            throw DataDirError.deletionFailed(error)
        }

        // 5. 在原路径创建符号链接
        AppLogger.shared.log("步骤3: 创建符号链接...")
        await progressHandler?(FileCopier.Progress(copiedBytes: totalBytes, totalBytes: totalBytes, currentFile: "正在创建符号链接...".localized))
        do {
            try createSymbolicLink(at: sourcePath, withDestinationURL: destPath)
            AppLogger.shared.log("步骤3: 符号链接创建成功: \(sourcePath.path) → \(destPath.path)")
            AppLogger.shared.logPathState("数据目录步骤3后-本地入口[\(operationID)]", url: sourcePath)
        } catch {
            AppLogger.shared.logError(
                "步骤3: 符号链接创建失败，恢复本地安全备份，保留外部副本",
                error: error,
                errorCode: "DATA-MIGRATE-SYMLINK-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("source", sourcePath), ("destination", destPath), ("backup", sourceBackupPath)]
            )
            restoreMigrationBackup(sourceBackupPath, to: sourcePath, operationID: operationID)
            try? removeManagedLinkMetadata(in: sourcePath)
            operationErrorCode = "DATA-MIGRATE-SYMLINK-FAILED"
            throw DataDirError.symlinkFailed(error)
        }

        do {
            try cleanupMigrationBackup(sourceBackupPath, operationID: operationID)
        } catch {
            AppLogger.shared.logError(
                "迁移已完成，但本地安全备份清理失败，外部副本保持不变",
                error: error,
                errorCode: "DATA-MIGRATE-BACKUP-CLEANUP-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("backup", sourceBackupPath), ("destination", destPath)]
            )
            operationResult = "success_with_warning"
            operationErrorCode = "DATA-MIGRATE-BACKUP-CLEANUP-FAILED"
        }

        AppLogger.shared.log("===== 数据目录迁移完成 =====")
        AppLogger.shared.logPathState("数据目录迁移完成-本地入口[\(operationID)]", url: sourcePath)
        AppLogger.shared.logPathState("数据目录迁移完成-外部目标[\(operationID)]", url: destPath)
        invalidateSizeCache(for: sourcePath)
        invalidateSizeCache(for: destPath)
        if operationResult != "success_with_warning" {
            operationResult = "success"
        }
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
        let operationID = AppLogger.shared.makeOperationID(prefix: "data-restore")
        let startedAt = Date()
        var operationResult = "failed"
        var operationErrorCode: String?

        defer {
            AppLogger.shared.logOperationSummary(
                category: "data_restore",
                operationID: operationID,
                result: operationResult,
                startedAt: startedAt,
                errorCode: operationErrorCode,
                details: [
                    ("item_name", item.name),
                    ("type", item.type.rawValue),
                    ("local_path", localPath.path)
                ]
            )
        }

        AppLogger.shared.log("===== 开始还原数据目录 =====")
        AppLogger.shared.logContext(
            "数据目录还原上下文",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("type", item.type.rawValue),
                ("status", item.status),
                ("local_path", localPath.path)
            ]
        )
        AppLogger.shared.logPathState("数据目录还原前-本地入口[\(operationID)]", url: localPath)

        // 确认是符号链接
        guard isSymbolicLink(at: localPath) else {
            AppLogger.shared.logError(
                "数据目录还原前检查失败：本地路径不是符号链接",
                errorCode: "DATA-RESTORE-NOT-A-SYMLINK",
                context: [("operation_id", operationID)],
                relatedURLs: [("local", localPath)]
            )
            operationErrorCode = "DATA-RESTORE-NOT-A-SYMLINK"
            throw DataDirError.notASymlink(localPath)
        }

        // 获取外部路径
        guard let externalPathStr = try? fileManager.destinationOfSymbolicLink(atPath: localPath.path) else {
            AppLogger.shared.logError(
                "数据目录还原前检查失败：无法读取符号链接目标",
                errorCode: "DATA-RESTORE-INVALID-SYMLINK",
                context: [("operation_id", operationID)],
                relatedURLs: [("local", localPath)]
            )
            operationErrorCode = "DATA-RESTORE-INVALID-SYMLINK"
            throw DataDirError.invalidSymlink(localPath)
        }
        let externalPath = URL(fileURLWithPath: externalPathStr)
        AppLogger.shared.log("外部路径: \(externalPath.path)")
        AppLogger.shared.logPathState("数据目录还原前-外部源[\(operationID)]", url: externalPath)

        // 确认外部目录存在
        guard fileManager.fileExists(atPath: externalPath.path) else {
            AppLogger.shared.logError(
                "数据目录还原前检查失败：外部目录不存在",
                errorCode: "DATA-RESTORE-EXTERNAL-NOT-FOUND",
                context: [("operation_id", operationID)],
                relatedURLs: [("external", externalPath)]
            )
            operationErrorCode = "DATA-RESTORE-EXTERNAL-NOT-FOUND"
            throw DataDirError.externalNotFound(externalPath)
        }

        // 1. 复制外部目录到本地临时暂存目录（不删除符号链接，避免数据不可用窗口期）
        let stagingName = "restore-staging-\(UUID().uuidString)"
        let stagingPath = localPath.deletingLastPathComponent().appendingPathComponent(stagingName)
        AppLogger.shared.log("步骤1: 复制数据到暂存目录 \(stagingPath.lastPathComponent)...")
        let totalBytes = fastDirectorySize(at: externalPath, fileManager: fileManager)
        do {
            let copier = FileCopier()
            try await copier.copyDirectory(from: externalPath, to: stagingPath, progressHandler: progressHandler)
            try? removeManagedLinkMetadata(in: stagingPath)
            AppLogger.shared.log("步骤1: 复制完成")
            AppLogger.shared.logPathState("数据目录还原步骤1后-暂存目录[\(operationID)]", url: stagingPath)
        } catch {
            // 复制失败：清理暂存目录，符号链接保持不变
            AppLogger.shared.logError(
                "步骤1: 复制到暂存目录失败",
                error: error,
                errorCode: "DATA-RESTORE-COPY-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("local", localPath), ("external", externalPath), ("staging", stagingPath)]
            )
            try? fileManager.removeItem(at: stagingPath)
            operationErrorCode = "DATA-RESTORE-COPY-FAILED"
            throw DataDirError.copyFailed(error)
        }

        // 2. 原子替换：删除符号链接 → rename 暂存目录到原路径
        AppLogger.shared.log("步骤2: 原子替换（删除符号链接 + 重命名暂存目录）...")
        do {
            try fileManager.removeItem(at: localPath)
            AppLogger.shared.logPathState("数据目录还原步骤2-符号链接已删除[\(operationID)]", url: localPath)
        } catch {
            // 符号链接删除失败：清理暂存目录，保持原状
            AppLogger.shared.logError(
                "步骤2: 删除符号链接失败",
                error: error,
                errorCode: "DATA-RESTORE-SYMLINK-REMOVE-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("local", localPath), ("staging", stagingPath)]
            )
            try? fileManager.removeItem(at: stagingPath)
            operationErrorCode = "DATA-RESTORE-SYMLINK-REMOVE-FAILED"
            throw DataDirError.deletionFailed(error)
        }
        do {
            try fileManager.moveItem(at: stagingPath, to: localPath)
            AppLogger.shared.log("步骤2: 暂存目录已重命名为原路径")
            AppLogger.shared.logPathState("数据目录还原步骤2后-本地路径[\(operationID)]", url: localPath)
        } catch {
            // rename 失败：尝试恢复符号链接
            AppLogger.shared.logError(
                "步骤2: 重命名暂存目录失败，尝试恢复符号链接",
                error: error,
                errorCode: "DATA-RESTORE-RENAME-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("local", localPath), ("staging", stagingPath), ("external", externalPath)]
            )
            try? createSymbolicLink(at: localPath, withDestinationURL: externalPath)
            // 保留暂存目录以便用户手动恢复
            AppLogger.shared.log("暂存目录保留在: \(stagingPath.path)，可手动恢复", level: "WARN")
            operationErrorCode = "DATA-RESTORE-RENAME-FAILED"
            throw DataDirError.copyFailed(error)
        }

        // 3. 删除外部目录
        AppLogger.shared.log("步骤3: 删除外部目录...")
        await progressHandler?(FileCopier.Progress(copiedBytes: totalBytes, totalBytes: totalBytes, currentFile: "正在清理外部存储...".localized))
        try? removeManagedLinkMetadata(in: externalPath)
        // 先递归删除子目录内容（避免受保护文件阻止删除父目录）
        try? fileManager.removeItem(at: externalPath)
        // 如果整体删除失败，尝试逐个删除内容
        if fileManager.fileExists(atPath: externalPath.path) {
            AppLogger.shared.log("整体删除外部目录失败，尝试逐项清理...")
            try? removeAllContents(of: externalPath)
            try? fileManager.removeItem(at: externalPath)
        }
        if fileManager.fileExists(atPath: externalPath.path) {
            AppLogger.shared.log("步骤3: 删除外部目录失败（本地还原已完成，可手动清理）", level: "WARN")
            operationResult = "success_with_warning"
            operationErrorCode = "DATA-RESTORE-EXTERNAL-CLEANUP-FAILED"
        } else {
            AppLogger.shared.log("步骤3: 完成")
        }
        AppLogger.shared.logPathState("数据目录还原完成-外部路径[\(operationID)]", url: externalPath)

        // 清理本地残留的 partial-recovery 暂存目录
        cleanStaleRestoreStaging(in: localPath.deletingLastPathComponent())

        AppLogger.shared.log("===== 数据目录还原完成 =====")
        AppLogger.shared.logPathState("数据目录还原完成-本地路径[\(operationID)]", url: localPath)
        invalidateSizeCache(for: localPath)
        invalidateSizeCache(for: externalPath)
        if operationResult != "success_with_warning" {
            operationResult = "success"
        }
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
        let operationID = AppLogger.shared.makeOperationID(prefix: "data-link")
        let startedAt = Date()
        var operationResult = "failed"
        var operationErrorCode: String?

        defer {
            AppLogger.shared.logOperationSummary(
                category: "data_link",
                operationID: operationID,
                result: operationResult,
                startedAt: startedAt,
                errorCode: operationErrorCode,
                details: [
                    ("local_path", localPath.path),
                    ("external_path", externalPath.path)
                ]
            )
        }

        AppLogger.shared.logContext(
            "创建数据目录符号链接",
            details: [
                ("operation_id", operationID),
                ("local_path", localPath.path),
                ("external_path", externalPath.path)
            ]
        )
        AppLogger.shared.logPathState("创建数据目录链接前-本地路径[\(operationID)]", url: localPath)
        AppLogger.shared.logPathState("创建数据目录链接前-外部路径[\(operationID)]", url: externalPath)

        if isProtectedGroupContainerRootPath(localPath) {
            AppLogger.shared.logError(
                "创建数据目录符号链接失败：应用组容器根目录受 macOS 保护",
                errorCode: "DATA-LINK-PROTECTED-PATH",
                context: [("operation_id", operationID), ("local_path", localPath.path)],
                relatedURLs: [("local", localPath)]
            )
            operationErrorCode = "DATA-LINK-PROTECTED-PATH"
            throw DataDirError.protectedPath(localPath)
        }

        // 确认外部目录存在
        guard fileManager.fileExists(atPath: externalPath.path) else {
            AppLogger.shared.logError(
                "创建数据目录符号链接失败：外部目录不存在",
                errorCode: "DATA-LINK-EXTERNAL-NOT-FOUND",
                context: [("operation_id", operationID)],
                relatedURLs: [("external", externalPath)]
            )
            operationErrorCode = "DATA-LINK-EXTERNAL-NOT-FOUND"
            throw DataDirError.externalNotFound(externalPath)
        }

        let parentURL = localPath.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        // 如果本地路径已存在符号链接，先删除
        if isSymbolicLink(at: localPath) {
            try fileManager.removeItem(at: localPath)
        }

        // 确认本地路径不存在真实内容
        if fileManager.fileExists(atPath: localPath.path) {
            operationErrorCode = "DATA-LINK-DESTINATION-CONFLICT"
            throw DataDirError.destinationExists(localPath)
        }

        if let inferredType = inferType(for: localPath) {
            do {
                try writeManagedLinkMetadata(sourcePath: localPath, destinationPath: externalPath, type: inferredType)
            } catch {
                operationErrorCode = "DATA-LINK-METADATA-WRITE-FAILED"
                throw DataDirError.metadataWriteFailed(error)
            }
        }

        do {
            try createSymbolicLink(at: localPath, withDestinationURL: externalPath)
            AppLogger.shared.log("符号链接创建成功")
            AppLogger.shared.logPathState("创建数据目录链接完成-本地路径[\(operationID)]", url: localPath)
        } catch {
            try? removeManagedLinkMetadata(in: externalPath)
            AppLogger.shared.logError(
                "创建数据目录符号链接失败",
                error: error,
                errorCode: "DATA-LINK-SYMLINK-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("local", localPath), ("external", externalPath)]
            )
            operationErrorCode = "DATA-LINK-SYMLINK-FAILED"
            throw DataDirError.symlinkFailed(error)
        }
        operationResult = "success"
    }

    // MARK: - 删除本地链接

    /// 删除本地符号链接，保留外部真实目录。
    ///
    /// 适用场景：用户想断开本地入口，但继续保留外部存储中的目录，之后可再接回。
    ///
    /// - Parameter localPath: 本地原路径（必须是符号链接）
    ///
    /// - Throws: 文件系统错误、目标不是符号链接
    func deleteLink(localPath: URL) throws {
        let operationID = AppLogger.shared.makeOperationID(prefix: "data-unlink")
        let startedAt = Date()
        var operationResult = "failed"
        var operationErrorCode: String?

        defer {
            AppLogger.shared.logOperationSummary(
                category: "data_unlink",
                operationID: operationID,
                result: operationResult,
                startedAt: startedAt,
                errorCode: operationErrorCode,
                details: [
                    ("local_path", localPath.path)
                ]
            )
        }

        AppLogger.shared.logContext(
            "开始删除数据目录本地链接",
            details: [
                ("operation_id", operationID),
                ("local_path", localPath.path)
            ]
        )
        AppLogger.shared.logPathState("删除数据目录链接前-本地路径[\(operationID)]", url: localPath)

        do {
            try checkWritePermission(at: localPath.deletingLastPathComponent())
        } catch {
            operationErrorCode = "DATA-UNLINK-PERMISSION-DENIED"
            throw error
        }

        guard isSymbolicLink(at: localPath) else {
            AppLogger.shared.logError(
                "删除数据目录本地链接失败：本地路径不是符号链接",
                errorCode: "DATA-UNLINK-NOT-A-SYMLINK",
                context: [("operation_id", operationID)],
                relatedURLs: [("local", localPath)]
            )
            operationErrorCode = "DATA-UNLINK-NOT-A-SYMLINK"
            throw DataDirError.notASymlink(localPath)
        }

        do {
            try fileManager.removeItem(at: localPath)
            AppLogger.shared.logPathState("删除数据目录链接后-本地路径[\(operationID)]", url: localPath)
            operationResult = "success"
        } catch {
            AppLogger.shared.logError(
                "删除数据目录本地链接失败",
                error: error,
                errorCode: "DATA-UNLINK-REMOVE-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("local", localPath)]
            )
            operationErrorCode = "DATA-UNLINK-REMOVE-FAILED"
            throw DataDirError.deletionFailed(error)
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
        let operationID = AppLogger.shared.makeOperationID(prefix: "data-normalize")
        let standardizedCurrent = currentExternalPath.standardizedFileURL
        let standardizedNormalized = normalizedExternalPath.standardizedFileURL
        let startedAt = Date()
        var operationResult = "failed"
        var operationErrorCode: String?

        defer {
            AppLogger.shared.logOperationSummary(
                category: "data_normalize",
                operationID: operationID,
                result: operationResult,
                startedAt: startedAt,
                errorCode: operationErrorCode,
                details: [
                    ("local_path", localPath.path),
                    ("current_external_path", standardizedCurrent.path),
                    ("normalized_external_path", standardizedNormalized.path)
                ]
            )
        }

        AppLogger.shared.logContext(
            "开始规范化受管数据目录链接",
            details: [
                ("operation_id", operationID),
                ("local_path", localPath.path),
                ("current_external_path", standardizedCurrent.path),
                ("normalized_external_path", standardizedNormalized.path)
            ]
        )
        AppLogger.shared.logPathState("规范化前-本地路径[\(operationID)]", url: localPath)
        AppLogger.shared.logPathState("规范化前-当前外部路径[\(operationID)]", url: standardizedCurrent)
        AppLogger.shared.logPathState("规范化前-规范目标[\(operationID)]", url: standardizedNormalized)

        if isProtectedGroupContainerRootPath(localPath) {
            AppLogger.shared.logError(
                "规范化受管数据目录链接失败：应用组容器根目录受 macOS 保护",
                errorCode: "DATA-NORMALIZE-PROTECTED-PATH",
                context: [("operation_id", operationID), ("local_path", localPath.path)],
                relatedURLs: [("local", localPath)]
            )
            operationErrorCode = "DATA-NORMALIZE-PROTECTED-PATH"
            throw DataDirError.protectedPath(localPath)
        }

        guard fileManager.fileExists(atPath: standardizedCurrent.path) else {
            AppLogger.shared.logError(
                "规范化受管数据目录链接失败：当前外部路径不存在",
                errorCode: "DATA-NORMALIZE-EXTERNAL-NOT-FOUND",
                context: [("operation_id", operationID)],
                relatedURLs: [("external", standardizedCurrent)]
            )
            operationErrorCode = "DATA-NORMALIZE-EXTERNAL-NOT-FOUND"
            throw DataDirError.externalNotFound(standardizedCurrent)
        }

        if standardizedCurrent == standardizedNormalized {
            try createLink(localPath: localPath, externalPath: standardizedCurrent)
            operationResult = "success"
            return
        }

        let normalizedParent = standardizedNormalized.deletingLastPathComponent()
        do {
            try checkWritePermission(at: normalizedParent)
        } catch {
            operationErrorCode = "DATA-NORMALIZE-PERMISSION-DENIED"
            throw error
        }

        if fileManager.fileExists(atPath: standardizedNormalized.path) {
            operationErrorCode = "DATA-NORMALIZE-DESTINATION-CONFLICT"
            throw DataDirError.destinationExists(standardizedNormalized)
        }

        do {
            try fileManager.moveItem(at: standardizedCurrent, to: standardizedNormalized)
            AppLogger.shared.log("规范化管理: 已移动外部数据到规范路径")
            AppLogger.shared.logPathState("规范化步骤1后-规范目标[\(operationID)]", url: standardizedNormalized)
        } catch {
            AppLogger.shared.logError(
                "规范化管理: 移动外部数据失败",
                error: error,
                errorCode: "DATA-NORMALIZE-MOVE-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("current_external", standardizedCurrent), ("normalized_external", standardizedNormalized)]
            )
            operationErrorCode = "DATA-NORMALIZE-MOVE-FAILED"
            throw DataDirError.copyFailed(error)
        }

        do {
            try createLink(localPath: localPath, externalPath: standardizedNormalized)
            AppLogger.shared.log("规范化管理: 已重建本地软链接")
        } catch {
            AppLogger.shared.logError(
                "规范化管理: 重建本地软链接失败，尝试回滚外部路径",
                error: error,
                errorCode: "DATA-NORMALIZE-RELINK-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("local", localPath), ("current_external", standardizedCurrent), ("normalized_external", standardizedNormalized)]
            )

            if !fileManager.fileExists(atPath: standardizedCurrent.path),
               fileManager.fileExists(atPath: standardizedNormalized.path) {
                try? fileManager.moveItem(at: standardizedNormalized, to: standardizedCurrent)
            }

            try? createLink(localPath: localPath, externalPath: standardizedCurrent)
            operationErrorCode = "DATA-NORMALIZE-RELINK-FAILED"
            throw error
        }

        AppLogger.shared.logPathState("规范化完成-本地路径[\(operationID)]", url: localPath)
        AppLogger.shared.logPathState("规范化完成-规范目标[\(operationID)]", url: standardizedNormalized)
        operationResult = "success"
    }

    // MARK: - 私有辅助

    /// 检查目录的写入权限
    private func checkWritePermission(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            // 如果目录不存在，尝试创建
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            AppLogger.shared.logContext("写权限检查：目标目录不存在，已自动创建", details: [("path", url.path)], level: "TRACE")
            return
        }
        guard fileManager.isWritableFile(atPath: url.path) else {
            AppLogger.shared.logError(
                "写权限检查失败",
                context: [("path", url.path)],
                relatedURLs: [("path", url)]
            )
            throw DataDirError.permissionDenied(url)
        }
        AppLogger.shared.logContext("写权限检查通过", details: [("path", url.path)], level: "TRACE")
    }

    private func cleanupFailedMigrationDestination(
        at destinationURL: URL,
        within cleanupRootURL: URL,
        operationID: String
    ) {
        let standardizedDestination = destinationURL.standardizedFileURL
        let standardizedCleanupRoot = cleanupRootURL.standardizedFileURL

        do {
            try? removeManagedLinkMetadata(in: standardizedDestination)

            if fileManager.fileExists(atPath: standardizedDestination.path) {
                try fileManager.removeItem(at: standardizedDestination)
                AppLogger.shared.logContext(
                    "迁移回滚：已删除外部半成品目录",
                    details: [
                        ("operation_id", operationID),
                        ("path", standardizedDestination.path)
                    ]
                )
            }
        } catch {
            AppLogger.shared.logError(
                "迁移回滚：删除外部半成品目录失败",
                error: error,
                context: [("operation_id", operationID)],
                relatedURLs: [("destination", standardizedDestination)]
            )
        }

        pruneEmptyDirectories(
            startingAt: standardizedDestination.deletingLastPathComponent(),
            upToIncluding: standardizedCleanupRoot,
            operationID: operationID
        )
    }

    private func moveSourceToMigrationBackup(_ sourcePath: URL, operationID: String) throws -> URL {
        let backupURL = makeMigrationBackupURL(for: sourcePath)
        try fileManager.moveItem(at: sourcePath, to: backupURL)
        AppLogger.shared.logContext(
            "迁移安全备份：已将源目录改名",
            details: [
                ("operation_id", operationID),
                ("source_path", sourcePath.path),
                ("backup_path", backupURL.path)
            ],
            level: "TRACE"
        )
        return backupURL
    }

    private func makeMigrationBackupURL(for sourcePath: URL) -> URL {
        let parentURL = sourcePath.deletingLastPathComponent()
        let backupName = ".appports-migration-backup-\(sourcePath.lastPathComponent)-\(UUID().uuidString)"
        return parentURL.appendingPathComponent(backupName)
    }

    private func restoreMigrationBackup(_ backupURL: URL, to sourcePath: URL, operationID: String) {
        if fileManager.fileExists(atPath: sourcePath.path) {
            if isSymbolicLink(at: sourcePath) {
                try? fileManager.removeItem(at: sourcePath)
            } else {
                AppLogger.shared.logError(
                    "迁移安全备份：源路径已存在，未覆盖恢复",
                    errorCode: "DATA-MIGRATE-BACKUP-RESTORE-SOURCE-EXISTS",
                    context: [("operation_id", operationID)],
                    relatedURLs: [("source", sourcePath), ("backup", backupURL)]
                )
                return
            }
        }

        do {
            try fileManager.moveItem(at: backupURL, to: sourcePath)
            AppLogger.shared.logContext(
                "迁移安全备份：已恢复到本地源路径",
                details: [
                    ("operation_id", operationID),
                    ("source_path", sourcePath.path),
                    ("backup_path", backupURL.path)
                ],
                level: "WARN"
            )
        } catch {
            AppLogger.shared.logError(
                "迁移安全备份：恢复到本地源路径失败，外部副本仍保留",
                error: error,
                errorCode: "DATA-MIGRATE-BACKUP-RESTORE-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("source", sourcePath), ("backup", backupURL)]
            )
        }
    }

    private func cleanupMigrationBackup(_ backupURL: URL, operationID: String) throws {
        if failSourceBackupCleanup {
            throw NSError(
                domain: "AppPorts.DataDirMover",
                code: 9002,
                userInfo: [NSLocalizedDescriptionKey: "forced source backup cleanup failure"]
            )
        }

        guard fileManager.fileExists(atPath: backupURL.path) else { return }
        try fileManager.removeItem(at: backupURL)
        AppLogger.shared.logContext(
            "迁移安全备份：已清理本地备份",
            details: [
                ("operation_id", operationID),
                ("backup_path", backupURL.path)
            ],
            level: "TRACE"
        )
    }

    private func pruneEmptyDirectories(
        startingAt directoryURL: URL,
        upToIncluding cleanupRootURL: URL,
        operationID: String
    ) {
        let standardizedCleanupRoot = cleanupRootURL.standardizedFileURL
        var currentURL = directoryURL.standardizedFileURL

        guard isDescendantOrSame(currentURL, of: standardizedCleanupRoot) else { return }

        while true {
            guard fileManager.fileExists(atPath: currentURL.path) else {
                if currentURL == standardizedCleanupRoot { break }
                currentURL = currentURL.deletingLastPathComponent()
                guard isDescendantOrSame(currentURL, of: standardizedCleanupRoot) else { break }
                continue
            }

            do {
                let contents = try fileManager.contentsOfDirectory(atPath: currentURL.path)
                guard contents.isEmpty else { break }

                try fileManager.removeItem(at: currentURL)
                AppLogger.shared.logContext(
                    "迁移回滚：已删除空父目录",
                    details: [
                        ("operation_id", operationID),
                        ("path", currentURL.path)
                    ],
                    level: "TRACE"
                )
            } catch {
                AppLogger.shared.logError(
                    "迁移回滚：删除空父目录失败",
                    error: error,
                    context: [("operation_id", operationID)],
                    relatedURLs: [("directory", currentURL)]
                )
                break
            }

            if currentURL == standardizedCleanupRoot { break }

            currentURL = currentURL.deletingLastPathComponent()
            guard isDescendantOrSame(currentURL, of: standardizedCleanupRoot) else { break }
        }
    }

    private func isDescendantOrSame(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path

        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func createSymbolicLink(at localPath: URL, withDestinationURL externalPath: URL) throws {
        if failSymlinkCreation {
            throw NSError(
                domain: "AppPorts.DataDirMover",
                code: 9001,
                userInfo: [NSLocalizedDescriptionKey: "forced symlink failure"]
            )
        }

        try fileManager.createSymbolicLink(at: localPath, withDestinationURL: externalPath)
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// 检查路径是否为 macOS 受保护的顶层容器目录（~/Library/Containers/xxx）
    ///
    /// macOS 系统保护 `~/Library/Containers/` 目录，不允许第三方应用创建新条目。
    /// 迁移这些目录会导致原始数据被删除后无法创建符号链接，造成数据丢失。
    /// 递归删除目录下所有内容（跳过受保护无法删除的文件）
    private func removeAllContents(of directory: URL) throws {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for item in contents {
            let itemURL = directory.appendingPathComponent(item)
            do {
                // 先处理子目录
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir), isDir.boolValue {
                    try removeAllContents(of: itemURL)
                }
                try fileManager.removeItem(at: itemURL)
            } catch {
                AppLogger.shared.logContext(
                    "清理时跳过受保护文件",
                    details: [("path", itemURL.path), ("error", error.localizedDescription)],
                    level: "TRACE"
                )
            }
        }
    }

    /// 清理 restore 操作遗留的 partial-recovery / restore-staging 暂存目录
    private func cleanStaleRestoreStaging(in parentURL: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: parentURL.path) else { return }
        for item in contents {
            if item.contains("partial-recovery-") || item.contains("restore-staging-") {
                let itemURL = parentURL.appendingPathComponent(item)
                try? fileManager.removeItem(at: itemURL)
                AppLogger.shared.logContext(
                    "已清理残留的还原暂存目录",
                    details: [("path", itemURL.path)],
                    level: "INFO"
                )
            }
        }
    }

    private func isProtectedContainersPath(_ url: URL) -> Bool {
        // 使用真实 home 目录，而非可覆盖的 homeDir（测试中会注入临时目录）
        let realHome = URL(fileURLWithPath: NSHomeDirectory())
        let containersURL = realHome.appendingPathComponent("Library/Containers")
        let standardized = url.standardizedFileURL
        let parentPath = standardized.deletingLastPathComponent().path

        // 顶层容器目录：~/Library/Containers/xxx
        if parentPath == containersURL.standardizedFileURL.path {
            return true
        }

        // 阻止 Data 下的受保护目录：Data/Library、Data/Documents、Data/Library/Application Support
        // macOS 沙盒会对这些目录做完整性校验，不能是符号链接。子目录可安全迁移。
        let pathComponents = standardized.pathComponents
        guard let containersIndex = pathComponents.lastIndex(of: "Containers"),
              containersIndex + 2 < pathComponents.count,
              pathComponents[containersIndex + 2] == "Data" else {
            return false
        }
        let subPath = pathComponents[(containersIndex + 3)...]
        if subPath == ["Library"] || subPath == ["Documents"] {
            return true
        }
        if subPath == ["Library", "Application Support"] {
            return true
        }

        // 微信专属：Data/Documents/xwechat_files 自身不可迁移（仅其子目录可迁移）
        let isWeChatContainer = pathComponents[containersIndex + 1] == "com.tencent.xinWeChat"
        if isWeChatContainer && subPath == ["Documents", "xwechat_files"] {
            return true
        }

        return false
    }

    private func isProtectedGroupContainerRootPath(_ url: URL) -> Bool {
        let groupContainersURL = homeDir.appendingPathComponent("Library/Group Containers").standardizedFileURL
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent().path == groupContainersURL.path
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

    private func readManagedLinkMetadata(at directoryURL: URL) -> ManagedLinkMetadata? {
        let markerURL = markerURL(for: directoryURL)
        guard fileManager.fileExists(atPath: markerURL.path),
              let data = try? Data(contentsOf: markerURL),
              let metadata = try? PropertyListDecoder().decode(ManagedLinkMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    private func hasMatchingManagedLinkMetadata(
        at directoryURL: URL,
        sourcePath: URL,
        destinationPath: URL,
        type: DataDirType
    ) -> Bool {
        guard let metadata = readManagedLinkMetadata(at: directoryURL) else {
            return false
        }

        return metadata.schemaVersion == managedLinkSchemaVersion
            && metadata.managedBy == managedLinkIdentifier
            && metadata.sourcePath == sourcePath.standardizedFileURL.path
            && metadata.destinationPath == destinationPath.standardizedFileURL.path
            && metadata.dataDirType == type.rawValue
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
    case protectedPath(URL)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let url):
            return String(format: "没有写入权限：%@".localized, url.path)
        case .destinationExists(let url):
            return String(format: "目标路径已存在真实目录，无法覆盖：%@".localized, url.lastPathComponent)
        case .deletionFailed(let error):
            return String(format: "删除原目录失败：%@".localized, error.localizedDescription)
        case .symlinkFailed(let error):
            return String(format: "创建符号链接失败，数据已紧急还原：%@".localized, error.localizedDescription)
        case .copyFailed(let error):
            return String(format: "复制失败：%@".localized, error.localizedDescription)
        case .metadataWriteFailed(let error):
            return String(format: "写入 AppPorts 链接标记失败：%@".localized, error.localizedDescription)
        case .notASymlink(let url):
            return String(format: "该目录不是符号链接，无法还原：%@".localized, url.lastPathComponent)
        case .invalidSymlink(let url):
            return String(format: "无法读取符号链接目标：%@".localized, url.lastPathComponent)
        case .externalNotFound(let url):
            return String(format: "外部存储目录不存在：%@".localized, url.path)
        case .protectedPath(let url):
            return String(format: "该目录受 macOS 系统保护，无法迁移：%@。请改为迁移容器内的子目录。".localized, url.lastPathComponent)
        }
    }
}
