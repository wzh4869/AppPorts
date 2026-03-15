//
//  AppMigrationService.swift
//  AppPorts
//
//  Created by Codex on 2026/3/12.
//

import Foundation

struct AppMigrationService {
    typealias FinderRemover = (URL) throws -> Void
    typealias PortalCreationOverride = (AppItem, URL) throws -> Void

    private enum LocalPortalKind {
        case wholeAppSymlink
        case deepContentsWrapper
    }

    private struct LocalPortalSnapshot {
        let localURL: URL
        let externalURL: URL
        let kind: LocalPortalKind
    }

    private let fileManager: FileManager
    private let portalCreationOverride: PortalCreationOverride?

    init(
        fileManager: FileManager = .default,
        portalCreationOverride: PortalCreationOverride? = nil
    ) {
        self.fileManager = fileManager
        self.portalCreationOverride = portalCreationOverride
    }

    static func checkWritePermission(at localURL: URL, fileManager: FileManager = .default) throws {
        let parentURL = localURL.deletingLastPathComponent()
        let testFileURL = parentURL.appendingPathComponent(".permission_check_\(UUID().uuidString)")

        do {
            try "test".write(to: testFileURL, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: testFileURL)
        } catch {
            throw AppMoverError.permissionDenied(error)
        }
    }

    static func removeItemViaFinder(at url: URL) throws {
        let escapedPath = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to delete POSIX file \"\(escapedPath)\""

        AppLogger.shared.log("执行 AppleScript: \(script)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                AppLogger.shared.logError("osascript 退出码: \(process.terminationStatus), 错误: \(errorOutput)")
                throw NSError(
                    domain: "AppleScript",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errorOutput.isEmpty ? "Finder 删除失败" : errorOutput]
                )
            }

