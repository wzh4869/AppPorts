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
        case stubPortal
        /// 文件夹套件（appSuiteFolder / singleAppContainer）：本地为真实文件夹，
        /// 内部每个 .app 是 Stub Portal（可被 Launch Services 索引），其余文件/子目录为符号链接。
        case folderMirror
        /// 透明混合入口（原型，feature flag `transparentHybridEnabled`）：本地为真实 .app 壳，
        /// 保留 Stub 启动器（可被 Launch Services / Spotlight 索引、安全启动），
        /// 同时把 `Contents` 下我们未注入的文件/子目录以符号链接镜像到外部真实 app，
        /// 使硬编码到 `/Applications/X.app/Contents/...` 的内部路径仍可解析（需外置磁盘在线）。
        case transparentHybrid
    }

    /// Folder Mirror 标记文件名：放在本地镜像文件夹内，记录外部真实文件夹路径。
    /// 用于扫描器识别镜像文件夹状态、解析体积与还原/解链。
    static let folderPortalMarkerName = ".appports-folder-portal.plist"

    /// Transparent Hybrid 标记文件名：放在本地 .app 的 `Contents` 内，记录外部真实 app 路径。
    /// 是 restore/解链识别本类型的权威依据（须早于 legacyHybrid 等符号链接启发式判断）。
    static let hybridPortalMarkerName = ".appports-hybrid-portal.plist"

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

    // MARK: - macOS 版本检测与 Volume 路径

    /// macOS >= 15.1 支持 App Store 应用安装到外部磁盘
    static var isMASExternalInstallSupported: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion > 15 || (v.majorVersion == 15 && v.minorVersion >= 1)
    }

    /// 从用户选择的外部路径推导磁盘根目录
    /// /Volumes/hano/appdisks/ → /Volumes/hano/
    /// /Volumes/hano/          → /Volumes/hano/
    static func volumeRoot(for url: URL) -> URL {
        let components = url.standardizedFileURL.pathComponents
        // 查找 "Volumes" 后的卷名
        if let volIndex = components.firstIndex(of: "Volumes"), volIndex + 1 < components.count {
            let volumeName = components[volIndex + 1]
            return URL(fileURLWithPath: "/Volumes/\(volumeName)")
        }
        return url.standardizedFileURL
    }

    /// App Store 应用在外部磁盘的 Applications 路径
    /// /Volumes/hano/appdisks/ → /Volumes/hano/Applications/
    static func masApplicationsURL(for externalDriveURL: URL) -> URL {
        volumeRoot(for: externalDriveURL).appendingPathComponent("Applications")
    }

    static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func removeItemViaFinder(at url: URL) throws {
        let script = "tell application \"Finder\" to delete POSIX file \(appleScriptStringLiteral(url.path))"

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
                    userInfo: [NSLocalizedDescriptionKey: errorOutput.isEmpty ? "Finder 删除失败".localized : errorOutput]
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
        lockExternal: Bool = true,
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
            AppLogger.shared.log("目标位置已存在文件，检查冲突类型")
            AppLogger.shared.logPathState("迁移冲突-目标现状[\(operationID)]", url: destinationURL)

            guard let replacementReason = externalTargetReplacementReason(for: appToMove, destinationURL: destinationURL) else {
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
                        userInfo: [NSLocalizedDescriptionKey: "目标已存在真实文件".localized]
                    )
                )
            }

            AppLogger.shared.logContext(
                "允许清理外部目标后继续迁移",
                details: [
                    ("operation_id", operationID),
                    ("reason", replacementReason),
                    ("destination_path", destinationURL.path)
                ],
                level: "WARN"
            )
            unlockImmutableRecursive(at: destinationURL)
            try fileManager.removeItem(at: destinationURL)
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
                        userInfo: [NSLocalizedDescriptionKey: String(format: "创建本地入口失败，应用已自动恢复到本地：%@".localized, error.localizedDescription)]
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
                        userInfo: [NSLocalizedDescriptionKey: String(format: "创建本地入口失败，且自动回滚未完成。外部副本仍保留在：%@".localized, destinationURL.path)]
                    )
                )
            }
        }

        // Sparkle/Electron 有更新器的应用：锁定外部 app，防止 updater 删除
        // 原生自更新 app（Chrome、Edge 等）不加锁，自更新后用户重新迁移即可
        if lockExternal && needsUchgLock(at: destinationURL) {
            lockExternalApp(at: destinationURL)
        }

        // 清除外部 app 的隔离属性，避免 Gatekeeper 拦截
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-cr", destinationURL.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()
        if xattr.terminationStatus != 0 {
            AppLogger.shared.log("清除隔离属性失败（退出码 \(xattr.terminationStatus)），可能触发 Gatekeeper", level: "WARN")
        }

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

                // stub portal: 有 AppPorts launcher 的假壳
                let launcherURL = contentsURL.appendingPathComponent("MacOS/launcher")
                let isStubPortal: Bool = {
                    if !fileManager.fileExists(atPath: launcherURL.path) { return false }
                    let pathFile = contentsURL.appendingPathComponent("Resources/real_app_path.txt")
                    if let raw = try? String(contentsOf: pathFile, encoding: .utf8),
                       !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return true
                    }
                    if let script = try? String(contentsOf: launcherURL, encoding: .utf8),
                       script.contains("REAL_APP=") {
                        return true
                    }
                    return false
                }()
                if isStubPortal {
                    try fileManager.removeItem(at: destinationURL)
                } else if contentsResourceValues?.isSymbolicLink == true {
                    try fileManager.removeItem(at: destinationURL)
                } else {
                    operationErrorCode = "APP-LINK-DESTINATION-CONFLICT"
                    throw AppMoverError.generalError(
                        NSError(
                            domain: "AppMover",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "本地已存在同名真实应用".localized]
                        )
                    )
                }
            } else {
                operationErrorCode = "APP-LINK-DESTINATION-CONFLICT"
                throw AppMoverError.generalError(
                    NSError(
                        domain: "AppMover",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "本地已存在同名文件".localized]
                    )
                )
            }
        }

        let portalKind: LocalPortalKind = appToLink.usesFolderOperation ? .folderMirror : preferredPortalKind(for: appToLink.path)
        AppLogger.shared.logContext(
            "本地入口策略",
            details: [("operation_id", operationID), ("portal_kind", portalKindDescription(portalKind))]
        )

        switch portalKind {
        case .wholeAppSymlink:
            AppLogger.shared.log("链接策略: iOS 应用 (整体符号链接)", level: "STRATEGY")
        case .deepContentsWrapper:
            AppLogger.shared.log("链接策略: Mac 原生应用 (Contents 深度链接)", level: "STRATEGY")
        case .stubPortal:
            AppLogger.shared.log("链接策略: Stub 启动器 (极小壳 + 外部真实 app，无箭头)", level: "STRATEGY")
        case .folderMirror:
            AppLogger.shared.log("链接策略: 文件夹镜像 (内部 app 为 Stub，其余符号链接)", level: "STRATEGY")
        case .transparentHybrid:
            AppLogger.shared.log("链接策略: 透明混合入口 (真实 .app 壳 + 内部符号链接镜像)", level: "STRATEGY")
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
                    userInfo: [NSLocalizedDescriptionKey: "尝试删除非链接文件".localized]
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

            if let existingPortalKind {
                try fileManager.removeItem(at: localDestinationURL)
                AppLogger.shared.log("已清理本地 AppPorts 入口: \(portalKindDescription(existingPortalKind))")
            } else if resolveSymlinkDestination(at: localDestinationURL) != nil {
                let error = NSError(
                    domain: "AppMover",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "本地入口并未指向当前外部应用，无法自动覆盖".localized]
                )
                operationErrorCode = "APP-RESTORE-LOCAL-CONFLICT"
                AppLogger.shared.logError("还原失败", error: error, errorCode: operationErrorCode)
                throw AppMoverError.generalError(error)
            } else {
                let resourceValues = try? localDestinationURL.resourceValues(forKeys: [.isDirectoryKey])
                let descriptionKey = (resourceValues?.isDirectory == true)
                    ? "本地已存在同名真实文件，无法覆盖".localized
                    : "本地已存在同名文件，无法覆盖".localized
                let error = NSError(domain: "AppMover", code: 6, userInfo: [NSLocalizedDescriptionKey: descriptionKey])
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

        // 解锁外部 app（uchg），以便复制和删除
        let unlockSuccess = unlockExternalApp(at: app.path)
        if !unlockSuccess {
            AppLogger.shared.log("外部 app 解锁未完全成功，后续复制/删除可能受影响", level: "WARN")
        }

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

    /// 递归解除目录及其内容的 immutable 标志（旧迁移会锁定外部副本）
    private func unlockImmutableRecursive(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = ["-R", "nouchg", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// 锁定外部 app（uchg），防止自更新应用的 updater 删除
    func lockExternalApp(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = ["-R", "uchg", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                AppLogger.shared.log("已锁定外部 app（uchg）: \(url.path)")
            } else {
                AppLogger.shared.log("锁定外部 app 失败（退出码 \(process.terminationStatus)）", level: "WARN")
            }
        } catch {
            AppLogger.shared.logError("锁定外部 app 进程启动失败", error: error)
        }
    }

    /// 解锁外部 app（nouchg），用于迁回前
    @discardableResult
    func unlockExternalApp(at url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = ["-R", "nouchg", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                AppLogger.shared.log("已解锁外部 app（nouchg）: \(url.path)")
                return true
            } else {
                AppLogger.shared.log("解锁外部 app 失败（退出码 \(process.terminationStatus)）", level: "WARN")
                return false
            }
        } catch {
            AppLogger.shared.logError("解锁外部 app 进程启动失败", error: error)
            return false
        }
    }

    /// Ad-hoc 重签名 app bundle（混合方案复制文件后签名失效，需要重新签名）
    /// 只做 shallow 签名（不穿透符号链接），避免破坏外部存储上的原始签名
    private func resignAppBundle(at appURL: URL) {
        // 先清理扩展属性
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-cr", appURL.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        // Ad-hoc shallow 签名（不使用 --deep，避免穿透 Frameworks 符号链接）
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", appURL.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try? codesign.run()
        codesign.waitUntilExit()

        if codesign.terminationStatus == 0 {
            AppLogger.shared.log("混合入口已 shallow 签名")
        } else {
            AppLogger.shared.log("混合入口签名失败（非致命）", level: "WARN")
        }
    }

    private func preferredPortalKind(for appURL: URL) -> LocalPortalKind {
        guard appURL.pathExtension == "app" else {
            return .wholeAppSymlink
        }

        // 原型：透明混合入口（feature flag）。让 .app/Contents/... 的硬编码内部路径可解析。
        // iOS 应用（Wrapper/WrappedBundle）不支持，回退到 Stub。
        if transparentHybridEnabled, !isIOSWrappedApp(at: appURL) {
            return .transparentHybrid
        }

        // 所有 .app 应用统一使用 stubPortal（无角标，安全）
        // iOS 应用使用专用的 iOS stub（从 iTunesMetadata.plist 生成 Info.plist，提取 AppIcon）
        return .stubPortal
    }

    /// 原型开关：透明混合入口。默认关闭，可用
    /// `defaults write com.shimoko.AppPorts transparentHybridEnabled -bool YES` 开启。
    private var transparentHybridEnabled: Bool {
        UserDefaults.standard.bool(forKey: "transparentHybridEnabled")
    }

    /// 是否为 iOS-on-Mac 应用（含 `Wrapper/` 或 `WrappedBundle/`）。
    private func isIOSWrappedApp(at appURL: URL) -> Bool {
        fileManager.fileExists(atPath: appURL.appendingPathComponent("Wrapper").path)
            || fileManager.fileExists(atPath: appURL.appendingPathComponent("WrappedBundle").path)
    }

    /// 检测应用是否有自更新能力
    func hasSelfUpdater(at appURL: URL) -> Bool {
        return isSparkleApp(at: appURL)
            || (isElectronApp(at: appURL) && hasElectronUpdater(at: appURL))
            || hasCustomUpdater(at: appURL)
    }

    /// 是否需要 uchg 锁定（仅 Sparkle/Electron 有更新器的应用，原生自更新 app 不锁定）
    private func needsUchgLock(at appURL: URL) -> Bool {
        return isSparkleApp(at: appURL)
            || (isElectronApp(at: appURL) && hasElectronUpdater(at: appURL))
    }

    /// 检测 Electron 应用是否有 electron-updater
    private func hasElectronUpdater(at appURL: URL) -> Bool {
        fileManager.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/app-update.yml").path)
    }

    /// 检测是否有自定义更新机制（非 Sparkle、非 Electron）
    private func hasCustomUpdater(at appURL: URL) -> Bool {
        let contents = appURL.appendingPathComponent("Contents")

        // 1. LaunchServices 特权助手（Chrome、Edge、Thunderbird 等）
        let launchServices = contents.appendingPathComponent("Library/LaunchServices")
        if let items = try? fileManager.contentsOfDirectory(at: launchServices, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            if items.contains(where: { $0.lastPathComponent.lowercased().contains("update") }) {
                return true
            }
        }

        // 2. MacOS/ 下的更新二进制（Parallels、Thunderbird 等）
        let macOS = contents.appendingPathComponent("MacOS")
        if let items = try? fileManager.contentsOfDirectory(at: macOS, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            if items.contains(where: {
                let name = $0.lastPathComponent.lowercased()
                return (name.contains("update") || name.contains("upgrade")) && !name.contains("electron")
            }) {
                return true
            }
        }

        // 3. SharedSupport/ 更新工具（wpsoffice 等）
        let sharedSupport = contents.appendingPathComponent("SharedSupport")
        if let items = try? fileManager.contentsOfDirectory(at: sharedSupport, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            if items.contains(where: { $0.lastPathComponent.lowercased().contains("update") }) {
                return true
            }
        }

        // 4. Keystone plist 键（Google Chrome）
        if let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
           plist["KSProductID"] != nil {
            return true
        }

        return false
    }

    /// 检测是否为 Electron 应用
    /// 检查：Electron Framework.framework、Electron Helper 进程、package.json
    private func isElectronApp(at appURL: URL) -> Bool {
        // 检查 Electron Framework
        if fileManager.fileExists(atPath: appURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            return true
        }
        // 检查 Electron Helper 变体
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks")
        if let items = try? fileManager.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items where item.lastPathComponent.contains("Electron Helper") {
                return true
            }
        }
        // 检查 Electron 特有的 Info.plist 键
        if let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
           plist["ElectronDefaultApp"] != nil || plist["electron"] != nil {
            return true
        }
        return false
    }

    /// 检测是否为自更新应用（Sparkle、Squirrel 或其他更新机制）
    /// 检查：框架、更新二进制、Info.plist 更新配置键
    private func isSparkleApp(at appURL: URL) -> Bool {
        // 检查 Sparkle/Squirrel 框架
        let frameworkCandidates = [
            "Contents/Frameworks/Sparkle.framework",
            "Contents/Frameworks/Squirrel.framework"
        ]
        for relativePath in frameworkCandidates {
            if fileManager.fileExists(atPath: appURL.appendingPathComponent(relativePath).path) {
                return true
            }
        }

        // 检查更新二进制文件（在 MacOS/ 和 Frameworks/ 中）
        // 跳过 Electron 应用，避免 electron-updater 的 "updater" 二进制误判
        if !isElectronApp(at: appURL) {
            let updaterNames = ["shipit", "autoupdate", "updater", "update"]
            let searchRoots = [
                appURL.appendingPathComponent("Contents/MacOS"),
                appURL.appendingPathComponent("Contents/Frameworks")
            ]
            for root in searchRoots {
                let items = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                if items.contains(where: { item in
                    let name = item.lastPathComponent.lowercased()
                    return updaterNames.contains(where: { name.contains($0) })
                }) {
                    return true
                }
            }
        }

        // 检查 Info.plist 中的 Sparkle 更新配置键
        if let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) {
            let sparkleKeys = ["SUFeedURL", "SUPublicDSAKeyFile", "SUPublicEDKey", "SUScheduledCheckInterval", "SUAllowsAutomaticUpdates"]
            for key in sparkleKeys {
                if plist[key] != nil {
                    return true
                }
            }
        }

        return false
    }

    private func resolveSymlinkDestination(at url: URL) -> URL? {
        guard let rawPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }

        return URL(fileURLWithPath: rawPath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    private func externalTargetReplacementReason(for appToMove: AppItem, destinationURL: URL) -> String? {
        if appToMove.status == AppStatus.pendingMoveOut {
            return "pending_move_out"
        }

        guard let portalKind = localPortalKind(at: destinationURL) else {
            return nil
        }

        switch portalKind {
        case .stubPortal:
            return "appports_stub_portal"
        case .deepContentsWrapper:
            return "appports_legacy_portal"
        case .wholeAppSymlink:
            return "appports_whole_app_symlink"
        case .folderMirror:
            return "appports_folder_mirror"
        case .transparentHybrid:
            return "appports_transparent_hybrid"
        }
    }

    private func localPortalKind(at localURL: URL) -> LocalPortalKind? {
        if let rootDestination = resolveSymlinkDestination(at: localURL) {
            return localPortalKind(at: localURL, linkedTo: rootDestination)
        }

        let localContentsURL = localURL.appendingPathComponent("Contents")
        if let contentsDestination = resolveSymlinkDestination(at: localContentsURL) {
            return localPortalKind(at: localURL, linkedTo: contentsDestination.deletingLastPathComponent())
        }

        // Transparent Hybrid：Contents 内标记文件（须早于 legacyHybrid 检测——本类型
        // 的 Contents 内含 Frameworks 等符号链接，否则会被 legacyHybrid 误判为 wholeAppSymlink）
        if fileManager.fileExists(atPath: localContentsURL.appendingPathComponent(Self.hybridPortalMarkerName).path) {
            return .transparentHybrid
        }

        // 旧 sparkleHybrid/electronHybrid portal 检测（向后兼容，映射为 wholeAppSymlink）
        if legacyHybridSymlinkComponent(in: localContentsURL) != nil {
            return .wholeAppSymlink
        }

        // Stub Portal：验证 launcher 是 AppPorts stub（real_app_path.txt 或 bash REAL_APP=）
        let launcherPath = localContentsURL.appendingPathComponent("MacOS/launcher")
        if fileManager.fileExists(atPath: launcherPath.path) {
            let pathFile = localContentsURL.appendingPathComponent("Resources/real_app_path.txt")
            if let raw = try? String(contentsOf: pathFile, encoding: .utf8),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .stubPortal
            }
            if let script = try? String(contentsOf: launcherPath, encoding: .utf8),
               script.contains("REAL_APP=") {
                return .stubPortal
            }
        }

        // Folder Mirror：真实文件夹 + 标记文件
        if fileManager.fileExists(atPath: localURL.appendingPathComponent(Self.folderPortalMarkerName).path) {
            return .folderMirror
        }

        return nil
    }

    private func localPortalKind(at localURL: URL, linkedTo externalURL: URL) -> LocalPortalKind? {
        let standardizedExternalURL = externalURL.standardizedFileURL

        // Folder Mirror：真实文件夹 + 标记文件（标记是套件入口的权威标识，优先识别）
        if fileManager.fileExists(atPath: localURL.appendingPathComponent(Self.folderPortalMarkerName).path) {
            return .folderMirror
        }

        if let linkDestination = resolveSymlinkDestination(at: localURL),
           linkDestination == standardizedExternalURL {
            return .wholeAppSymlink
        }

        let localContentsURL = localURL.appendingPathComponent("Contents")
        if let contentsDestination = resolveSymlinkDestination(at: localContentsURL),
           contentsDestination == standardizedExternalURL.appendingPathComponent("Contents").standardizedFileURL {
            return .deepContentsWrapper
        }

        // Transparent Hybrid：Contents 内标记文件，记录的外部路径匹配即视为本类型
        // （须早于 legacyHybrid 检测，避免内部 Frameworks 符号链接被误判为 wholeAppSymlink）
        if fileManager.fileExists(atPath: localContentsURL.appendingPathComponent(Self.hybridPortalMarkerName).path),
           let recorded = Self.hybridPortalExternalURL(at: localURL, fileManager: fileManager),
           recorded == standardizedExternalURL {
            return .transparentHybrid
        }

        // 旧 sparkleHybrid/electronHybrid 入口检测（向后兼容）
        if legacyHybridSymlinkComponent(in: localContentsURL, linkedTo: standardizedExternalURL) != nil {
            return .wholeAppSymlink
        }

        // Stub Portal：检查 launcher 是否指向目标外部 app
        let launcherPath = localContentsURL.appendingPathComponent("MacOS/launcher")
        if fileManager.fileExists(atPath: launcherPath.path) {
            // 原生 launcher：从 real_app_path.txt 读取
            let pathFile = localContentsURL.appendingPathComponent("Resources/real_app_path.txt")
            if let raw = try? String(contentsOf: pathFile, encoding: .utf8) {
                let realPath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !realPath.isEmpty && realPath == standardizedExternalURL.path {
                    return .stubPortal
                }
            }
            // 旧版 bash launcher：检查脚本内容
            if let script = try? String(contentsOf: launcherPath, encoding: .utf8),
               script.contains(standardizedExternalURL.path) {
                return .stubPortal
            }
        }

        return nil
    }

    private func legacyHybridSymlinkComponent(in contentsURL: URL) -> String? {
        for relativePath in legacyHybridRelativePaths {
            if resolveSymlinkDestination(at: contentsURL.appendingPathComponent(relativePath)) != nil {
                return relativePath
            }
        }
        return nil
    }

    private func legacyHybridSymlinkComponent(in contentsURL: URL, linkedTo externalURL: URL) -> String? {
        let externalContentsURL = externalURL.appendingPathComponent("Contents").standardizedFileURL
        for relativePath in legacyHybridRelativePaths {
            let componentURL = contentsURL.appendingPathComponent(relativePath)
            let expectedURL = externalContentsURL.appendingPathComponent(relativePath).standardizedFileURL
            if let destination = resolveSymlinkDestination(at: componentURL),
               destination == expectedURL {
                return relativePath
            }
        }
        return nil
    }

    private var legacyHybridRelativePaths: [String] {
        ["Info.plist", "MacOS", "Resources", "Frameworks"]
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

        case .stubPortal:
            try createStubPortal(at: localURL, pointingTo: externalURL)

        case .folderMirror:
            try createFolderMirrorPortal(at: localURL, pointingTo: externalURL)

        case .transparentHybrid:
            try createTransparentHybridPortal(at: localURL, pointingTo: externalURL)
        }

        AppLogger.shared.logPathState("本地入口结果[\(operationID ?? "n/a")]", url: localURL, level: "TRACE")
    }

    /// 创建 Folder Mirror：本地真实文件夹，逐项镜像外部套件文件夹。
    ///
    /// - 内部每个 `.app` → Stub Portal（真实 .app 壳，可被 Launch Services / Spotlight 索引）
    /// - 其余文件/子目录（PDF、文档目录等）→ 指向外部的符号链接（不占空间，无需索引）
    /// - 写入隐藏标记 `.appports-folder-portal.plist` 记录外部路径，供扫描/还原/解链识别
    ///
    /// 单个 `.app` 的 stub 创建失败时回退为整体符号链接，保证整套迁移不因个别项失败而中断。
    private func createFolderMirrorPortal(at localFolderURL: URL, pointingTo externalFolderURL: URL) throws {
        let fm = fileManager

        // 确保是一个全新的真实目录（覆盖残留的旧入口）
        if fm.fileExists(atPath: localFolderURL.path) {
            unlockImmutableRecursive(at: localFolderURL)
            try fm.removeItem(at: localFolderURL)
        }
        try fm.createDirectory(at: localFolderURL, withIntermediateDirectories: true, attributes: nil)

        let entries = (try? fm.contentsOfDirectory(
            at: externalFolderURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []

        var stubCount = 0
        var linkCount = 0
        for entry in entries {
            let localEntry = localFolderURL.appendingPathComponent(entry.lastPathComponent)
            if entry.pathExtension == "app" {
                do {
                    try createStubPortal(at: localEntry, pointingTo: entry)
                    stubCount += 1
                } catch {
                    AppLogger.shared.logError(
                        "Folder Mirror：创建内部 Stub 失败，回退为符号链接",
                        error: error,
                        errorCode: "FOLDER-MIRROR-STUB-FAILED",
                        relatedURLs: [("local", localEntry), ("external", entry)]
                    )
                    try? fm.removeItem(at: localEntry)
                    try fm.createSymbolicLink(at: localEntry, withDestinationURL: entry)
                    linkCount += 1
                }
            } else {
                try fm.createSymbolicLink(at: localEntry, withDestinationURL: entry)
                linkCount += 1
            }
        }

        try writeFolderPortalMarker(in: localFolderURL, externalFolderURL: externalFolderURL)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: localFolderURL.path)

        AppLogger.shared.log(
            "已创建 Folder Mirror: \(localFolderURL.lastPathComponent) (stubs=\(stubCount), links=\(linkCount)) -> \(externalFolderURL.path)"
        )
        refreshLaunchServicesRecursive(for: localFolderURL)
    }

    /// 写入 Folder Mirror 标记文件。
    private func writeFolderPortalMarker(in localFolderURL: URL, externalFolderURL: URL) throws {
        let marker: [String: Any] = [
            "externalPath": externalFolderURL.standardizedFileURL.path,
            "createdBy": "AppPorts",
            "kind": "folderMirror",
            "version": 1
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: marker, format: .xml, options: 0)
        try data.write(to: localFolderURL.appendingPathComponent(Self.folderPortalMarkerName))
    }

    /// 若本地文件夹是 Folder Mirror（含标记文件），返回其记录的外部真实文件夹路径。
    func folderMirrorExternalURL(at localFolderURL: URL) -> URL? {
        Self.folderMirrorExternalURL(at: localFolderURL, fileManager: fileManager)
    }

    /// 读取 Folder Mirror 标记中的外部路径（静态版，供扫描器等无实例场景复用）。
    static func folderMirrorExternalURL(at localFolderURL: URL, fileManager: FileManager = .default) -> URL? {
        let markerURL = localFolderURL.appendingPathComponent(folderPortalMarkerName)
        guard fileManager.fileExists(atPath: markerURL.path),
              let data = try? Data(contentsOf: markerURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = dict["externalPath"] as? String,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// 写入 Transparent Hybrid 标记文件（位于本地 .app 的 `Contents` 内）。
    private func writeHybridPortalMarker(in localContentsURL: URL, externalURL: URL) throws {
        let marker: [String: Any] = [
            "externalPath": externalURL.standardizedFileURL.path,
            "createdBy": "AppPorts",
            "kind": "transparentHybrid",
            "version": 1
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: marker, format: .xml, options: 0)
        try data.write(to: localContentsURL.appendingPathComponent(Self.hybridPortalMarkerName))
    }

    /// 读取 Transparent Hybrid 标记中的外部路径（静态版，供扫描器等无实例场景复用）。
    static func hybridPortalExternalURL(at localAppURL: URL, fileManager: FileManager = .default) -> URL? {
        let markerURL = localAppURL
            .appendingPathComponent("Contents")
            .appendingPathComponent(hybridPortalMarkerName)
        guard fileManager.fileExists(atPath: markerURL.path),
              let data = try? Data(contentsOf: markerURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = dict["externalPath"] as? String,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// 重新同步 Folder Mirror，使本地镜像与外部套件文件夹保持一致。
    ///
    /// 在 rescan 时调用（外部套件被 App Store / 自更新器更新后内容可能变化）：
    /// - 现有内部 Stub → 调用 `refreshStubPortal` 同步版本/图标
    /// - 外部新增的 `.app` → 新建 Stub；新增的其他文件/目录 → 新建符号链接
    /// - 本地多余的项（外部已删除）→ 移除
    /// 仅对带标记文件的真实镜像文件夹生效，旧版整体符号链接文件夹会被安全跳过。
    func refreshFolderMirror(at localFolderURL: URL, from externalFolderURL: URL) {
        let fm = fileManager

        // 仅处理 AppPorts 镜像文件夹（标记存在），其余（旧 symlink 文件夹、用户真实文件夹）跳过
        let markerURL = localFolderURL.appendingPathComponent(Self.folderPortalMarkerName)
        guard fm.fileExists(atPath: markerURL.path),
              let externalEntries = try? fm.contentsOfDirectory(
                  at: externalFolderURL,
                  includingPropertiesForKeys: nil,
                  options: .skipsHiddenFiles
              ) else {
            return
        }

        let externalNames = Set(externalEntries.map { $0.lastPathComponent })
        var didChange = false

        // 1. 新增 / 刷新外部存在的条目
        for entry in externalEntries {
            let localEntry = localFolderURL.appendingPathComponent(entry.lastPathComponent)
            if entry.pathExtension == "app" {
                if fm.fileExists(atPath: localEntry.path),
                   localPortalKind(at: localEntry, linkedTo: entry) == .stubPortal {
                    // 现有内部 Stub：同步版本/图标
                    refreshStubPortal(at: localEntry, from: entry)
                } else {
                    // 外部新增 app（或本地缺失/损坏）：重建 Stub
                    try? fm.removeItem(at: localEntry)
                    do {
                        try createStubPortal(at: localEntry, pointingTo: entry)
                        didChange = true
                    } catch {
                        try? fm.createSymbolicLink(at: localEntry, withDestinationURL: entry)
                        didChange = true
                    }
                }
            } else {
                // 非 app：确保符号链接存在且指向当前外部条目
                let needsLink: Bool
                if let dest = resolveSymlinkDestination(at: localEntry) {
                    needsLink = dest != entry.standardizedFileURL
                } else {
                    needsLink = !fm.fileExists(atPath: localEntry.path)
                }
                if needsLink {
                    try? fm.removeItem(at: localEntry)
                    try? fm.createSymbolicLink(at: localEntry, withDestinationURL: entry)
                    didChange = true
                }
            }
        }

        // 2. 移除外部已不存在的本地条目（标记与隐藏文件因 skipsHiddenFiles 不被遍历，自动保留）
        if let localEntries = try? fm.contentsOfDirectory(
            at: localFolderURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            for localEntry in localEntries where !externalNames.contains(localEntry.lastPathComponent) {
                try? fm.removeItem(at: localEntry)
                didChange = true
            }
        }

        if didChange {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: localFolderURL.path)
            refreshLaunchServicesRecursive(for: localFolderURL)
            AppLogger.shared.log("已同步 Folder Mirror: \(localFolderURL.lastPathComponent) -> \(externalFolderURL.path)")
        }
    }

    /// 创建 Stub Portal：极小的假 .app，含 launcher 脚本启动外部真实 app
    private func createStubPortal(at localURL: URL, pointingTo externalURL: URL) throws {
        let fm = fileManager

        // 检测是否为 iOS 应用（有 Wrapper/ 或 WrappedBundle/ 目录）
        let wrapperDir = externalURL.appendingPathComponent("Wrapper")
        let wrappedBundleDir = externalURL.appendingPathComponent("WrappedBundle")
        let isIOSApp = fm.fileExists(atPath: wrapperDir.path) || fm.fileExists(atPath: wrappedBundleDir.path)

        if isIOSApp {
            try createIOSStubPortal(at: localURL, pointingTo: externalURL)
        } else {
            try createMacOSStubPortal(at: localURL, pointingTo: externalURL)
        }
    }

    /// iOS 应用的 Stub Portal
    private func createIOSStubPortal(at localURL: URL, pointingTo externalURL: URL) throws {
        let fm = fileManager
        let localContents = localURL.appendingPathComponent("Contents")
        let localMacOS = localContents.appendingPathComponent("MacOS")
        let localResources = localContents.appendingPathComponent("Resources")

        // 1. 创建目录结构
        try fm.createDirectory(at: localMacOS, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: localResources, withIntermediateDirectories: true, attributes: nil)

        // 2. 写入 launcher 脚本
        try writeBashLauncher(at: localMacOS, externalURL: externalURL)

        // 3. 从 iOS app 内部提取图标并转换为 .icns
        let wrapperDir = fm.fileExists(atPath: externalURL.appendingPathComponent("Wrapper").path)
            ? externalURL.appendingPathComponent("Wrapper")
            : externalURL.appendingPathComponent("WrappedBundle")
        if let innerAppURL = try? fm.contentsOfDirectory(at: wrapperDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
           let appURL = innerAppURL.first(where: { $0.pathExtension == "app" }) {
            try extractIOSIcon(from: appURL, to: localResources)
        }

        // 4. 从 iTunesMetadata.plist 生成 Info.plist（位于 Wrapper/ 目录内）
        let iTunesPlist = wrapperDir.appendingPathComponent("iTunesMetadata.plist")
        if let metadata = NSDictionary(contentsOf: iTunesPlist) as? [String: Any] {
            let bundleID = metadata["softwareVersionBundleId"] as? String ?? "com.appports.stub"
            let appName = metadata["title"] as? String ?? localURL.deletingPathExtension().lastPathComponent
            let version = metadata["bundleShortVersionString"] as? String ?? "1.0"

            let plist: [String: Any] = [
                "CFBundleExecutable": "launcher",
                "CFBundleIdentifier": "\(bundleID).appports.stub",
                "CFBundleName": appName,
                "CFBundleDisplayName": appName,
                "CFBundleShortVersionString": version,
                "LSUIElement": true,  // 后台运行，不在 Dock 显示图标
                "CFBundleVersion": version,
                "CFBundlePackageType": "APPL",
                "CFBundleIconFile": "AppIcon",
                "LSMinimumSystemVersion": "12.0"
            ]
            if let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try newData.write(to: localContents.appendingPathComponent("Info.plist"))
            }
        }

        // 5. 写入 PkgInfo
        try "APPL????".write(to: localContents.appendingPathComponent("PkgInfo"), atomically: true, encoding: .utf8)

        // 6. 清除隔离属性（iOS stub 不需要代码签名，shell script 无法被 codesign 处理）
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-cr", localURL.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        AppLogger.shared.log("已创建 iOS Stub Portal: \(localURL.lastPathComponent) -> \(externalURL.path)")
    }

    /// macOS 应用的 Stub Portal
    private func createMacOSStubPortal(at localURL: URL, pointingTo externalURL: URL) throws {
        let fm = fileManager
        let localContents = localURL.appendingPathComponent("Contents")
        let localMacOS = localContents.appendingPathComponent("MacOS")
        let externalContents = externalURL.appendingPathComponent("Contents")
        let externalResources = externalContents.appendingPathComponent("Resources")

        // 1. 创建目录结构
        try fm.createDirectory(at: localMacOS, withIntermediateDirectories: true, attributes: nil)

        // 2. 复制原生 launcher 二进制
        let localResources = localContents.appendingPathComponent("Resources")
        try fm.createDirectory(at: localResources, withIntermediateDirectories: true, attributes: nil)
        try copyNativeLauncher(to: localMacOS, resourcesDir: localResources, externalURL: externalURL)

        // 3. 复制 PkgInfo
        let externalPkgInfo = externalContents.appendingPathComponent("PkgInfo")
        if fm.fileExists(atPath: externalPkgInfo.path) {
            try fm.copyItem(at: externalPkgInfo, to: localContents.appendingPathComponent("PkgInfo"))
        }

        // 4. 仅复制图标文件
        if let plistData = try? Data(contentsOf: externalContents.appendingPathComponent("Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
           let iconName = plist["CFBundleIconFile"] as? String {
            let iconNameURL = URL(fileURLWithPath: iconName)
            let iconExt = iconNameURL.pathExtension.isEmpty ? "icns" : iconNameURL.pathExtension
            let iconBase = iconNameURL.pathExtension.isEmpty ? iconName : iconNameURL.deletingPathExtension().lastPathComponent
            let externalIcon = externalResources.appendingPathComponent("\(iconBase).\(iconExt)")
            if fm.fileExists(atPath: externalIcon.path) {
                try fm.copyItem(at: externalIcon, to: localResources.appendingPathComponent("\(iconBase).\(iconExt)"))
            }
        }

        // 5. 生成 Info.plist
        let externalInfoPlist = externalContents.appendingPathComponent("Info.plist")
        if let plistData = try? Data(contentsOf: externalInfoPlist),
           var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
            plist["CFBundleExecutable"] = "launcher"
            plist["LSUIElement"] = true  // 后台运行，不在 Dock 显示图标
            if let bundleID = plist["CFBundleIdentifier"] as? String {
                plist["CFBundleIdentifier"] = "\(bundleID).appports.stub"
            }
            let updateKeys = ["SUFeedURL", "SUPublicDSAKeyFile", "SUPublicEDKey",
                              "SUScheduledCheckInterval", "SUAllowsAutomaticUpdates",
                              "ElectronDefaultApp", "electron"]
            for key in updateKeys { plist.removeValue(forKey: key) }

            if let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try newData.write(to: localContents.appendingPathComponent("Info.plist"))
            }
        }

        // 6. Ad-hoc 签名
        resignAppBundle(at: localURL)

        AppLogger.shared.log("已创建 macOS Stub Portal: \(localURL.lastPathComponent) -> \(externalURL.path)")
    }

    /// 创建透明混合入口（Transparent Hybrid，原型）。
    ///
    /// 本地为真实 .app 壳：保留 Stub 启动器（`Contents/MacOS/launcher` + `Resources/real_app_path.txt`），
    /// 因此可被 Launch Services / Spotlight 索引、双击经启动器打开外部真实 app、外置磁盘缺失时弹提示；
    /// 同时把 `Contents` 下未被我们注入的文件/子目录以符号链接镜像到外部真实 app，
    /// 使硬编码到 `/Applications/X.app/Contents/...` 的内部路径仍可解析（需外置磁盘在线）。
    ///
    /// 镜像遵循"只在含我们文件的分支下建真实目录，其余整棵子树用符号链接"：
    /// - `Contents` 顶层：除注入项（Info.plist/PkgInfo/MacOS/Resources/_CodeSignature/标记）外，逐项符号链接
    /// - `Contents/MacOS`、`Contents/Resources`：保留我们的真实文件，其余子项逐项符号链接（不再深入）
    private func createTransparentHybridPortal(at localURL: URL, pointingTo externalURL: URL) throws {
        let fm = fileManager

        // iOS 应用（Wrapper/WrappedBundle）不支持透明混合，回退为常规 Stub
        if isIOSWrappedApp(at: externalURL) {
            AppLogger.shared.log("透明混合入口不支持 iOS 应用，回退为 Stub Portal", level: "WARN")
            try createStubPortal(at: localURL, pointingTo: externalURL)
            return
        }

        // 1. 先建立 Stub "脊柱"（Info.plist / PkgInfo / MacOS/launcher / Resources/real_app_path.txt + 图标 + 签名）
        try createMacOSStubPortal(at: localURL, pointingTo: externalURL)

        let localContents = localURL.appendingPathComponent("Contents")
        let externalContents = externalURL.appendingPathComponent("Contents")

        // 2. Contents 顶层：镜像我们未注入的条目为符号链接（整棵子树，不深入）。
        //    _CodeSignature 由本地重新签名生成，绝不可符号链接到外部（否则签名会写穿到外部 app）。
        let injectedTopLevel: Set<String> = [
            "Info.plist", "PkgInfo", "MacOS", "Resources", "_CodeSignature", Self.hybridPortalMarkerName
        ]
        if let externalTop = try? fm.contentsOfDirectory(at: externalContents, includingPropertiesForKeys: nil, options: []) {
            for entry in externalTop {
                let name = entry.lastPathComponent
                if injectedTopLevel.contains(name) { continue }
                let localEntry = localContents.appendingPathComponent(name)
                if fm.fileExists(atPath: localEntry.path) { continue }  // 不覆盖既有真实项，避免与我们的数据相交
                try fm.createSymbolicLink(at: localEntry, withDestinationURL: entry)
            }
        }

        // 3. MacOS / Resources：保留我们的真实文件，其余子项逐项符号链接（只深入这一层）
        mirrorChildrenAsSymlinks(
            localDir: localContents.appendingPathComponent("MacOS"),
            externalDir: externalContents.appendingPathComponent("MacOS")
        )
        mirrorChildrenAsSymlinks(
            localDir: localContents.appendingPathComponent("Resources"),
            externalDir: externalContents.appendingPathComponent("Resources")
        )

        // 4. 写入标记文件（restore/scan 识别本类型的权威依据，须在重新签名前写入）
        try writeHybridPortalMarker(in: localContents, externalURL: externalURL)

        // 5. 重新 ad-hoc shallow 签名（覆盖脊柱签名，纳入新增符号链接与标记；shallow 不穿透 Frameworks 符号链接）
        resignAppBundle(at: localURL)

        refreshLaunchServices(for: localURL)
        AppLogger.shared.log("已创建 Transparent Hybrid Portal: \(localURL.lastPathComponent) -> \(externalURL.path)")
    }

    /// 将 `externalDir` 下我们尚未注入的子项，逐个在 `localDir` 内创建符号链接（不递归深入）。
    /// `localDir` 内已存在的真实文件（如 launcher / real_app_path.txt / 图标）优先保留，避免与我们的数据相交。
    private func mirrorChildrenAsSymlinks(localDir: URL, externalDir: URL) {
        let fm = fileManager
        guard let children = try? fm.contentsOfDirectory(at: externalDir, includingPropertiesForKeys: nil, options: []) else {
            return
        }
        for child in children {
            let localChild = localDir.appendingPathComponent(child.lastPathComponent)
            if fm.fileExists(atPath: localChild.path) { continue }
            do {
                try fm.createSymbolicLink(at: localChild, withDestinationURL: child)
            } catch {
                AppLogger.shared.logError(
                    "Transparent Hybrid: 符号链接创建失败",
                    error: error,
                    errorCode: "HYBRID-SYMLINK-FAILED",
                    relatedURLs: [("local", localChild), ("external", child)]
                )
            }
        }
    }

    /// 刷新 Stub Portal 的 Info.plist 和图标（同步外置 app 的版本等元数据）
    ///
    /// 当外置 app 更新后，FolderMonitor 触发 rescan 时调用。
    /// 对比本地 Stub Portal 与外置 app 的版本号，如有变化则更新 plist、图标并刷新 Launch Services。
    func refreshStubPortal(at localURL: URL, from externalURL: URL) {
        let fm = fileManager
        let localContents = localURL.appendingPathComponent("Contents")
        let externalContents = externalURL.appendingPathComponent("Contents")
        let localInfoPlist = localContents.appendingPathComponent("Info.plist")
        let externalInfoPlist = externalContents.appendingPathComponent("Info.plist")

        // 读取外置 app 的 Info.plist
        guard let extData = try? Data(contentsOf: externalInfoPlist),
              var extPlist = try? PropertyListSerialization.propertyList(from: extData, format: nil) as? [String: Any] else {
            return
        }

        // 读取本地 Stub Portal 的 Info.plist
        guard let localData = try? Data(contentsOf: localInfoPlist),
              let localPlist = try? PropertyListSerialization.propertyList(from: localData, format: nil) as? [String: Any] else {
            return
        }

        // 对比版本号
        let localVersion = localPlist["CFBundleShortVersionString"] as? String
        let externalVersion = extPlist["CFBundleShortVersionString"] as? String
        let localBuild = localPlist["CFBundleVersion"] as? String
        let externalBuild = extPlist["CFBundleVersion"] as? String

        guard localVersion != externalVersion || localBuild != externalBuild else { return }

        AppLogger.shared.logContext(
            "Stub Portal 版本变化，刷新中",
            details: [
                ("app", localURL.lastPathComponent),
                ("old_version", localVersion ?? "nil"),
                ("new_version", externalVersion ?? "nil"),
                ("old_build", localBuild ?? "nil"),
                ("new_build", externalBuild ?? "nil")
            ]
        )

        // 用外置 app 的 plist 重新生成 Stub Portal 的 plist（与 createMacOSStubPortal 相同逻辑）
        extPlist["CFBundleExecutable"] = "launcher"
        extPlist["LSUIElement"] = true
        if let bundleID = extPlist["CFBundleIdentifier"] as? String {
            extPlist["CFBundleIdentifier"] = "\(bundleID).appports.stub"
        }
        let updateKeys = ["SUFeedURL", "SUPublicDSAKeyFile", "SUPublicEDKey",
                          "SUScheduledCheckInterval", "SUAllowsAutomaticUpdates",
                          "ElectronDefaultApp", "electron"]
        for key in updateKeys { extPlist.removeValue(forKey: key) }

        if let newData = try? PropertyListSerialization.data(fromPropertyList: extPlist, format: .xml, options: 0) {
            try? newData.write(to: localInfoPlist)
        }

        // 刷新图标
        let localResources = localContents.appendingPathComponent("Resources")
        let externalResources = externalContents.appendingPathComponent("Resources")
        if let iconName = extPlist["CFBundleIconFile"] as? String {
            let iconNameURL = URL(fileURLWithPath: iconName)
            let iconExt = iconNameURL.pathExtension.isEmpty ? "icns" : iconNameURL.pathExtension
            let iconBase = iconNameURL.pathExtension.isEmpty ? iconName : iconNameURL.deletingPathExtension().lastPathComponent
            let iconFileName = "\(iconBase).\(iconExt)"
            let externalIcon = externalResources.appendingPathComponent(iconFileName)
            let localIcon = localResources.appendingPathComponent(iconFileName)
            if fm.fileExists(atPath: externalIcon.path) {
                try? fm.removeItem(at: localIcon)
                try? fm.copyItem(at: externalIcon, to: localIcon)
            }
        }

        // 重新 ad-hoc 签名
        resignAppBundle(at: localURL)

        // 刷新 Launch Services
        refreshLaunchServices(for: localURL)

        AppLogger.shared.log("已刷新 Stub Portal: \(localURL.lastPathComponent) (\(localVersion ?? "?") → \(externalVersion ?? "?"))")
    }

    private func refreshLaunchServices(for appURL: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = ["-f", appURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLogger.shared.log("lsregister 刷新失败: \(appURL.lastPathComponent)", level: "WARN")
        }
    }

    /// 递归刷新 Launch Services（Folder Mirror：需注册文件夹内部的所有 Stub）
    private func refreshLaunchServicesRecursive(for folderURL: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = ["-f", "-R", folderURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLogger.shared.log("lsregister 递归刷新失败: \(folderURL.lastPathComponent)", level: "WARN")
        }
    }

    /// 复制原生 launcher 二进制，并写入 real_app_path.txt
    private func copyNativeLauncher(to macosDir: URL, resourcesDir: URL, externalURL: URL) throws {
        // 从 AppPorts bundle 中复制预编译的原生 launcher 二进制
        guard let bundledLauncher = Bundle.main.url(forResource: "StubLauncherBinary", withExtension: nil) else {
            // 降级：如果找不到原生二进制，回退到 bash 脚本
            AppLogger.shared.log("未找到原生 launcher 二进制，回退到 bash 脚本", level: "WARN")
            try writeBashLauncher(at: macosDir, externalURL: externalURL)
            return
        }
        let launcherPath = macosDir.appendingPathComponent("launcher")
        try fileManager.copyItem(at: bundledLauncher, to: launcherPath)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath.path)

        // 写入 real_app_path.txt，原生 launcher 读取此文件获取真实应用路径
        let realAppPathFile = resourcesDir.appendingPathComponent("real_app_path.txt")
        try externalURL.path.write(to: realAppPathFile, atomically: true, encoding: .utf8)
    }

    /// 写入 bash launcher 脚本（降级回退或 iOS stub 用）
    private func writeBashLauncher(at macosDir: URL, externalURL: URL) throws {
        let launcherPath = macosDir.appendingPathComponent("launcher")
        let script = """
            #!/bin/bash
            REAL_APP='\(externalURL.path.replacingOccurrences(of: "'", with: "'\\''"))'
            if [ -d "$REAL_APP" ]; then
                open "$REAL_APP"
            else
                osascript -e 'display dialog "External storage is not connected. Connect it and try again." buttons {"OK"} default button 1 with icon caution'
            fi
            """
        try script.write(to: launcherPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath.path)
    }

    /// 从 iOS app 提取图标并转换为 .icns
    private func extractIOSIcon(from innerAppURL: URL, to resourcesDir: URL) throws {
        let fm = fileManager
        // 查找最大的 AppIcon PNG
        let iconFiles = (try? fm.contentsOfDirectory(at: innerAppURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?
            .filter { $0.lastPathComponent.hasPrefix("AppIcon") && $0.pathExtension == "png" } ?? []

        guard let largestIcon = iconFiles.max(by: { a, b in
            (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 <
            (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
        }) else {
            AppLogger.shared.logContext("iOS app 无 AppIcon PNG，跳过图标提取", details: [("path", innerAppURL.path)], level: "WARN")
            return
        }

        // 先缩放到 256x256（.icns 标准尺寸），再转换
        let tempPng = fm.temporaryDirectory.appendingPathComponent("appports_icon_\(UUID().uuidString).png")
        let icnsPath = resourcesDir.appendingPathComponent("AppIcon.icns")

        defer { try? fm.removeItem(at: tempPng) }

        // sips 缩放
        let resize = Process()
        resize.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        resize.arguments = ["-z", "256", "256", largestIcon.path, "--out", tempPng.path]
        resize.standardOutput = FileHandle.nullDevice
        resize.standardError = FileHandle.nullDevice
        try resize.run()
        resize.waitUntilExit()

        guard resize.terminationStatus == 0 else {
            AppLogger.shared.log("iOS app 图标缩放失败（非致命）", level: "WARN")
            return
        }

        // sips 转 icns
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        convert.arguments = ["-s", "format", "icns", tempPng.path, "--out", icnsPath.path]
        convert.standardOutput = FileHandle.nullDevice
        convert.standardError = FileHandle.nullDevice
        try convert.run()
        convert.waitUntilExit()

        if convert.terminationStatus == 0 {
            AppLogger.shared.log("iOS app 图标已转换为 .icns: \(icnsPath.path)")
        } else {
            AppLogger.shared.log("iOS app 图标转换失败（非致命），将使用默认图标", level: "WARN")
        }
    }

    private func buildPortal(for appToMove: AppItem, destinationURL: URL, operationID: String) throws {
        if let portalCreationOverride {
            try portalCreationOverride(appToMove, destinationURL)
            return
        }

        if appToMove.usesFolderOperation {
            AppLogger.shared.log("迁移策略: 应用文件夹 (文件夹镜像，内部 app 为 Stub)", level: "STRATEGY")
            try createLocalPortal(
                at: appToMove.path,
                pointingTo: destinationURL,
                portalKind: .folderMirror,
                operationID: operationID
            )
            return
        }

        switch preferredPortalKind(for: destinationURL) {
        case .wholeAppSymlink:
            AppLogger.shared.log("迁移策略: iOS 应用 (直接符号链接)", level: "STRATEGY")

        case .deepContentsWrapper:
            AppLogger.shared.log("迁移策略: Mac 原生应用 (Contents 深度链接)", level: "STRATEGY")

        case .stubPortal:
            AppLogger.shared.log("迁移策略: 自更新应用 (Stub 启动器，无箭头)", level: "STRATEGY")

        case .folderMirror:
            // preferredPortalKind 不会对单 app 返回此类型；文件夹路径已在上方分支处理
            AppLogger.shared.log("迁移策略: 文件夹镜像", level: "STRATEGY")
        case .transparentHybrid:
            AppLogger.shared.log("迁移策略: 透明混合入口 (真实 .app 壳 + 内部符号链接镜像)", level: "STRATEGY")
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
        unlockImmutableRecursive(at: destinationURL)
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
        case .stubPortal:
            return "stub_portal"
        case .folderMirror:
            return "folder_mirror"
        case .transparentHybrid:
            return "transparent_hybrid"
        }
    }
}
