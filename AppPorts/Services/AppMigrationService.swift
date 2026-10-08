//
//  AppMigrationService.swift
//  AppPorts
//
//  Created by Codex on 2026/3/12.
//

import Foundation
import AppKit
import Darwin

struct AppMigrationService {
    private static let mutationCoordinator = PortalMutationCoordinator()
    static var maintenanceGeneration: UInt64 { mutationCoordinator.generation }

    typealias FinderRemover = (URL) throws -> Void
    typealias PortalCreationOverride = (AppItem, URL) throws -> Void
    typealias DockShortcutUpdater = (URL, URL) throws -> Int

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
        let inode: NSNumber
        let device: NSNumber
    }

    private let fileManager: FileManager
    private let portalCreationOverride: PortalCreationOverride?
    private let dockShortcutUpdater: DockShortcutUpdater
    private let runningApplications: () -> [AppRunningState.RunningApplication]

    init(
        fileManager: FileManager = .default,
        portalCreationOverride: PortalCreationOverride? = nil,
        dockShortcutUpdater: @escaping DockShortcutUpdater = { source, destination in
            try DockShortcutService.shared.redirectShortcuts(from: source, to: destination)
        },
        runningApplications: @escaping () -> [AppRunningState.RunningApplication] = {
            NSWorkspace.shared.runningApplications.map {
                .init(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
            }
        }
    ) {
        self.fileManager = fileManager
        self.portalCreationOverride = portalCreationOverride
        self.dockShortcutUpdater = dockShortcutUpdater
        self.runningApplications = runningApplications
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

    /// Convert an existing standalone copy on the same volume. No missing local entry is recreated.
    func excludeFromSearch(app: AppItem, externalRoot: URL, localEntries: [URL],
                           store: AppSearchRecordStore = .shared) async throws -> AppSearchExclusionService.Result {
        try await Self.mutationCoordinator.begin()
        defer { Self.mutationCoordinator.end() }
        typealias Exclusion = AppSearchExclusionService
        if let reason = Exclusion.unsupportedReason(for: app) { throw Exclusion.failure(reason) }
        let source = app.path.standardizedFileURL
        guard source.deletingLastPathComponent() == externalRoot.standardizedFileURL
                || source.deletingLastPathComponent() == Exclusion.library(in: externalRoot).standardizedFileURL,
              source.resolvingSymlinksInPath() == source else {
            throw Exclusion.failure("套件目录可能包含文档，暂不自动排除。".localized)
        }
        try requireNotRunning(app)
        let library = Exclusion.library(in: externalRoot)
        try Exclusion.prepareLibrary(library, fileManager: fileManager)
        let destination = library.appendingPathComponent(source.lastPathComponent)
        let pending = try fileManager.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".appports-exclusion-") && $0.pathExtension == "json" }
        guard pending.isEmpty else {
            throw Exclusion.failure("存在未完成的存储转换，请先检查应用库中的恢复记录。".localized)
        }
        if Exclusion.isExcluded(source) { return .init(destination: source, dockSynchronized: true) }
        guard (try? fileManager.attributesOfItem(atPath: destination.path)) == nil else {
            throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
        }
        guard let volume = try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw Exclusion.failure("无法确认真实应用身份，未更改存储位置。".localized)
        }
        let sourceIdentity = try Exclusion.FileIdentity.read(source, fileManager: fileManager)
        let sourcePlist = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        let bundleID = sourcePlist?["CFBundleIdentifier"] as? String
        let records = try store.records().filter { $0.externalPath == source.path }
        guard records.allSatisfy({ ($0.volumeUUID == nil || $0.volumeUUID == volume)
            && ($0.targetBundleIdentifier == nil || $0.targetBundleIdentifier == bundleID) }) else {
            throw Exclusion.failure("无法确认真实应用身份，未更改存储位置。".localized)
        }
        let localURLs = Set(localEntries.map { $0.standardizedFileURL.path }
            + records.filter { !$0.isRestored }.map(\.localPath)).map { URL(fileURLWithPath: $0) }
        var portals: [Exclusion.Journal.Portal] = []
        var kinds: [URL: LocalPortalKind] = [:]
        for local in localURLs.sorted(by: { $0.path < $1.path }) {
            guard let present = AppSearchRecordStore.observedLocalPresence(at: local) else {
                throw Exclusion.failure("无法确认真实应用身份，未更改存储位置。".localized)
            }
            if !present { continue }
            guard let kind = localPortalKind(at: local, linkedTo: source),
                  AppPortalMaintenance.matchesRememberedTarget(.init(localURL: local, externalURL: source), store: store),
                  kind != .stubPortal || AppPortalMaintenance.targetIdentityMatches(localURL: local, externalURL: source) else {
                throw Exclusion.failure("本地入口并未指向当前外部应用，无法自动覆盖".localized)
            }
            let stageRoot = local.deletingLastPathComponent().appendingPathComponent(".appports-exclusion-\(UUID().uuidString)")
            let backup = stageRoot.appendingPathComponent("original")
            let stage = stageRoot.appendingPathComponent(local.lastPathComponent)
            portals.append(.init(local: local, backup: backup, stage: stage,
                                 identity: try Exclusion.FileIdentity.read(local, fileManager: fileManager)))
            kinds[local] = kind
        }
        let journalURL = library.appendingPathComponent(".appports-exclusion-\(UUID().uuidString).json")
        var journal = Exclusion.Journal(source: source, destination: destination, sourceIdentity: sourceIdentity,
                                       volumeUUID: volume, portals: portals)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        let wasImmutable = (try fileManager.attributesOfItem(atPath: source.path)[.immutable] as? Bool) == true
        var moved = false
        var backedUp: [Exclusion.Journal.Portal] = []
        var installed: [URL: Exclusion.FileIdentity] = [:]
        var ownedStageRoots: [URL] = []
        var stagedIdentities: [URL: Exclusion.FileIdentity] = [:]
        do {
            try requireNotRunning(app)
            guard try Exclusion.FileIdentity.read(source, fileManager: fileManager) == sourceIdentity else {
                throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
            }
            if wasImmutable { try fileManager.setAttributes([.immutable: false], ofItemAtPath: source.path) }
            try fileManager.moveItem(at: source, to: destination)
            moved = true
            journal.phase = "external-moved"
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            for portal in portals {
                try fileManager.createDirectory(at: portal.stage.deletingLastPathComponent(), withIntermediateDirectories: false)
                ownedStageRoots.append(portal.stage.deletingLastPathComponent())
                if kinds[portal.local] == .stubPortal {
                    try createStubPortal(at: portal.stage, pointingTo: destination, register: false)
                } else {
                    try createLocalPortal(at: portal.stage, pointingTo: destination, portalKind: kinds[portal.local])
                }
                stagedIdentities[portal.stage] = try Exclusion.FileIdentity.read(portal.stage, fileManager: fileManager)
            }
            var relocated = app
            relocated.path = destination
            relocated.bundleURL = destination
            try requireNotRunning(relocated)
            for portal in portals {
                var coordinationError: NSError?
                var mutationError: Error?
                NSFileCoordinator().coordinate(writingItemAt: portal.local, options: .forReplacing, error: &coordinationError) { url in
                    do {
                        // Recheck inside coordination and after the rename. A replacement is never ours to delete.
                        guard try Exclusion.FileIdentity.read(url, fileManager: fileManager) == portal.identity,
                              localPortalKind(at: url, linkedTo: source) != nil else {
                            throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
                        }
                        try fileManager.moveItem(at: url, to: portal.backup)
                        backedUp.append(portal)
                        guard try Exclusion.FileIdentity.read(portal.backup, fileManager: fileManager) == portal.identity else {
                            throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
                        }
                        let newIdentity = try Exclusion.FileIdentity.read(portal.stage, fileManager: fileManager)
                        try fileManager.moveItem(at: portal.stage, to: url)
                        installed[portal.local] = newIdentity
                        stagedIdentities.removeValue(forKey: portal.stage)
                    } catch { mutationError = error }
                }
                if let error = mutationError ?? coordinationError { throw error }
            }
            guard try Exclusion.FileIdentity.read(destination, fileManager: fileManager) == sourceIdentity else {
                throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
            }
            if wasImmutable { try fileManager.setAttributes([.immutable: true], ofItemAtPath: destination.path) }
            journal.phase = "portals-installed"
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try store.retarget(from: source, to: destination, snapshots: records)
        } catch {
            var recoveryFailed = false
            // Undo only files whose device/inode still matches our snapshot.
            for portal in backedUp.reversed() {
                do {
                    if let identity = installed[portal.local] {
                        try removeExclusionOwnedItem(at: portal.local, identity: identity)
                    }
                    try fileManager.moveItem(at: portal.backup, to: portal.local)
                } catch {
                    recoveryFailed = true
                    AppLogger.shared.logError("恢复原应用入口失败，保留恢复记录", error: error, relatedURLs: [("backup", portal.backup)])
                }
            }
            if moved {
                do {
                    guard (try? Exclusion.FileIdentity.read(destination, fileManager: fileManager)) == sourceIdentity else {
                        throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
                    }
                    if wasImmutable { try fileManager.setAttributes([.immutable: false], ofItemAtPath: destination.path) }
                    try fileManager.moveItem(at: destination, to: source)
                } catch {
                    recoveryFailed = true
                    AppLogger.shared.logError("恢复外部应用位置失败，保留恢复记录", error: error, relatedURLs: [("journal", journalURL)])
                }
            }
            if wasImmutable, (try? Exclusion.FileIdentity.read(source, fileManager: fileManager)) == sourceIdentity {
                do { try fileManager.setAttributes([.immutable: true], ofItemAtPath: source.path) }
                catch { recoveryFailed = true }
            }
            if !recoveryFailed {
                for (stage, identity) in stagedIdentities {
                    do { try removeExclusionOwnedItem(at: stage, identity: identity) }
                    catch { recoveryFailed = true }
                }
                for stageRoot in ownedStageRoots {
                    // Never recursively remove a staging directory: it may contain a new user file.
                    if rmdir(stageRoot.path) != 0 { recoveryFailed = true }
                }
                if !recoveryFailed { try? fileManager.removeItem(at: journalURL) }
            }
            if recoveryFailed {
                throw Exclusion.failure(String(format: "转换未完成，已保留应用和恢复记录：%@".localized, journalURL.path))
            }
            throw error
        }
        // The record write is the commit point. Cleanup/Dock failures must not roll back a committed path.
        for portal in portals {
            do { try removeExclusionOwnedItem(at: portal.backup, identity: portal.identity) }
            catch { AppLogger.shared.logError("已完成转换，入口备份清理失败", error: error, relatedURLs: [("backup", portal.backup)]) }
            _ = rmdir(portal.stage.deletingLastPathComponent().path)
            refreshLaunchServices(for: portal.local)
            NotificationCenter.default.post(name: .appPortalPresentationDidChange, object: portal.local)
        }
        try? fileManager.removeItem(at: journalURL)
        let dockOK = synchronizeDockShortcuts(from: source, to: destination,
                                              operationID: AppLogger.shared.makeOperationID(prefix: "search-exclusion"))
        return .init(destination: destination, dockSynchronized: dockOK)
    }

    /// Isolate the actual object before deletion; a concurrent replacement is restored or preserved.
    private func removeExclusionOwnedItem(at url: URL, identity: AppSearchExclusionService.FileIdentity) throws {
        typealias Exclusion = AppSearchExclusionService
        let quarantine = url.deletingLastPathComponent().appendingPathComponent(".appports-cleanup-\(UUID().uuidString)")
        var coordinationError: NSError?
        var removalError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinated in
            do {
                guard try Exclusion.FileIdentity.read(coordinated, fileManager: fileManager) == identity else {
                    throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
                }
                try fileManager.moveItem(at: coordinated, to: quarantine)
                guard try Exclusion.FileIdentity.read(quarantine, fileManager: fileManager) == identity else {
                    // moveItem refuses to overwrite a file that appeared at the original path.
                    try fileManager.moveItem(at: quarantine, to: coordinated)
                    throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
                }
                try fileManager.removeItem(at: quarantine)
            } catch {
                removalError = error
                AppLogger.shared.logError("清理入口时身份改变或删除失败，保留文件", error: error,
                                          relatedURLs: [("original", url), ("quarantine", quarantine)])
            }
        }
        if let error = removalError ?? coordinationError { throw error }
    }

    func moveAndLink(
        appToMove: AppItem,
        destinationURL: URL,
        isRunning: Bool,
        lockExternal: Bool = true,
        deleteSourceFallback: FinderRemover? = nil,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws {
        try await Self.mutationCoordinator.begin()
        defer { Self.mutationCoordinator.end() }
        if AppSearchExclusionService.isExcluded(destinationURL) {
            if let reason = AppSearchExclusionService.unsupportedReason(for: appToMove) {
                throw AppSearchExclusionService.failure(reason)
            }
            try AppSearchExclusionService.prepareLibrary(destinationURL.deletingLastPathComponent(), fileManager: fileManager)
        }
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
            do {
                try await copier.copyDirectory(
                    from: appToMove.path,
                    to: destinationURL,
                    estimatedTotalBytes: appToMove.sizeBytes,
                    removeQuarantine: true,
                    progressHandler: progressHandler
                )
            } catch {
                // Only clean up failures from copying, while the complete source still exists.
                // A failed source deletion below must not enter this cleanup path.
                if fileManager.fileExists(atPath: destinationURL.path) {
                    do {
                        try FileCopier.removeCopy(at: destinationURL)
                    } catch let cleanupError {
                        AppLogger.shared.logError(
                            "清理未完成的外部副本失败",
                            error: cleanupError,
                            errorCode: "APP-MOVE-PARTIAL-COPY-CLEANUP-FAILED",
                            context: [("operation_id", operationID)],
                            relatedURLs: [("destination", destinationURL)]
                        )
                    }
                }
                throw error
            }
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
                            "步骤2: Finder 删除也失败，保留完整外部副本",
                            error: finderError,
                            errorCode: "APP-MOVE-SOURCE-DELETE-FAILED",
                            context: [("operation_id", operationID)],
                            relatedURLs: [("source", appToMove.path), ("destination", destinationURL)]
                        )
                        // removeItem can fail after deleting part of the source.
                        // The external copy is now the only guaranteed complete copy.
                        operationErrorCode = "APP-MOVE-SOURCE-DELETE-FAILED"
                        throw AppMoverError.appStoreAppError(finderError)
                    }
                } else {
                    AppLogger.shared.logError(
                        "步骤2: 删除源失败，保留完整外部副本",
                        error: normalError,
                        errorCode: "APP-MOVE-SOURCE-DELETE-FAILED",
                        context: [("operation_id", operationID)],
                        relatedURLs: [("source", appToMove.path), ("destination", destinationURL)]
                    )
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

        // FileCopier removes only quarantine as each item is copied. Do not strip
        // unrelated metadata or traverse the entire external tree again here.

        AppLogger.shared.logPathState("迁移完成-本地入口[\(operationID)]", url: appToMove.path)
        AppLogger.shared.logPathState("迁移完成-外部目标[\(operationID)]", url: destinationURL)
        if synchronizeDockShortcuts(from: appToMove.path, to: destinationURL, operationID: operationID) {
            operationResult = "success"
        } else {
            operationResult = "success_with_warning"
            operationErrorCode = "APP-DOCK-SYNC-FAILED"
        }
    }

    func linkApp(appToLink: AppItem, destinationURL: URL) throws {
        try Self.mutationCoordinator.beginSynchronously()
        defer { Self.mutationCoordinator.end() }
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

        if appToLink.usesFolderOperation,
           localPortalKind(at: destinationURL, linkedTo: appToLink.path) == .folderMirror {
            try addMissingFolderEntries(at: destinationURL, from: appToLink.path)
            operationResult = "success"
            return
        }

        var originalPortalBackup: URL?
        if (try? fileManager.attributesOfItem(atPath: destinationURL.path)) != nil {
            guard let existingKind = localPortalKind(at: destinationURL, linkedTo: appToLink.path),
                  existingKind != .folderMirror else {
                throw AppMoverError.generalError(NSError(domain: "AppMover", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "本地已有其他应用或入口，无法自动覆盖".localized]))
            }
            let backup = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".appports-link-backup-\(UUID().uuidString)")
            try fileManager.moveItem(at: destinationURL, to: backup)
            originalPortalBackup = backup
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
            var recoveryError: Error?
            if let backup = originalPortalBackup {
                do {
                    // Exclusive move preserves any file that appeared during preparation.
                    try fileManager.moveItem(at: backup, to: destinationURL)
                } catch {
                    recoveryError = NSError(domain: "AppPorts.PortalRecovery", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: String(format: "重新添加入口失败，原入口备份位于：%@".localized, backup.path),
                        NSFilePathErrorKey: backup.path, NSUnderlyingErrorKey: error
                    ])
                    AppLogger.shared.logError("重新添加入口失败，原入口保留在备份位置", error: error,
                        relatedURLs: [("backup", backup), ("destination", destinationURL)])
                }
            }
            operationErrorCode = "APP-LINK-PORTAL-CREATE-FAILED"
            AppLogger.shared.logError(
                "创建应用入口失败",
                error: error,
                errorCode: operationErrorCode,
                context: [("operation_id", operationID), ("portal_kind", portalKindDescription(portalKind))],
                relatedURLs: [("source", appToLink.path), ("destination", destinationURL)]
            )
            throw recoveryError ?? error
        }
        if let backup = originalPortalBackup { try? fileManager.removeItem(at: backup) }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destinationURL.path)
        AppLogger.shared.logPathState("链接完成-本地目标[\(operationID)]", url: destinationURL)
        if synchronizeDockShortcuts(from: destinationURL, to: appToLink.path, operationID: operationID) {
            operationResult = "success"
        } else {
            operationResult = "success_with_warning"
            operationErrorCode = "APP-DOCK-SYNC-FAILED"
        }
    }

    func deleteLink(app: AppItem) throws {
        try Self.mutationCoordinator.beginSynchronously()
        defer { Self.mutationCoordinator.end() }
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

    struct RestoreResult {
        let retiredLocalPortalURLs: [URL]
        let externalSourceRemains: Bool
    }

    @discardableResult
    func moveBack(
        app: AppItem,
        localDestinationURL: URL,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws -> RestoreResult {
        try await Self.mutationCoordinator.begin()
        defer { Self.mutationCoordinator.end() }
        try requireNotRunning(app)
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
        let suitePortalSnapshots = app.usesFolderOperation
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

        var originalPortalBackup: URL?
        if fileManager.fileExists(atPath: localDestinationURL.path) {
            AppLogger.shared.log("本地存在同名项目，正在清理...")

            if let existingPortalKind {
                let backup = localDestinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".appports-restore-backup-\(UUID().uuidString)")
                try fileManager.moveItem(at: localDestinationURL, to: backup)
                originalPortalBackup = backup
                AppLogger.shared.log("已暂存本地 AppPorts 入口: \(portalKindDescription(existingPortalKind))")
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


        AppLogger.shared.log("步骤1: 开始复制应用回本地...")
        let startTime = Date()
        let copier = FileCopier()
        let sourceSize = (try? fileManager.attributesOfItem(atPath: app.path.path)[.size] as? Int64) ?? 0

        // 解锁外部 app（uchg），以便复制和删除
        let unlockSuccess = unlockExternalApp(at: app.path)
        if !unlockSuccess {
            AppLogger.shared.log("外部 app 解锁未完全成功，后续复制/删除可能受影响", level: "WARN")
        }

        let copyOwnership = CopyDestinationOwnership()
        do {
            try await copier.copyDirectory(
                from: app.path,
                to: localDestinationURL,
                estimatedTotalBytes: app.sizeBytes,
                progressHandler: { progress in
                    if progress.copiedBytes > 0 { await copyOwnership.observe(localDestinationURL) }
                    await progressHandler?(progress)
                }
            )
        } catch {
            if let identity = await copyOwnership.recorded() {
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(writingItemAt: localDestinationURL, options: .forDeleting, error: &coordinationError) { url in
                    guard CopyDestinationOwnership.identity(at: url) == identity else { return }
                    try? FileCopier.removeCopy(at: url)
                }
            }
            var recoveryError: Error?

            if let backup = originalPortalBackup {
                do {
                    try fileManager.moveItem(at: backup, to: localDestinationURL)
                    originalPortalBackup = nil
                } catch let portalError {
                    recoveryError = NSError(domain: "AppPorts.PortalRecovery", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: String(format: "还原失败，当前本地文件已保留。原入口备份位于：%@".localized, backup.path),
                        NSFilePathErrorKey: backup.path, NSUnderlyingErrorKey: portalError
                    ])
                    // Leave the backup recoverable if restoring it encounters a new conflict.
                    AppLogger.shared.logError("还原失败后恢复原入口失败，保留备份", error: portalError,
                        relatedURLs: [("backup", backup), ("destination", localDestinationURL)])
                }
            }


            AppLogger.shared.logError(
                "复制外部应用回本地失败",
                error: error,
                errorCode: "APP-RESTORE-COPY-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("source", app.path), ("destination", localDestinationURL)]
            )
            operationErrorCode = "APP-RESTORE-COPY-FAILED"
            if recoveryError == nil, originalPortalBackup != nil || (existingPortalKind == nil && (try? fileManager.attributesOfItem(atPath: localDestinationURL.path)) != nil) {
                recoveryError = NSError(domain: "AppPorts.PortalRecovery", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: String(format: "还原失败，未能确认本地文件归属，已保留：%@".localized, localDestinationURL.path),
                    NSUnderlyingErrorKey: error
                ])
            }
            throw recoveryError ?? error
        }
        var retiredLocalPortalURLs: [URL] = []
        for snapshot in suitePortalSnapshots {
            do {
                if try retirePortal(snapshot) { retiredLocalPortalURLs.append(snapshot.localURL) }
            } catch {
                operationResult = "success_with_warning"
                operationErrorCode = "APP-RESTORE-PORTAL-CLEANUP-FAILED"
                AppLogger.shared.logError("旧套件入口待清理", error: error,
                    relatedURLs: [("local", snapshot.localURL)])
            }
        }

        if let backup = originalPortalBackup {
            try? fileManager.removeItem(at: backup)
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

        // A process may have started while the copy was in progress. Keep both
        // complete copies if so; never delete resources from a live application.
        try requireNotRunning(app)

        // 本地副本完整后即可切回；外部副本清理失败也不应让 Dock 继续打开旧副本。
        var dockSynchronized = synchronizeDockShortcuts(
            from: app.path, to: localDestinationURL, operationID: operationID
        )
        for snapshot in suitePortalSnapshots where retiredLocalPortalURLs.contains(snapshot.localURL) {
            // 兼容旧版本把套件内部应用展开到本地根目录的入口。
            let restoredAppURL = localDestinationURL.appendingPathComponent(snapshot.externalURL.lastPathComponent)
            if !synchronizeDockShortcuts(from: snapshot.localURL, to: restoredAppURL, operationID: operationID) {
                dockSynchronized = false
            }
        }
        if !dockSynchronized {
            operationResult = "success_with_warning"
            operationErrorCode = "APP-DOCK-SYNC-FAILED"
        }

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
        if app.usesFolderOperation { refreshLaunchServicesRecursive(for: localDestinationURL) }
        else { refreshLaunchServices(for: localDestinationURL) }
        return RestoreResult(
            retiredLocalPortalURLs: retiredLocalPortalURLs,
            externalSourceRemains: fileManager.fileExists(atPath: app.path.path)
        )
    }

    /// 恢复到已有入口所在的扫描目录；旧版展开入口仍恢复整个应用容器。
    /// 还原必须作用在外部本体上。
    ///
    /// 已链接 / 部分链接的应用，本地那一条记录只是一个入口（stub / 符号链接），它的 `path`
    /// 指向本地入口而不是本体。直接拿它去还原会变成「把入口还原到入口自己身上」，
    /// 入口检查认不出这个入口，于是报「本地已存在同名真实文件，无法覆盖」。
    /// 这里按入口实际指向的真实路径，在外部应用列表里找出对应的本体记录。
    /// - Returns: 对应的外部本体记录；传入的本来就是外部本体、本地实体，或解析不出来时返回 nil。
    func externalCounterpart(of app: AppItem, in externalApps: [AppItem]) -> AppItem? {
        guard !app.usesFolderOperation,
              app.status == AppStatus.linked || app.status == AppStatus.partialLinked,
              let realURL = try? CodeSigner.resolveAppURL(at: app.path) else { return nil }
        let standardized = realURL.standardizedFileURL
        guard standardized.path != app.path.standardizedFileURL.path else { return nil }
        return externalApps.first { candidate in
            candidate.path.standardizedFileURL == standardized
                || candidate.bundleURL?.standardizedFileURL == standardized
        }
    }

    func localDestinationForRestore(
        of app: AppItem,
        defaultDirectory: URL,
        additionalDirectories: [URL] = []
    ) -> URL {
        for directory in [defaultDirectory] + additionalDirectories {
            let candidate = directory.appendingPathComponent(app.name)
            if localPortalKind(at: candidate, linkedTo: app.path) != nil {
                return candidate
            }
            if let bundleURL = app.bundleURL, bundleURL.lastPathComponent != app.name {
                let bundleCandidate = directory.appendingPathComponent(bundleURL.lastPathComponent)
                if localPortalKind(at: bundleCandidate, linkedTo: bundleURL) != nil {
                    return app.usesFolderOperation ? candidate : bundleCandidate
                }
            }
        }
        return defaultDirectory.appendingPathComponent(app.name)
    }

    /// 显式修复既有本地入口对应的固定项；扫描与版本刷新不会改动用户的 Dock。
    func repairDockShortcuts(for app: AppItem) throws -> Int {
        let sourceURL = app.path
        guard localPortalKind(at: sourceURL) != nil else {
            throw NSError(domain: "AppPorts.Dock", code: 2)
        }
        let destinationURL: URL
        if app.usesFolderOperation {
            guard let externalURL = folderMirrorExternalURL(at: sourceURL) ?? resolveSymlinkDestination(at: sourceURL),
                  externalURL.path != sourceURL.standardizedFileURL.path,
                  fileManager.fileExists(atPath: externalURL.path) else {
                throw NSError(domain: "AppPorts.Dock", code: 1)
            }
            destinationURL = externalURL
        } else {
            var resolvedURL = try CodeSigner.resolveAppURL(at: sourceURL)
            // 旧 Hybrid 只链接 Contents/MacOS 等组件，没有 launcher 的目标文件。
            // 仅从标准 <App>.app/Contents/<component> 结构推导，不按应用名猜路径。
            let contentsURL = sourceURL.appendingPathComponent("Contents")
            if resolvedURL == sourceURL.resolvingSymlinksInPath().standardizedFileURL,
               let component = legacyHybridSymlinkComponent(in: contentsURL),
               let linkedComponent = resolveSymlinkDestination(at: contentsURL.appendingPathComponent(component)),
               linkedComponent.lastPathComponent == component,
               linkedComponent.deletingLastPathComponent().lastPathComponent == "Contents" {
                let externalURL = linkedComponent.deletingLastPathComponent().deletingLastPathComponent()
                resolvedURL = try CodeSigner.resolveAppURL(at: externalURL)
            }
            destinationURL = resolvedURL
        }
        guard destinationURL.standardizedFileURL.path != sourceURL.standardizedFileURL.path else {
            throw NSError(domain: "AppPorts.Dock", code: 2)
        }
        return try dockShortcutUpdater(sourceURL, destinationURL)
    }

    /// Dock 属于迁移后的附加同步：失败应可重试，不能回滚已经完整迁移的应用。
    @discardableResult
    private func synchronizeDockShortcuts(from sourceURL: URL, to destinationURL: URL, operationID: String) -> Bool {
        do {
            let updatedCount = try dockShortcutUpdater(sourceURL, destinationURL)
            if updatedCount > 0 {
                AppLogger.shared.logContext(
                    "已同步 Dock 固定项",
                    details: [("operation_id", operationID), ("updated_count", String(updatedCount)),
                              ("source", sourceURL.path), ("destination", destinationURL.path)]
                )
            }
            return true
        } catch {
            AppLogger.shared.logError(
                "应用迁移已完成，但 Dock 固定项未能同步，可从应用菜单重试",
                error: error,
                errorCode: "APP-DOCK-SYNC-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("source", sourceURL), ("destination", destinationURL)]
            )
            return false
        }
    }

    private func isIOSAppBundle(at appURL: URL) -> Bool {
        fileManager.fileExists(atPath: appURL.appendingPathComponent("WrappedBundle").path)
    }

    /// 递归解除目录及其内容的 immutable 标志（旧迁移会锁定外部副本）
    private func unlockImmutableRecursive(at url: URL) {
        unlockExternalApp(at: url)
    }

    /// 锁定外部 app（uchg），防止自更新应用的 updater 删除
    func lockExternalApp(at url: URL) {
        guard !FileCopier.isNetworkVolume(at: url) else {
            AppLogger.shared.logContext(
                "网络卷跳过本地文件锁，避免递归请求不支持的 uchg 标志",
                details: [("path", url.path)],
                level: "WARN"
            )
            return
        }
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
        guard !FileCopier.isNetworkVolume(at: url) else { return true }
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

    private func requireNotRunning(_ app: AppItem) throws {
        var urls = [app.path]
        if app.usesFolderOperation {
            urls += try fileManager.contentsOfDirectory(at: app.path, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "app" }
        }
        let snapshot = runningApplications()
        guard !urls.contains(where: { AppRunningState.isRunning(appURL: $0, applications: snapshot) }) else {
            throw AppMoverError.appIsRunning
        }
    }

    private func applicationMetadata(at url: URL) -> [String: Any]? {
        guard case .success(let identity) = AppIdentityResolver.resolve(at: url) else { return nil }
        for path in ["Contents/Info.plist", "Info.plist"] {
            if let data = try? Data(contentsOf: identity.identityBundleURL.appendingPathComponent(path)),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return plist
            }
        }
        return nil
    }

    private func samePortalTarget(_ stored: String, _ expected: URL) -> Bool {
        guard stored.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: stored).standardizedFileURL
        return url.lastPathComponent == expected.lastPathComponent
            && DiskUtility.pathsMatch(url.deletingLastPathComponent().path, expected.deletingLastPathComponent().path)
    }

    private func hasRealStubStorage(at url: URL) -> Bool {
        for path in ["", "Contents", "Contents/MacOS", "Contents/Resources"] {
            let candidate = path.isEmpty ? url : url.appendingPathComponent(path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        }
        for path in ["Contents/Info.plist", "Contents/MacOS/launcher"] {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.appendingPathComponent(path).path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        }
        return true
    }

    private func externalTargetReplacementReason(for appToMove: AppItem, destinationURL: URL) -> String? {
        if appToMove.status == AppStatus.pendingMoveOut {
            // A scanner status is not authority to delete the name-based destination.
            guard let source = applicationMetadata(at: appToMove.path),
                  let target = applicationMetadata(at: destinationURL),
                  let sourceID = source["CFBundleIdentifier"] as? String,
                  let targetID = target["CFBundleIdentifier"] as? String,
                  !sourceID.isEmpty, sourceID == targetID else { return nil }
            for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
                guard let newer = source[key] as? String, let older = target[key] as? String,
                      !newer.isEmpty, !older.isEmpty,
                      newer.allSatisfy({ $0.isNumber || $0 == "." }),
                      older.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
                let comparison = newer.compare(older, options: .numeric)
                if comparison != .orderedSame {
                    return comparison == .orderedDescending ? "pending_move_out" : nil
                }
            }
            return nil
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

    func isManagedPortal(at localURL: URL) -> Bool {
        localPortalKind(at: localURL) != nil
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

        // 只有标记指向本次操作的外部套件，才允许替换或清理这个本地入口。
        if let recorded = Self.folderMirrorExternalURL(at: localURL, fileManager: fileManager),
           recorded.path == standardizedExternalURL.path {
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
                if !realPath.isEmpty && samePortalTarget(realPath, standardizedExternalURL) {
                    return .stubPortal
                }
            }
            // 旧版 bash launcher：检查脚本内容
            if let script = try? String(contentsOf: launcherPath, encoding: .utf8),
               let assignment = script.components(separatedBy: .newlines)
                    .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("REAL_APP=") }),
               assignment.hasPrefix("REAL_APP='"), assignment.hasSuffix("'") {
                let path = String(assignment.dropFirst("REAL_APP='".count).dropLast())
                    .replacingOccurrences(of: "'\\''", with: "'")
                if samePortalTarget(path, standardizedExternalURL) { return .stubPortal }
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

        // Existing entries, including concurrently installed real folders, must not be overwritten.
        try fm.createDirectory(at: localFolderURL, withIntermediateDirectories: false, attributes: nil)

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
                    // Exclusive creation must fail if a real app appeared while staging.
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

    /// Explicit additive relink only. Rescans never call this method.
    private func addMissingFolderEntries(at localFolder: URL, from externalFolder: URL) throws {
        let fm = fileManager
        let originalIdentity = try fm.attributesOfItem(atPath: localFolder.path)[.systemFileNumber] as? NSNumber
        let entries = try fm.contentsOfDirectory(at: externalFolder, includingPropertiesForKeys: nil,
                                                options: .skipsHiddenFiles).sorted { $0.path < $1.path }
        var missing: [URL] = []
        for external in entries {
            let local = localFolder.appendingPathComponent(external.lastPathComponent)
            if (try? fm.attributesOfItem(atPath: local.path)) != nil {
                if external.pathExtension == "app", localPortalKind(at: local, linkedTo: external) == nil {
                    throw AppMoverError.generalError(NSError(domain: "AppMover", code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "本地已有其他应用或入口，无法自动覆盖".localized]))
                }
                continue // Preserve personal files and every surviving entry byte-for-byte.
            }
            missing.append(external)
        }
        let stage = localFolder.deletingLastPathComponent()
            .appendingPathComponent(".appports-suite-add-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        // Prepare every entry before installing any of them. Invalid resources or
        // signing failures leave the original folder completely unchanged.
        for external in missing {
            let staged = stage.appendingPathComponent(external.lastPathComponent)
            if external.pathExtension == "app" {
                try createStubPortal(at: staged, pointingTo: external, register: false)
            } else {
                try fm.createSymbolicLink(at: staged, withDestinationURL: external)
            }
        }
        var installed: [(URL, NSNumber?)] = []
        do {
            for external in missing {
                guard localPortalKind(at: localFolder, linkedTo: externalFolder) == .folderMirror,
                      (try fm.attributesOfItem(atPath: localFolder.path)[.systemFileNumber] as? NSNumber) == originalIdentity else {
                    throw CocoaError(.fileWriteFileExists)
                }
                let staged = stage.appendingPathComponent(external.lastPathComponent)
                let local = localFolder.appendingPathComponent(external.lastPathComponent)
                let identity = try fm.attributesOfItem(atPath: staged.path)[.systemFileNumber] as? NSNumber
                guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, local.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                installed.append((local, identity))
            }
        } catch {
            for (local, identity) in installed.reversed() {
                if let current = try? fm.attributesOfItem(atPath: local.path)[.systemFileNumber] as? NSNumber,
                   current == identity {
                    do { try fm.removeItem(at: local) }
                    catch { AppLogger.shared.logError("添加套件入口回滚失败", error: error, relatedURLs: [("local", local)]) }
                }
            }
            throw error
        }
        if !installed.isEmpty {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: localFolder.path)
            refreshLaunchServicesRecursive(for: localFolder)
        }
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

    /// A rescan updates only surviving managed entries. Missing entries express user intent;
    /// unavailable targets may merely be in the middle of an updater transaction.
    func refreshFolderMirror(at localFolderURL: URL, from externalFolderURL: URL, expectedGeneration: UInt64? = nil) {
        guard Self.mutationCoordinator.tryBeginMaintenance(expectedGeneration: expectedGeneration) else { return }
        defer { Self.mutationCoordinator.end() }
        let fm = fileManager
        guard (try? fm.attributesOfItem(atPath: localFolderURL.path)[.type]) as? FileAttributeType == .typeDirectory,
              let recorded = Self.folderMirrorExternalURL(at: localFolderURL, fileManager: fm),
              recorded.resolvingSymlinksInPath() == externalFolderURL.resolvingSymlinksInPath(),
              let entries = try? fm.contentsOfDirectory(at: localFolderURL,
                  includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        for local in entries where local.pathExtension == "app" {
            refreshExistingStubPortal(at: local, from: externalFolderURL.appendingPathComponent(local.lastPathComponent))
        }
    }

    /// 创建 Stub Portal：极小的假 .app，含 launcher 脚本启动外部真实 app
    private func createStubPortal(at localURL: URL, pointingTo externalURL: URL, register: Bool = true) throws {
        let fm = fileManager

        // 检测是否为 iOS 应用（有 Wrapper/ 或 WrappedBundle/ 目录）
        let wrapperDir = externalURL.appendingPathComponent("Wrapper")
        let wrappedBundleDir = externalURL.appendingPathComponent("WrappedBundle")
        let isIOSApp = fm.fileExists(atPath: wrapperDir.path) || fm.fileExists(atPath: wrappedBundleDir.path)

        if isIOSApp {
            try createIOSStubPortal(at: localURL, pointingTo: externalURL)
        } else {
            try createMacOSStubPortal(at: localURL, pointingTo: externalURL, register: register)
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
        let metadata = (NSDictionary(contentsOf: iTunesPlist) as? [String: Any]) ?? [:]
        let identityMetadata = applicationMetadata(at: externalURL)
        guard let bundleID = (identityMetadata?["CFBundleIdentifier"] as? String)
                ?? (metadata["softwareVersionBundleId"] as? String), !bundleID.isEmpty else {
            throw AppMoverError.generalError(CocoaError(.fileReadCorruptFile))
        }
        do {
            let appName = metadata["title"] as? String ?? localURL.deletingPathExtension().lastPathComponent
            let version = identityMetadata?["CFBundleShortVersionString"] as? String ?? metadata["bundleShortVersionString"] as? String ?? "1.0"

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
            let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try newData.write(to: localContents.appendingPathComponent("Info.plist"))
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
    private func createMacOSStubPortal(at destinationURL: URL, pointingTo externalURL: URL, register: Bool = true) throws {
        let fm = fileManager
        let localURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".appports-create-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: localURL) }
        let localContents = localURL.appendingPathComponent("Contents")
        let localMacOS = localContents.appendingPathComponent("MacOS")
        let externalContents = externalURL.appendingPathComponent("Contents")

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

        // Creation and repair share one resource and metadata implementation.
        for warning in try PortalPresentation.write(from: externalContents, to: localContents) {
            AppLogger.shared.log(warning, level: "WARN")
        }
        try signAndVerifyPortal(at: localURL)
        guard renameatx_np(AT_FDCWD, localURL.path, AT_FDCWD, destinationURL.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if register { refreshLaunchServices(for: destinationURL) }

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
    @discardableResult
    func refreshStubPortal(at localURL: URL, from externalURL: URL, force: Bool = false, expectedGeneration: UInt64? = nil) -> Bool {
        guard Self.mutationCoordinator.tryBeginMaintenance(expectedGeneration: expectedGeneration) else { return false }
        defer { Self.mutationCoordinator.end() }
        return refreshExistingStubPortal(at: localURL, from: externalURL, force: force)
    }

    @discardableResult
    private func refreshExistingStubPortal(at localURL: URL, from externalURL: URL, force: Bool = false) -> Bool {
        guard AppPortalMaintenance.targetIdentityMatches(localURL: localURL, externalURL: externalURL),
              hasRealStubStorage(at: localURL),
              localPortalKind(at: localURL, linkedTo: externalURL) == .stubPortal,
              let resolved = try? CodeSigner.resolveAppURL(at: localURL),
              resolved.resolvingSymlinksInPath() == externalURL.resolvingSymlinksInPath() else { return false }
        let fm = fileManager
        let localContents = localURL.appendingPathComponent("Contents")
        let externalContents = externalURL.appendingPathComponent("Contents")
        let localInfoPlist = localContents.appendingPathComponent("Info.plist")
        let externalInfoPlist = externalContents.appendingPathComponent("Info.plist")

        // 读取外置 app 的 Info.plist
        guard let extData = try? Data(contentsOf: externalInfoPlist),
              let extPlist = try? PropertyListSerialization.propertyList(from: extData, format: nil) as? [String: Any] else {
            return false
        }

        // 读取本地 Stub Portal 的 Info.plist
        guard let localData = try? Data(contentsOf: localInfoPlist),
              let localPlist = try? PropertyListSerialization.propertyList(from: localData, format: nil) as? [String: Any] else {
            return false
        }

        guard force || PortalPresentation.needsRefresh(local: localPlist, external: extPlist) else { return false }
        let stage = localURL.deletingLastPathComponent()
            .appendingPathComponent(".appports-refresh-\(UUID().uuidString).app")
        let originalIdentity = try? fm.attributesOfItem(atPath: localURL.path)[.systemFileNumber] as? NSNumber
        defer { try? fm.removeItem(at: stage) }
        do {
            try fm.copyItem(at: localURL, to: stage)
            for warning in try PortalPresentation.write(from: externalContents, to: stage.appendingPathComponent("Contents")) {
                AppLogger.shared.log(warning, level: "WARN")
            }
            try signAndVerifyPortal(at: stage)
            var coordinationError: NSError?
            var commitError: Error?
            var committed = false
            NSFileCoordinator().coordinate(writingItemAt: localURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                // Finder may have removed or replaced the entry during resource preparation.
                guard AppPortalMaintenance.targetIdentityMatches(localURL: coordinatedURL, externalURL: externalURL),
                      hasRealStubStorage(at: coordinatedURL),
                      localPortalKind(at: coordinatedURL, linkedTo: externalURL) == .stubPortal,
                      let currentIdentity = try? fm.attributesOfItem(atPath: coordinatedURL.path)[.systemFileNumber] as? NSNumber,
                      currentIdentity == originalIdentity else { return }
                // Exchange requires BOTH paths to exist. A deleted entry is never recreated.
                if renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, coordinatedURL.path, UInt32(RENAME_SWAP)) != 0 {
                    commitError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                } else {
                    committed = true
                }
            }
            if let error = coordinationError ?? commitError as NSError? { throw error }
            if committed { refreshLaunchServices(for: localURL) }
            return committed
        } catch {
            AppLogger.shared.logError("入口显示资料修复失败，保留原入口", error: error,
                                      relatedURLs: [("local", localURL), ("external", externalURL)])
            return false
        }
    }

    /// Signing failures are fatal before a staged portal is installed.
    private func signAndVerifyPortal(at appURL: URL) throws {
        // Only staged portal resources are cleaned; the external original is never modified.
        let attributes = Process()
        attributes.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        attributes.arguments = ["-crs", appURL.path]
        attributes.standardOutput = FileHandle.nullDevice
        attributes.standardError = FileHandle.nullDevice
        try attributes.run()
        attributes.waitUntilExit()
        guard attributes.terminationStatus == 0 else {
            throw NSError(domain: "AppPorts.PortalSigning", code: Int(attributes.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "无法准备入口签名资料".localized])
        }
        for arguments in [["--force", "--sign", "-", appURL.path], ["--verify", "--strict", appURL.path]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "AppPorts.PortalSigning", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "入口签名验证失败".localized])
            }
        }
    }

    private func refreshLaunchServices(for appURL: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = ["-f", appURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                AppLogger.shared.log("lsregister 退出码: \(process.terminationStatus)", level: "WARN")
            }
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
            if process.terminationStatus != 0 {
                AppLogger.shared.log("lsregister 退出码: \(process.terminationStatus)", level: "WARN")
            }
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
            guard let kind = localPortalKind(at: localAppURL, linkedTo: appURL),
                  let attributes = try? fileManager.attributesOfItem(atPath: localAppURL.path),
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber else { return nil }
            return LocalPortalSnapshot(localURL: localAppURL, externalURL: appURL, kind: kind, inode: inode, device: device)
        }
    }

    private func retirePortal(_ snapshot: LocalPortalSnapshot) throws -> Bool {
        var coordinationError: NSError?
        var removalError: Error?
        var removed = false
        NSFileCoordinator().coordinate(writingItemAt: snapshot.localURL, options: .forDeleting, error: &coordinationError) { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.systemFileNumber] as? NSNumber == snapshot.inode,
                  attributes[.systemNumber] as? NSNumber == snapshot.device,
                  localPortalKind(at: url, linkedTo: snapshot.externalURL) == snapshot.kind else { return }
            do { try fileManager.removeItem(at: url); removed = true }
            catch { removalError = error }
        }
        if let error = coordinationError ?? removalError as NSError? { throw error }
        return removed
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

        if let attributes = try? fileManager.attributesOfItem(atPath: appToMove.path.path) {
            guard let kind = localPortalKind(at: appToMove.path, linkedTo: destinationURL),
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber,
                  try retirePortal(LocalPortalSnapshot(localURL: appToMove.path, externalURL: destinationURL,
                      kind: kind, inode: inode, device: device)) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }

        let copier = FileCopier()
        try await copier.copyDirectory(from: destinationURL, to: appToMove.path, progressHandler: nil)
        // 部分入口可能已被 Dock 识别为 Stub；只在完整本地应用恢复后纠正缓存。
        synchronizeDockShortcuts(from: destinationURL, to: appToMove.path, operationID: operationID)
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

/// One process-wide lease across service instances. Async operations suspend while waiting;
/// synchronous UI actions fail promptly rather than blocking the main thread behind a copy.
final class PortalMutationCoordinator {
    private let lock = NSLock()
    private var occupied = false
    private var currentGeneration: UInt64 = 0

    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration
    }

    func tryBegin() -> Bool {
        claim(isMutation: true, expectedGeneration: nil)
    }

    func tryBeginMaintenance(expectedGeneration: UInt64?) -> Bool {
        claim(isMutation: false, expectedGeneration: expectedGeneration)
    }

    private func claim(isMutation: Bool, expectedGeneration: UInt64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !occupied, expectedGeneration == nil || expectedGeneration == currentGeneration else { return false }
        occupied = true
        if isMutation { currentGeneration &+= 1 }
        return true
    }

    func beginSynchronously() throws {
        guard tryBegin() else {
            throw NSError(domain: "AppPorts.PortalMutation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "应用操作正在进行，请稍后重试。".localized])
        }
    }

    func begin() async throws {
        while !tryBegin() { try await Task.sleep(nanoseconds: 10_000_000) }
        do { try Task.checkCancellation() }
        catch { end(); throw error }
    }

    func end() {
        lock.lock()
        occupied = false
        lock.unlock()
    }
}

/// Records ownership before a progress consumer can replace the destination.
private actor CopyDestinationOwnership {
    struct Identity: Equatable, Sendable {
        let inode: UInt64
        let device: UInt64
    }
    private var captured: Identity?

    nonisolated static func identity(at url: URL) -> Identity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { return nil }
        return Identity(inode: inode.uint64Value, device: device.uint64Value)
    }

    func observe(_ url: URL) {
        if captured == nil { captured = Self.identity(at: url) }
    }

    func recorded() -> Identity? { captured }
}