            AppLogger.shared.log("Finder 删除成功")
        } catch {
            AppLogger.shared.logError("Process 执行失败", error: error)
            throw error
        }
    }

    func moveAndLink(
        appToMove: AppItem,
        destinationURL: URL,
        isRunning: Bool,
        deleteSourceFallback: FinderRemover? = nil,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws {
        let operationID = AppLogger.shared.makeOperationID(prefix: "app-move")
        let startedAt = Date()
        var operationResult = "failed"
        var operationErrorCode: String?

        defer {
            AppLogger.shared.logOperationSummary(
                category: "app_move",
                operationID: operationID,
                result: operationResult,
                startedAt: startedAt,
                errorCode: operationErrorCode,
                details: [
                    ("app_name", appToMove.name),
                    ("source_path", appToMove.path.path),
                    ("destination_path", destinationURL.path),
                    ("is_folder", appToMove.usesFolderOperation ? "true" : "false")
                ]
            )
        }

        AppLogger.shared.log("===== 开始迁移应用 =====")
        AppLogger.shared.logContext(
            "应用迁移上下文",
            details: [
                ("operation_id", operationID),
                ("app_name", appToMove.name),
                ("source_path", appToMove.path.path),
                ("destination_path", destinationURL.path),
                ("is_folder", appToMove.usesFolderOperation ? "true" : "false"),
                ("app_count", appToMove.usesFolderOperation ? String(appToMove.appCount) : nil),
                ("status", appToMove.status),
                ("is_running", isRunning ? "true" : "false"),
                ("has_finder_fallback", deleteSourceFallback == nil ? "false" : "true")
            ]
        )
        AppLogger.shared.logPathState("迁移前-本地源[\(operationID)]", url: appToMove.path)
        AppLogger.shared.logPathState("迁移前-外部目标[\(operationID)]", url: destinationURL)

        do {
            try Self.checkWritePermission(at: appToMove.path, fileManager: fileManager)
        } catch {
            operationErrorCode = "APP-MOVE-PERMISSION-DENIED"
            AppLogger.shared.logError(
                "迁移前权限检查失败",
                error: error,
                errorCode: operationErrorCode,
                context: [("operation_id", operationID)],
                relatedURLs: [("source", appToMove.path)]
            )
            throw error
        }
        AppLogger.shared.log("权限检查通过")

        if isRunning {
            operationErrorCode = "APP-MOVE-APP-RUNNING"
            AppLogger.shared.logError(
                "应用正在运行，无法迁移",
                errorCode: operationErrorCode,
                context: [("operation_id", operationID), ("app_name", appToMove.name)],
                relatedURLs: [("source", appToMove.path)]
            )
            throw AppMoverError.appIsRunning
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            AppLogger.shared.log("目标位置已存在文件，检查是否为符号链接")
            AppLogger.shared.logPathState("迁移冲突-目标现状[\(operationID)]", url: destinationURL)
            let existingItemResourceValues = try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if existingItemResourceValues?.isSymbolicLink == true {
                try fileManager.removeItem(at: destinationURL)
                AppLogger.shared.log("已删除目标位置的符号链接")
            } else {
                operationErrorCode = "APP-MOVE-DESTINATION-CONFLICT"
                AppLogger.shared.logError(
                    "目标位置存在真实文件，无法覆盖",
                    errorCode: operationErrorCode,
                    context: [("operation_id", operationID), ("destination_path", destinationURL.path)],
                    relatedURLs: [("destination", destinationURL)]
                )
                throw AppMoverError.generalError(
                    NSError(
                        domain: "AppMover",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "目标已存在真实文件"]
                    )
                )
            }
        }

        do {
            AppLogger.shared.log("步骤1: 开始复制应用到外部存储...")
            let copier = FileCopier()
            try await copier.copyDirectory(
                from: appToMove.path,
                to: destinationURL,
                progressHandler: progressHandler
            )
            AppLogger.shared.log("步骤1: 复制成功")
            AppLogger.shared.logPathState("步骤1后-外部副本[\(operationID)]", url: destinationURL)

            AppLogger.shared.log("步骤2: 尝试删除源文件 (普通方式)...")
            do {
                try fileManager.removeItem(at: appToMove.path)
                AppLogger.shared.log("步骤2: 普通删除成功")
                AppLogger.shared.logPathState("步骤2后-本地源[\(operationID)]", url: appToMove.path)
            } catch let normalError {
                AppLogger.shared.logError(
                    "步骤2: 普通删除失败，尝试使用 Finder...",
                    error: normalError,
                    context: [("operation_id", operationID)],
                    relatedURLs: [("source", appToMove.path), ("destination", destinationURL)]
                )

                if let deleteSourceFallback {
                    do {
                        try deleteSourceFallback(appToMove.path)
                        AppLogger.shared.log("步骤2: Finder 删除成功")
                        AppLogger.shared.logPathState("Finder 删除后-本地源[\(operationID)]", url: appToMove.path)
                    } catch let finderError {
                        AppLogger.shared.logError(
                            "步骤2: Finder 删除也失败，执行回滚",
                            error: finderError,
                            errorCode: "APP-MOVE-SOURCE-DELETE-FAILED",
                            context: [("operation_id", operationID)],
                            relatedURLs: [("source", appToMove.path), ("destination", destinationURL)]
                        )
                        try? fileManager.removeItem(at: destinationURL)
                        AppLogger.shared.log("回滚: 已删除外部存储中的副本")
                        operationResult = "rolled_back"
                        operationErrorCode = "APP-MOVE-SOURCE-DELETE-FAILED"
                        throw AppMoverError.appStoreAppError(finderError)
                    }
                } else {
                    AppLogger.shared.logError(
                        "步骤2: 删除失败，执行回滚",
                        error: normalError,
                        errorCode: "APP-MOVE-SOURCE-DELETE-FAILED",
                        context: [("operation_id", operationID)],
                        relatedURLs: [("source", appToMove.path), ("destination", destinationURL)]
                    )
                    try? fileManager.removeItem(at: destinationURL)
                    operationResult = "rolled_back"
                    operationErrorCode = "APP-MOVE-SOURCE-DELETE-FAILED"
                    throw AppMoverError.generalError(normalError)
                }
            }
        } catch {
            operationErrorCode = operationErrorCode ?? "APP-MOVE-FILE-TRANSFER-FAILED"
            AppLogger.shared.logError(
                "迁移过程出错",
                error: error,
                errorCode: operationErrorCode,
                context: [("operation_id", operationID), ("app_name", appToMove.name)],
                relatedURLs: [("source", appToMove.path), ("destination", destinationURL)]
            )
            throw error
        }

        do {
            try buildPortal(for: appToMove, destinationURL: destinationURL, operationID: operationID)
        } catch {
            operationErrorCode = "APP-MOVE-PORTAL-CREATE-FAILED"
            AppLogger.shared.logError(
                "步骤3: 创建本地入口失败，执行紧急回滚",
                error: error,
                errorCode: operationErrorCode,
                context: [("operation_id", operationID)],
                relatedURLs: [("source", appToMove.path), ("destination", destinationURL)]
            )

            do {
                try await rollbackMoveAndLink(appToMove: appToMove, destinationURL: destinationURL, operationID: operationID)
                operationResult = "rolled_back"
                throw AppMoverError.generalError(
                    NSError(
                        domain: "AppMover",
                        code: 10,
                        userInfo: [NSLocalizedDescriptionKey: "创建本地入口失败，应用已自动恢复到本地：\(error.localizedDescription)"]
                    )
                )
            } catch let rollbackError as AppMoverError {
                throw rollbackError
            } catch {
                operationErrorCode = "APP-MOVE-ROLLBACK-FAILED"
                AppLogger.shared.logError(
                    "步骤3: 自动回滚失败",
                    error: error,
                    errorCode: operationErrorCode,
                    context: [("operation_id", operationID)],
                    relatedURLs: [("source", appToMove.path), ("destination", destinationURL)]
                )
                throw AppMoverError.generalError(
                    NSError(
                        domain: "AppMover",
                        code: 11,
                        userInfo: [NSLocalizedDescriptionKey: "创建本地入口失败，且自动回滚未完成。外部副本仍保留在：\(destinationURL.path)"]
                    )
                )
            }
        }

        AppLogger.shared.log("锁定外部项目，防止被修改或删除...")
        try? fileManager.setAttributes([.immutable: true], ofItemAtPath: destinationURL.path)
        AppLogger.shared.logPathState("迁移完成-本地入口[\(operationID)]", url: appToMove.path)
        AppLogger.shared.logPathState("迁移完成-外部目标[\(operationID)]", url: destinationURL)
        operationResult = "success"
    }

    func linkApp(appToLink: AppItem, destinationURL: URL) throws {
        let operationID = AppLogger.shared.makeOperationID(prefix: "app-link")
        let startedAt = Date()
        var operationResult = "failed"
        var operationErrorCode: String?

        defer {
            AppLogger.shared.logOperationSummary(
                category: "app_link",
                operationID: operationID,
                result: operationResult,
                startedAt: startedAt,
                errorCode: operationErrorCode,
                details: [
                    ("app_name", appToLink.name),
                    ("source_path", appToLink.path.path),
                    ("destination_path", destinationURL.path),
                    ("is_folder", appToLink.usesFolderOperation ? "true" : "false")
                ]
            )
        }

        AppLogger.shared.logContext(
            "开始创建应用入口",
            details: [
                ("operation_id", operationID),
                ("app_name", appToLink.name),
                ("source_path", appToLink.path.path),
                ("destination_path", destinationURL.path),
                ("status", appToLink.status)
            ]
        )
        AppLogger.shared.logPathState("链接前-外部源[\(operationID)]", url: appToLink.path)
        AppLogger.shared.logPathState("链接前-本地目标[\(operationID)]", url: destinationURL)

        do {
            try Self.checkWritePermission(at: destinationURL, fileManager: fileManager)
        } catch {
            operationErrorCode = "APP-LINK-PERMISSION-DENIED"
            AppLogger.shared.logError(
                "创建应用入口前权限检查失败",
                error: error,
                errorCode: operationErrorCode,
                context: [("operation_id", operationID)],
                relatedURLs: [("source", appToLink.path), ("destination", destinationURL)]
            )
            throw error
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            let resourceValues = try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            AppLogger.shared.logPathState("链接冲突-本地目标[\(operationID)]", url: destinationURL)

            if resourceValues?.isSymbolicLink == true {
                try fileManager.removeItem(at: destinationURL)
            } else if resourceValues?.isDirectory == true {
                let contentsURL = destinationURL.appendingPathComponent("Contents")
                let contentsResourceValues = try? contentsURL.resourceValues(forKeys: [.isSymbolicLinkKey])

                if contentsResourceValues?.isSymbolicLink == true {
                    try fileManager.removeItem(at: destinationURL)
                } else {
                    operationErrorCode = "APP-LINK-DESTINATION-CONFLICT"
                    throw AppMoverError.generalError(
                        NSError(
                            domain: "AppMover",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "本地已存在同名真实应用"]
                        )
                    )
                }
            } else {
                operationErrorCode = "APP-LINK-DESTINATION-CONFLICT"
                throw AppMoverError.generalError(
                    NSError(
                        domain: "AppMover",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "本地已存在同名文件"]
                    )
                )
            }
        }

        let portalKind: LocalPortalKind = appToLink.usesFolderOperation ? .wholeAppSymlink : preferredPortalKind(for: appToLink.path)
        AppLogger.shared.logContext(
            "本地入口策略",
            details: [("operation_id", operationID), ("portal_kind", portalKindDescription(portalKind))]
        )

        switch portalKind {
        case .wholeAppSymlink:
            if isIOSAppBundle(at: appToLink.path) {
                AppLogger.shared.log("链接策略: iOS 应用 (整体符号链接)", level: "STRATEGY")
            } else {
                AppLogger.shared.log("链接策略: 自更新应用 (整体符号链接兼容模式)", level: "STRATEGY")
            }
        case .deepContentsWrapper:
            AppLogger.shared.log("链接策略: Mac 原生应用 (Contents 深度链接)", level: "STRATEGY")
        }

        do {
            try createLocalPortal(at: destinationURL, pointingTo: appToLink.path, portalKind: portalKind, operationID: operationID)
        } catch {
            operationErrorCode = "APP-LINK-PORTAL-CREATE-FAILED"
            AppLogger.shared.logError(
                "创建应用入口失败",
                error: error,
                errorCode: operationErrorCode,
                context: [("operation_id", operationID), ("portal_kind", portalKindDescription(portalKind))],
                relatedURLs: [("source", appToLink.path), ("destination", destinationURL)]
            )
            throw error
        }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destinationURL.path)
        AppLogger.shared.logPathState("链接完成-本地目标[\(operationID)]", url: destinationURL)
        operationResult = "success"
    }

    func deleteLink(app: AppItem) throws {
        let operationID = AppLogger.shared.makeOperationID(prefix: "app-unlink")
        let startedAt = Date()
        var operationResult = "failed"
        var operationErrorCode: String?

        defer {
            AppLogger.shared.logOperationSummary(
                category: "app_unlink",
                operationID: operationID,
                result: operationResult,
                startedAt: startedAt,
                errorCode: operationErrorCode,
                details: [
                    ("app_name", app.name),
                    ("path", app.path.path),
                    ("status", app.status)
                ]
            )
        }

        AppLogger.shared.logContext(
            "开始删除应用入口",
            details: [
                ("operation_id", operationID),
                ("app_name", app.name),
                ("path", app.path.path),
                ("status", app.status)
            ]
        )
        AppLogger.shared.logPathState("删除前-本地入口[\(operationID)]", url: app.path)

        do {
            try Self.checkWritePermission(at: app.path, fileManager: fileManager)
        } catch {
            operationErrorCode = "APP-UNLINK-PERMISSION-DENIED"
            AppLogger.shared.logError(
                "删除应用入口前权限检查失败",
                error: error,
                errorCode: operationErrorCode,
                context: [("operation_id", operationID)],
                relatedURLs: [("path", app.path)]
            )
            throw error
        }

        guard let portalKind = localPortalKind(at: app.path) else {
            operationErrorCode = "APP-UNLINK-NOT-A-PORTAL"
            AppLogger.shared.logError(
                "删除应用入口前检查失败：目标不是受支持的 App portal",
                errorCode: operationErrorCode,
                context: [("operation_id", operationID), ("app_name", app.name)],
                relatedURLs: [("path", app.path)]
            )
            throw AppMoverError.generalError(
                NSError(
                    domain: "AppMover",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "尝试删除非链接文件"]
                )
            )
        }

        AppLogger.shared.logContext(
            "删除应用入口校验通过",
            details: [
                ("operation_id", operationID),
                ("portal_kind", portalKindDescription(portalKind))
            ],
            level: "TRACE"
        )

        try fileManager.removeItem(at: app.path)

        AppLogger.shared.logPathState("删除后-本地入口[\(operationID)]", url: app.path)
        operationResult = "success"
    }

    func moveBack(
        app: AppItem,
        localDestinationURL: URL,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws {
        let operationID = AppLogger.shared.makeOperationID(prefix: "app-restore")
        let startedAt = Date()
        var operationResult = "failed"
        var operationErrorCode: String?

        defer {
            AppLogger.shared.logOperationSummary(
                category: "app_restore",
                operationID: operationID,
                result: operationResult,
                startedAt: startedAt,
                errorCode: operationErrorCode,
                details: [
                    ("app_name", app.name),
                    ("external_path", app.path.path),
                    ("local_destination", localDestinationURL.path),
                    ("is_folder", app.usesFolderOperation ? "true" : "false")
                ]
            )
        }

        AppLogger.shared.log("===== 开始还原应用 =====")
        AppLogger.shared.logContext(
            "应用还原上下文",
            details: [
                ("operation_id", operationID),
                ("app_name", app.name),
                ("external_path", app.path.path),
                ("local_destination", localDestinationURL.path),
                ("is_folder", app.usesFolderOperation ? "true" : "false"),
                ("app_count", app.usesFolderOperation ? String(app.appCount) : nil),
                ("status", app.status)
            ]
        )
        AppLogger.shared.logPathState("还原前-外部源[\(operationID)]", url: app.path)
        AppLogger.shared.logPathState("还原前-本地目标[\(operationID)]", url: localDestinationURL)

        do {
            try Self.checkWritePermission(at: localDestinationURL, fileManager: fileManager)
        } catch {
            operationErrorCode = "APP-RESTORE-PERMISSION-DENIED"
            AppLogger.shared.logError(
                "还原前权限检查失败",
                error: error,
                errorCode: operationErrorCode,
                context: [("operation_id", operationID)],
                relatedURLs: [("source", app.path), ("destination", localDestinationURL)]
            )
            throw error
        }
        AppLogger.shared.log("权限检查通过")

        let existingPortalKind = localPortalKind(at: localDestinationURL, linkedTo: app.path)
        let suitePortalSnapshots = app.isFolder
            ? folderPortalSnapshots(for: app.path, localAppsDir: localDestinationURL.deletingLastPathComponent())
            : []
        AppLogger.shared.logContext(
            "还原前入口检查",
            details: [
                ("operation_id", operationID),
                ("existing_portal_kind", existingPortalKind.map { portalKindDescription($0) } ?? "none"),
                ("suite_portal_snapshot_count", String(suitePortalSnapshots.count))
            ],
            level: "TRACE"
        )

        if fileManager.fileExists(atPath: localDestinationURL.path) {
            AppLogger.shared.log("本地存在同名项目，正在清理...")
            let resourceValues = try? localDestinationURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])

            if resourceValues?.isSymbolicLink == true {
                guard existingPortalKind == .wholeAppSymlink else {
                    let error = NSError(
                        domain: "AppMover",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "本地入口并未指向当前外部应用，无法自动覆盖"]
                    )
                    operationErrorCode = "APP-RESTORE-LOCAL-CONFLICT"
                    AppLogger.shared.logError("还原失败", error: error, errorCode: operationErrorCode)
                    throw AppMoverError.generalError(error)
                }
                try fileManager.removeItem(at: localDestinationURL)
                AppLogger.shared.log("已清理本地符号链接")
            } else if resourceValues?.isDirectory == true {
                if existingPortalKind == .deepContentsWrapper {
                    try fileManager.removeItem(at: localDestinationURL)
                    AppLogger.shared.log("已清理本地假壳/符号链接结构")
                } else {
                    let error = NSError(
                        domain: "AppMover",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "本地已存在同名真实文件，无法覆盖"]
                    )
                    operationErrorCode = "APP-RESTORE-LOCAL-CONFLICT"
                    AppLogger.shared.logError("还原失败", error: error, errorCode: operationErrorCode)
                    throw AppMoverError.generalError(error)
                }
            } else {
                let error = NSError(
                    domain: "AppMover",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "本地已存在同名文件，无法覆盖"]
                )
                operationErrorCode = "APP-RESTORE-LOCAL-CONFLICT"
                AppLogger.shared.logError("还原失败", error: error, errorCode: operationErrorCode)
                throw AppMoverError.generalError(error)
            }
        }

        if app.isFolder, !suitePortalSnapshots.isEmpty {
            for snapshot in suitePortalSnapshots {
                try fileManager.removeItem(at: snapshot.localURL)
                AppLogger.shared.log("已清理套件入口: \(snapshot.localURL.lastPathComponent)")
                AppLogger.shared.logPathState("已清理套件入口[\(operationID)]", url: snapshot.localURL, level: "TRACE")
            }
        }

        AppLogger.shared.log("步骤1: 开始复制应用回本地...")
        let startTime = Date()
        let copier = FileCopier()
        let sourceSize = (try? fileManager.attributesOfItem(atPath: app.path.path)[.size] as? Int64) ?? 0

        do {
            try await copier.copyDirectory(
                from: app.path,
                to: localDestinationURL,
                progressHandler: progressHandler
            )
        } catch {
            if fileManager.fileExists(atPath: localDestinationURL.path) {
                try? fileManager.removeItem(at: localDestinationURL)
            }

            if let existingPortalKind {
                do {
                    try createLocalPortal(
                        at: localDestinationURL,
                        pointingTo: app.path,
                        portalKind: existingPortalKind,
                        operationID: operationID
                    )
                } catch let portalError {
                    AppLogger.shared.logError(
                        "还原失败后恢复单应用入口失败",
                        error: portalError,
                        context: [("operation_id", operationID)],
                        relatedURLs: [("source", app.path), ("destination", localDestinationURL)]
                    )
                }
            }

            if app.isFolder, !suitePortalSnapshots.isEmpty {
                recreatePortals(from: suitePortalSnapshots, operationID: operationID)
            }

            AppLogger.shared.logError(
                "复制外部应用回本地失败",
                error: error,
                errorCode: "APP-RESTORE-COPY-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("source", app.path), ("destination", localDestinationURL)]
            )
            operationErrorCode = "APP-RESTORE-COPY-FAILED"
            throw error
        }
        let duration = Date().timeIntervalSince(startTime)
        AppLogger.shared.log("步骤1: 复制成功")
        AppLogger.shared.logPathState("步骤1后-本地目标[\(operationID)]", url: localDestinationURL)

        AppLogger.shared.logMigrationPerformance(
            appName: app.name,
            size: sourceSize > 0 ? sourceSize : 0,
            duration: duration,
            sourcePath: app.path.path,
            destPath: localDestinationURL.path
        )

        AppLogger.shared.log("步骤2: 解锁并删除外部存储源文件...")
        do {
            try? fileManager.setAttributes([.immutable: false], ofItemAtPath: app.path.path)
            try fileManager.removeItem(at: app.path)
            AppLogger.shared.log("步骤2: 删除成功")
            AppLogger.shared.log("===== 还原完成 =====")
            AppLogger.shared.logPathState("还原完成-本地目标[\(operationID)]", url: localDestinationURL)
            AppLogger.shared.logPathState("还原完成-外部源[\(operationID)]", url: app.path)
        } catch {
            AppLogger.shared.logError(
                "步骤2: 删除外部文件失败 (但不影响还原)",
                error: error,
                errorCode: "APP-RESTORE-EXTERNAL-CLEANUP-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("source", app.path), ("destination", localDestinationURL)]
            )
            operationResult = "success_with_warning"
            operationErrorCode = "APP-RESTORE-EXTERNAL-CLEANUP-FAILED"
        }

        if operationResult != "success_with_warning" {
            operationResult = "success"
        }
    }

    private func isIOSAppBundle(at appURL: URL) -> Bool {
        fileManager.fileExists(atPath: appURL.appendingPathComponent("WrappedBundle").path)
    }

    private func prefersWholeAppSymlink(for appURL: URL) -> Bool {
        let frameworkCandidates = [
            "Contents/Frameworks/Squirrel.framework",
            "Contents/Frameworks/Sparkle.framework"
        ]

        for relativePath in frameworkCandidates {
            if fileManager.fileExists(atPath: appURL.appendingPathComponent(relativePath).path) {
                return true
            }
        }

        let nameCandidates = ["shipit", "autoupdate", "updater", "update"]
        let searchRoots = [
            appURL.appendingPathComponent("Contents/MacOS"),
            appURL.appendingPathComponent("Contents/Frameworks")
        ]

        for root in searchRoots {
            let items = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            if items.contains(where: { item in
                let name = item.lastPathComponent.lowercased()
                return nameCandidates.contains(where: { name.contains($0) })
            }) {
                return true
            }
        }

        return false
    }

    private func preferredPortalKind(for appURL: URL) -> LocalPortalKind {
        guard appURL.pathExtension == "app" else {
            return .wholeAppSymlink
        }

        if isIOSAppBundle(at: appURL) || prefersWholeAppSymlink(for: appURL) {
            return .wholeAppSymlink
        }

        return .deepContentsWrapper
    }

    private func resolveSymlinkDestination(at url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let rawPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }

        return URL(fileURLWithPath: rawPath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    private func localPortalKind(at localURL: URL) -> LocalPortalKind? {
        if let rootDestination = resolveSymlinkDestination(at: localURL) {
            return localPortalKind(at: localURL, linkedTo: rootDestination)
        }

        let localContentsURL = localURL.appendingPathComponent("Contents")
        if let contentsDestination = resolveSymlinkDestination(at: localContentsURL) {
            return localPortalKind(at: localURL, linkedTo: contentsDestination.deletingLastPathComponent())
        }

        return nil
    }

    private func localPortalKind(at localURL: URL, linkedTo externalURL: URL) -> LocalPortalKind? {
        let standardizedExternalURL = externalURL.standardizedFileURL

        if let linkDestination = resolveSymlinkDestination(at: localURL),
           linkDestination == standardizedExternalURL {
            return .wholeAppSymlink
        }

        let localContentsURL = localURL.appendingPathComponent("Contents")
        if let contentsDestination = resolveSymlinkDestination(at: localContentsURL),
           contentsDestination == standardizedExternalURL.appendingPathComponent("Contents").standardizedFileURL {
            return .deepContentsWrapper
        }

        return nil
    }

    private func createLocalPortal(
        at localURL: URL,
        pointingTo externalURL: URL,
        portalKind: LocalPortalKind? = nil,
        operationID: String? = nil
    ) throws {
        let resolvedPortalKind = portalKind ?? preferredPortalKind(for: externalURL)
        AppLogger.shared.logContext(
            "创建本地入口",
            details: [
                ("operation_id", operationID),
                ("portal_kind", portalKindDescription(resolvedPortalKind)),
                ("local_path", localURL.path),
                ("external_path", externalURL.path)
            ],
            level: "TRACE"
        )

        switch resolvedPortalKind {
        case .wholeAppSymlink:
            try fileManager.createSymbolicLink(at: localURL, withDestinationURL: externalURL)
            AppLogger.shared.log("已创建符号链接: \(localURL.path) -> \(externalURL.path)")

        case .deepContentsWrapper:
            try fileManager.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)
            let localContentsURL = localURL.appendingPathComponent("Contents")
            let externalContentsURL = externalURL.appendingPathComponent("Contents")
            try fileManager.createSymbolicLink(at: localContentsURL, withDestinationURL: externalContentsURL)
            AppLogger.shared.log("已创建 Contents 符号链接: \(localContentsURL.path) -> \(externalContentsURL.path)")
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: localURL.path)
        }

        AppLogger.shared.logPathState("本地入口结果[\(operationID ?? "n/a")]", url: localURL, level: "TRACE")
    }

    private func buildPortal(for appToMove: AppItem, destinationURL: URL, operationID: String) throws {
        if let portalCreationOverride {
            try portalCreationOverride(appToMove, destinationURL)
            return
        }

        if appToMove.usesFolderOperation {
            AppLogger.shared.log("迁移策略: 应用文件夹 (整体符号链接)", level: "STRATEGY")
            try createLocalPortal(
                at: appToMove.path,
                pointingTo: destinationURL,
                portalKind: .wholeAppSymlink,
                operationID: operationID
            )
            return
        }

        switch preferredPortalKind(for: destinationURL) {
        case .wholeAppSymlink:
            if isIOSAppBundle(at: destinationURL) {
                AppLogger.shared.log("迁移策略: iOS 应用 (直接符号链接)", level: "STRATEGY")
            } else {
                AppLogger.shared.log("迁移策略: 自更新应用 (整体符号链接兼容模式)", level: "STRATEGY")
            }

        case .deepContentsWrapper:
            AppLogger.shared.log("迁移策略: Mac 原生应用 (Contents 深度链接)", level: "STRATEGY")
        }

        try createLocalPortal(at: appToMove.path, pointingTo: destinationURL, operationID: operationID)
    }

    private func folderPortalSnapshots(for externalFolderURL: URL, localAppsDir: URL) -> [LocalPortalSnapshot] {
        let folderContents = (try? fileManager.contentsOfDirectory(at: externalFolderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let appsInFolder = folderContents.filter { $0.pathExtension == "app" }

        return appsInFolder.compactMap { appURL in
            let localAppURL = localAppsDir.appendingPathComponent(appURL.lastPathComponent)
            guard let kind = localPortalKind(at: localAppURL, linkedTo: appURL) else { return nil }
            return LocalPortalSnapshot(localURL: localAppURL, externalURL: appURL, kind: kind)
        }
    }

    private func recreatePortals(from snapshots: [LocalPortalSnapshot], operationID: String) {
        for snapshot in snapshots {
            do {
                try createLocalPortal(
                    at: snapshot.localURL,
                    pointingTo: snapshot.externalURL,
                    portalKind: snapshot.kind,
                    operationID: operationID
                )
            } catch {
                AppLogger.shared.logError(
                    "恢复本地入口失败",
                    error: error,
                    context: [("operation_id", operationID)],
                    relatedURLs: [("local", snapshot.localURL), ("external", snapshot.externalURL)]
                )
            }
        }
    }

    private func rollbackMoveAndLink(appToMove: AppItem, destinationURL: URL, operationID: String) async throws {
        AppLogger.shared.logContext(
            "开始执行应用迁移回滚",
            details: [
                ("operation_id", operationID),
                ("app_name", appToMove.name),
                ("source_path", appToMove.path.path),
                ("destination_path", destinationURL.path),
                    ("is_folder", appToMove.usesFolderOperation ? "true" : "false")
            ],
            level: "WARN"
        )

        if fileManager.fileExists(atPath: appToMove.path.path) {
            try? fileManager.removeItem(at: appToMove.path)
        }

        let copier = FileCopier()
        try await copier.copyDirectory(from: destinationURL, to: appToMove.path, progressHandler: nil)
        try? fileManager.setAttributes([.immutable: false], ofItemAtPath: destinationURL.path)
        try fileManager.removeItem(at: destinationURL)
        AppLogger.shared.logPathState("回滚完成-本地源[\(operationID)]", url: appToMove.path, level: "WARN")
        AppLogger.shared.logPathState("回滚完成-外部目标[\(operationID)]", url: destinationURL, level: "WARN")
    }

    private func portalKindDescription(_ kind: LocalPortalKind) -> String {
        switch kind {
        case .wholeAppSymlink:
            return "whole_app_symlink"
        case .deepContentsWrapper:
            return "deep_contents_wrapper"
        }
    }
}
