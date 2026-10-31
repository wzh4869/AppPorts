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

    struct ReplacementChoice: Identifiable, Sendable {
        enum VersionComparison: String, Hashable, Sendable { case newer, same, older, unrecognized }
        let id: UUID
        let sourceURL: URL
        let destinationURL: URL
        let sourceIdentity: DataPathIdentity
        let destinationIdentity: DataPathIdentity
        let applicationIdentifiers: [String: String]
        let versionComparison: VersionComparison
    }

    private enum LocalPortalKind: String {
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
    private let dockShortcutRetryUpdater: DockShortcutUpdater
    private let runningApplications: () -> [AppRunningState.RunningApplication]
    private let transferStore: AppTransferStore
    private let signatureFactStore: SignatureFactStore
    private let transferHooks: AppTransferHooks
    private let writerAdmissionCheck: (() throws -> Void)?

    init(
        fileManager: FileManager = .default,
        portalCreationOverride: PortalCreationOverride? = nil,
        dockShortcutUpdater: DockShortcutUpdater? = nil,
        dockShortcutRetryUpdater: DockShortcutUpdater? = nil,
        transferStore: AppTransferStore = .shared,
        signatureFactStore: SignatureFactStore = SignatureFactStore(),
        transferHooks: AppTransferHooks = .init(),
        writerAdmissionCheck: (() throws -> Void)? = nil,
        runningApplications: @escaping () -> [AppRunningState.RunningApplication] = {
            NSWorkspace.shared.runningApplications.map {
                .init(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
            }
        }
    ) {
        self.fileManager = fileManager
        self.portalCreationOverride = portalCreationOverride
        self.dockShortcutUpdater = dockShortcutUpdater ?? { source, destination in
            try DockShortcutService.shared.redirectShortcuts(from: source, to: destination)
        }
        // Preserve injected effects in tests; production retries enforce the original bundle identity.
        self.dockShortcutRetryUpdater = dockShortcutRetryUpdater ?? dockShortcutUpdater ?? { source, destination in
            try DockShortcutService.shared.redirectShortcuts(from: source, to: destination, requiringBundleIdentity: true)
        }
        self.runningApplications = runningApplications
        self.transferStore = transferStore
        self.signatureFactStore = signatureFactStore
        self.transferHooks = transferHooks
        self.writerAdmissionCheck = writerAdmissionCheck
    }

    private func makeOperationLock() -> OperationLock {
        OperationLock(fileURL: transferStore.operationLockURL, writerAdmissionCheck: writerAdmissionCheck)
    }

    /// Synchronous entry actions fail promptly if another process owns the
    /// dataset. Only public operation boundaries acquire this lock.
    private func acquireOperationLock(at url: URL) throws -> OperationLock {
        let operationLock = makeOperationLock()
        guard operationLock.tryAcquire() else {
            throw AppTransferTransaction.failure(operationLock.admissionFailureReason
                ?? "其他操作正在使用应用记录，请稍后重试。".localized, at: url)
        }
        return operationLock
    }

    /// The object at a path is still the recorded filesystem object. Used after
    /// adoption, where reading and rewriting protection facts must not span a
    /// replacement or a remount.
    private func requireIdentity(_ expected: DataPathIdentity, at url: URL) throws {
        guard try expected.matchesFilesystemObject(DataPathIdentity.capture(url)) else {
            throw AppTransferTransaction.failure("路径对应的对象或磁盘已改变，已保留内容。".localized, at: url)
        }
    }

    private func recheckWriterAdmission() throws {
        if let writerAdmissionCheck { try writerAdmissionCheck() }
        else { try transferStore.recheckWriterAdmission() }
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
        let operationLock = makeOperationLock()
        guard await operationLock.acquire(timeout: OperationLock.appWaitTimeout) else {
            throw AppTransferTransaction.failure(operationLock.admissionFailureReason
                ?? "其他操作正在使用应用记录，请稍后重试。".localized, at: app.path)
        }
        defer { operationLock.release() }
        typealias Exclusion = AppSearchExclusionService
        if let reason = Exclusion.unsupportedReason(for: app) { throw Exclusion.failure(reason) }
        let source = app.path.standardizedFileURL
        guard source.deletingLastPathComponent() == externalRoot.standardizedFileURL
                || source.deletingLastPathComponent() == Exclusion.library(in: externalRoot).standardizedFileURL,
              source.resolvingSymlinksInPath() == source else {
            throw Exclusion.failure("套件目录可能包含文档，暂不自动排除。".localized)
        }
        let library = Exclusion.library(in: externalRoot)
        try Exclusion.prepareLibrary(library, fileManager: fileManager)
        let destination = library.appendingPathComponent(source.lastPathComponent)
        let records = try store.records().filter { $0.externalPath == source.path }
        let localURLs = Set(localEntries.map { $0.standardizedFileURL.path }
            + records.filter { !$0.isRestored }.map(\.localPath)).map { URL(fileURLWithPath: $0) }
        if let pending = try Exclusion.blockingJournal(in: library, affecting: [source, destination] + localURLs,
                                                      fileManager: fileManager) {
            throw Exclusion.failure(String(format: "转换未完成，已保留应用和恢复记录：%@".localized, pending.path))
        }
        if Exclusion.isExcluded(source) {
            // A previous relocation may have finished while Dock synchronization failed.
            // Retry only existing pins. If the old path has been reused, preserve that new app's pins.
            let previous = library.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent)
            let dockSource = (try? fileManager.attributesOfItem(atPath: previous.path)) == nil ? previous : source
            let dockOK = synchronizeDockShortcuts(from: dockSource, to: source,
                operationID: AppLogger.shared.makeOperationID(prefix: "search-exclusion-retry"), using: dockShortcutRetryUpdater)
            return .init(destination: source, dockSynchronized: dockOK)
        }
        // Only relocation requires quitting. Running an already excluded app does not undo completion.
        try requireNotRunning(app)
        guard (try? fileManager.attributesOfItem(atPath: destination.path)) == nil else {
            throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
        }
        guard let volume = try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw Exclusion.failure("无法确认真实应用身份，未更改存储位置。".localized)
        }
        let sourceIdentity = try Exclusion.FileIdentity.read(source, fileManager: fileManager)
        let sourcePlist = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        let bundleID = sourcePlist?["CFBundleIdentifier"] as? String
        guard records.allSatisfy({ ($0.volumeUUID == nil || $0.volumeUUID == volume)
            && ($0.targetBundleIdentifier == nil || $0.targetBundleIdentifier == bundleID) }) else {
            throw Exclusion.failure("无法确认真实应用身份，未更改存储位置。".localized)
        }
        let protection = AppUpdateProtectionStore(transferStore: transferStore)
        // The lock is AppPorts' own, and older versions never recorded it. Record
        // what is locked here so the relocation can suspend and restore exactly
        // those bits; a tree with no lock simply has nothing to record.
        let identityBeforeAdoption = try DataPathIdentity.capture(source)
        _ = try protection.adoptLegacyLock(source, evidence: .init(
            managedLocalEntry: localURLs.sorted(by: { $0.path < $1.path })
                .first { localPortalKind(at: $0, linkedTo: source) != nil },
            sameApplicationSource: nil))
        try requireIdentity(identityBeforeAdoption, at: source)
        let protectionRelocation = try protection.captureForExchange(at: source)
        let signatureRelocation = try signatureFactStore.captureRelocation(from: source, transferStore: transferStore)
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
        journal.updateProtectionRelocation = protectionRelocation
        journal.signatureFactRelocation = signatureRelocation
        try recheckWriterAdmission()
        try DurableFileIO.write(try JSONEncoder().encode(journal), to: journalURL)
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
            try recheckWriterAdmission()
            if let protectionRelocation { try protection.suspendForExchange(protectionRelocation, at: source) }
            try fileManager.moveItem(at: source, to: destination)
            moved = true
            journal.phase = "external-moved"
            try recheckWriterAdmission()
            try DurableFileIO.write(try JSONEncoder().encode(journal), to: journalURL)
            for portal in portals {
                try recheckWriterAdmission()
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
                        try recheckWriterAdmission()
                        try fileManager.moveItem(at: url, to: portal.backup)
                        backedUp.append(portal)
                        guard try Exclusion.FileIdentity.read(portal.backup, fileManager: fileManager) == portal.identity else {
                            throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
                        }
                        let newIdentity = try Exclusion.FileIdentity.read(portal.stage, fileManager: fileManager)
                        try recheckWriterAdmission()
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
            journal.phase = "portals-installed"
            try recheckWriterAdmission()
            try DurableFileIO.write(try JSONEncoder().encode(journal), to: journalURL)
            try store.retarget(from: source, to: destination, snapshots: records)
        } catch {
            AppLogger.shared.logError("应用索引排除转换失败，开始回滚", error: error,
                                      relatedURLs: [("source", source), ("journal", journalURL)])
            var recoveryFailed = false
            // Undo only files whose device/inode still matches our snapshot.
            for portal in backedUp.reversed() {
                do {
                    if let identity = installed[portal.local] {
                        try removeExclusionOwnedItem(at: portal.local, identity: identity)
                    }
                    try recheckWriterAdmission()
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
                    try recheckWriterAdmission()
                    try fileManager.moveItem(at: destination, to: source)
                } catch {
                    recoveryFailed = true
                    AppLogger.shared.logError("恢复外部应用位置失败，保留恢复记录", error: error, relatedURLs: [("journal", journalURL)])
                }
            }
            if protectionRelocation != nil, (try? Exclusion.FileIdentity.read(source, fileManager: fileManager)) == sourceIdentity {
                do {
                    try recheckWriterAdmission()
                    try protection.resume(source, requiringRecord: true)
                }
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
        do {
            journal.phase = "committed"
            try recheckWriterAdmission()
            try DurableFileIO.write(try JSONEncoder().encode(journal), to: journalURL)
            if let protectionRelocation { try protection.commitSameObjectMove(protectionRelocation, to: destination) }
            if let signatureRelocation { try signatureFactStore.commitRelocation(signatureRelocation, to: destination) }
        } catch {
            AppLogger.shared.logError("应用索引排除位置已切换，保护和签名记录仍待完成", error: error,
                                      relatedURLs: [("destination", destination), ("journal", journalURL)])
            throw Exclusion.failure(String(format: "转换未完成，已保留应用和恢复记录：%@".localized, journalURL.path))
        }
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
                try recheckWriterAdmission()
                try fileManager.moveItem(at: coordinated, to: quarantine)
                guard try Exclusion.FileIdentity.read(quarantine, fileManager: fileManager) == identity else {
                    // moveItem refuses to overwrite a file that appeared at the original path.
                    try recheckWriterAdmission()
                    try fileManager.moveItem(at: quarantine, to: coordinated)
                    throw Exclusion.failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
                }
                try recheckWriterAdmission()
                try fileManager.removeItem(at: quarantine)
            } catch {
                removalError = error
                AppLogger.shared.logError("清理入口时身份改变或删除失败，保留文件", error: error,
                                          relatedURLs: [("original", url), ("quarantine", quarantine)])
            }
        }
        if let error = removalError ?? coordinationError { throw error }
    }

    @discardableResult
    func moveAndLink(
        appToMove: AppItem,
        destinationURL: URL,
        isRunning: Bool,
        lockExternal: Bool = true,
        replaceExistingSameApplication: Bool = false,
        replacementChoice: ReplacementChoice? = nil,
        deleteSourceFallback: FinderRemover? = nil,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws -> AppTransferResult {
        try await Self.mutationCoordinator.begin()
        defer { Self.mutationCoordinator.end() }
        let operationLock = makeOperationLock()
        guard await operationLock.acquire(timeout: OperationLock.appWaitTimeout) else {
            throw AppTransferTransaction.failure(operationLock.admissionFailureReason
                ?? "其他操作正在使用应用记录，请稍后重试。".localized, at: appToMove.path)
        }
        defer { operationLock.release() }
        if isRunning { throw AppMoverError.appIsRunning }
        if AppSearchExclusionService.isExcluded(destinationURL) {
            if let reason = AppSearchExclusionService.unsupportedReason(for: appToMove) {
                throw AppSearchExclusionService.failure(reason)
            }
            try AppSearchExclusionService.prepareLibrary(destinationURL.deletingLastPathComponent(), fileManager: fileManager)
        }
        try Self.checkWritePermission(at: appToMove.path, fileManager: fileManager)
        let confirmedReplacement: ReplacementChoice?
        if let replacementChoice {
            guard let current = try self.replacementChoice(for: appToMove, destinationURL: destinationURL),
                  current.sourceURL == replacementChoice.sourceURL,
                  current.destinationURL == replacementChoice.destinationURL,
                  current.sourceIdentity.matchesFilesystemObject(replacementChoice.sourceIdentity),
                  current.destinationIdentity.matchesFilesystemObject(replacementChoice.destinationIdentity),
                  current.applicationIdentifiers == replacementChoice.applicationIdentifiers else {
                throw AppTransferTransaction.failure("确认后源应用或目标应用已改变，请重新选择替换。".localized, at: destinationURL)
            }
            confirmedReplacement = replacementChoice
        } else if replaceExistingSameApplication {
            confirmedReplacement = try self.replacementChoice(for: appToMove, destinationURL: destinationURL)
        } else { confirmedReplacement = nil }
        let mayReplace = externalTargetReplacementReason(for: appToMove, destinationURL: destinationURL) != nil
            || confirmedReplacement != nil
        // Re-migrating over a v1.9.0-locked external copy needs the same adoption
        // as a restore: without a provenance record the replacement's copy step
        // fails closed on the very lock this app already carries.
        if confirmedReplacement != nil {
            try adoptLegacyLockOnReplacement(of: appToMove.path, at: destinationURL)
        }
        let kind: LocalPortalKind = portalCreationOverride != nil ? .wholeAppSymlink
            : appToMove.usesFolderOperation ? .folderMirror : preferredPortalKind(for: appToMove.path)
        _ = retireUnrecoverableTransfersWhileLocked()
        let result = try await transferTransaction().start(app: appToMove, destination: destinationURL, direction: .migrate,
            portalKind: kind.rawValue, protectDestination: lockExternal && needsUpdateProtection(appToMove),
            mayReplaceDestination: mayReplace, replacementChoice: confirmedReplacement, legacyPortals: [], progress: progressHandler)
        if result.isSwitchComplete {
            if appToMove.usesFolderOperation { refreshLaunchServicesRecursive(for: appToMove.path) }
            else { refreshLaunchServices(for: appToMove.path) }
        }
        return result
    }

    /// A retained external copy still carries AppPorts' update lock and is about
    /// to be replaced by a verified copy of the same application. Record what is
    /// locked so the replacement's removal step can proceed.
    private func adoptLegacyLockOnReplacement(of sourceURL: URL, at destinationURL: URL) throws {
        guard (try? SignatureSnapshot.info(at: destinationURL).st_flags & UInt32(UF_IMMUTABLE)) ?? 0 != 0 else { return }
        let protection = AppUpdateProtectionStore(transferStore: transferStore)
        let identity = try DataPathIdentity.capture(destinationURL)
        _ = try protection.adoptLegacyLock(destinationURL, evidence: .init(managedLocalEntry: nil,
            sameApplicationSource: sourceURL))
        try requireIdentity(identity, at: destinationURL)
    }

    private func needsUpdateProtection(_ app: AppItem) -> Bool {
        if !app.usesFolderOperation { return needsUchgLock(at: app.path) }
        return ((try? fileManager.contentsOfDirectory(at: app.path, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "app" }.contains { needsUchgLock(at: $0) }
    }

    func pendingTransfers() throws -> [AppTransferRecord] { try transferTransaction().pending() }

    func pendingTransferInspection() throws -> AppTransferStore.Inventory {
        let transfers = try transferTransaction().pendingInspection()
        let issues: [AppTransferRecordIssue]
        do {
            issues = try AppUpdateProtectionStore(transferStore: transferStore).inventory().issues.map(\.diagnostic)
        } catch {
            issues = [.init(url: transferStore.directoryURL.appendingPathComponent("update-protection"),
                appName: "应用更新保护来源无法确认。".localized,
                message: "操作记录读取失败：".localized + error.localizedDescription, knownPaths: [])]
        }
        return .init(records: transfers.records, issues: transfers.issues + issues)
    }

    @discardableResult
    func retryTransfer(operationID: UUID, progressHandler: FileCopier.ProgressHandler? = nil) async throws -> AppTransferResult {
        try await Self.mutationCoordinator.begin()
        defer { Self.mutationCoordinator.end() }
        let operationLock = makeOperationLock()
        guard await operationLock.acquire(timeout: OperationLock.appWaitTimeout) else {
            throw AppTransferTransaction.failure(operationLock.admissionFailureReason
                ?? "其他操作正在使用应用记录，请稍后重试。".localized, at: transferStore.directoryURL)
        }
        defer { operationLock.release() }
        let record = try transferStore.record(operationID)
        let ejection = try DiskEjectionPauseStore(directory: transferStore.operationLockURL.deletingLastPathComponent()).snapshot()
        guard !ejection.blocks(volumeUUIDs: [record.sourceIdentity.volumeUUID,
            record.sourceParentIdentity.volumeUUID, record.destinationParentIdentity.volumeUUID],
            paths: [record.sourcePath, record.destinationPath, record.stagePath]) else { throw DiskEjectionError.paused }
        return try await transferTransaction(retrying: true).resume(operationID, progress: progressHandler)
    }

    /// User-requested recovery bypasses content verification, never the operation locks.
    func recoverTransferIgnoringErrors(operationID: UUID, restore: Bool,
                                       progress: DataTransferProgress) async throws -> String {
        try await Self.mutationCoordinator.begin()
        defer { Self.mutationCoordinator.end() }
        let operationLock = makeOperationLock()
        guard await operationLock.acquire(timeout: OperationLock.appWaitTimeout) else {
            throw AppTransferTransaction.failure(operationLock.admissionFailureReason
                ?? "其他操作正在使用应用记录，请稍后重试。".localized, at: transferStore.directoryURL)
        }
        defer { operationLock.release() }
        return try await AppTransferForceRecovery(store: transferStore).run(
            operationID: operationID, restore: restore, progress: progress)
    }

    @discardableResult
    func cancelTransfer(operationID: UUID) async throws -> AppTransferResult {
        try await Self.mutationCoordinator.begin()
        defer { Self.mutationCoordinator.end() }
        let operationLock = makeOperationLock()
        guard await operationLock.acquire(timeout: OperationLock.appWaitTimeout) else {
            throw AppTransferTransaction.failure(operationLock.admissionFailureReason
                ?? "其他操作正在使用应用记录，请稍后重试。".localized, at: transferStore.directoryURL)
        }
        defer { operationLock.release() }
        return try transferTransaction().cancel(operationID)
    }

    /// What maintenance should do with one journal. A record that can still
    /// advance is retried; one whose facts already contradict the disk cannot
    /// advance, so it is retired automatically.
    enum TransferRetryDisposition: Sendable {
        case retry
        /// Retrying cannot change the outcome. The caller retires the record
        /// itself — it is never handed to the user as a task.
        case terminal(String)

        var isTerminal: Bool {
            if case .terminal = self { return true }
            return false
        }
    }

    /// Decide from disk facts, never from the last error text. This is the whole
    /// triage: everything that can still progress is retried forever (that is
    /// what maintenance is for), and anything that provably cannot is closed out
    /// by `retireUnrecoverableTransfers()`. The user is not part of this loop —
    /// both outcomes are AppPorts' own bookkeeping, and neither one needs a
    /// judgement only the user could make.
    func retryDisposition(for record: AppTransferRecord) -> TransferRetryDisposition {
        if record.phase == .cancelled {
            return .terminal("本次尝试已结束，保留的材料已列出。")
        }
        guard !record.isSwitchComplete else { return .retry }
        let source = URL(fileURLWithPath: record.sourcePath)
        let destination = URL(fileURLWithPath: record.destinationPath)
        // Both original parents must be available before interpreting absence.
        // An offline volume or unreadable path is still recoverable.
        guard let sourceParent = try? DataPathIdentity.capture(source.deletingLastPathComponent()),
              sourceParent.matchesFilesystemObject(record.sourceParentIdentity),
              let destinationParent = try? DataPathIdentity.capture(destination.deletingLastPathComponent()),
              destinationParent.matchesFilesystemObject(record.destinationParentIdentity) else { return .retry }
        do {
            let object = try DataPathIdentity.capture(source)
            // An exchanged local portal can outlive commit bookkeeping. If its
            // activation cannot currently be inspected, keep the cleanup journal.
            if let portal = record.portalIdentity, object.matchesFilesystemObject(portal) { return .retry }
            guard object.matchesFilesystemObject(record.sourceIdentity) else {
                return .terminal("记录中的源应用已被替换。")
            }
        } catch {
            guard (error as? POSIXError)?.code == .ENOENT else { return .retry }
            return .terminal("记录中的源应用已不在原位。")
        }
        if AppTransferJournalIntegrity.missingManifests(for: record, store: transferStore,
                                                       onlyConfirmedMissing: true) {
            return .terminal("校验清单缺失，记录无法再次验证。")
        }
        // Before a candidate baseline is saved, copying can simply start again.
        // Afterwards, resume requires that exact object, either staged or (for
        // migration) already published at the external destination.
        if record.hasCandidateBaseline, let identity = record.candidateIdentity {
            var candidates = [record.candidateURL]
            if record.direction == .migrate && record.switchIntentRecorded { candidates.append(destination) }
            for url in candidates {
                do {
                    if try DataPathIdentity.capture(url).matchesFilesystemObject(identity) { return .retry }
                } catch {
                    guard (error as? POSIXError)?.code == .ENOENT else { return .retry }
                }
            }
            return .terminal("已校验的暂存副本已丢失或被替换，旧记录已归档，可重新操作。")
        }
        return .retry
    }

    /// Close out journals that can no longer advance, so they stop blocking their
    /// paths. Only bookkeeping moves: the record and its manifests are archived
    /// under `app-transfers/archived/`, while every application, retained copy
    /// and staging object stays exactly where it is. That is the same outcome a
    /// user would reach by hand, minus the hand — nothing is deleted that
    /// AppPorts did not create, and nothing is decided that could go either way.
    ///
    /// A committed transfer is never retired: its remaining work is deleting a
    /// copy under its own verified manifest, and retrying performs that safely.
    @discardableResult
    func retireUnrecoverableTransfers() -> [String] {
        do { try Self.mutationCoordinator.beginSynchronously() } catch { return [] }
        defer { Self.mutationCoordinator.end() }
        let operationLock = makeOperationLock()
        guard operationLock.tryAcquire() else { return [] }
        defer { operationLock.release() }
        return retireUnrecoverableTransfersWhileLocked()
    }

    /// Caller holds both the mutation coordinator and the operation lock.
    private func retireUnrecoverableTransfersWhileLocked() -> [String] {
        guard let inventory = try? pendingTransferInspection() else { return [] }
        var notes: [String] = []
        for record in inventory.records {
            guard case .terminal(let reason) = retryDisposition(for: record), !record.isSwitchComplete else { continue }
            do {
                guard try transferStore.archive(record.operationID) != nil else { continue }
                // The diagnostic package deliberately ships no record files, so
                // the facts that explain *why* the record could not advance have
                // to travel in the log. Without them the report only carries the
                // conclusion ("manifest missing") and not the evidence.
                AppLogger.shared.logContext("应用位置记录已自动收束，保留所有副本",
                    details: [("operation_id", record.operationID.uuidString), ("app", record.appName),
                              ("direction", record.direction.rawValue), ("phase", record.phase.rawValue),
                              ("reason", reason),
                              ("switch_complete", String(record.isSwitchComplete)),
                              ("has_source_baseline", String(record.hasSourceBaseline)),
                              ("has_candidate_baseline", String(record.hasCandidateBaseline)),
                              ("has_existing_baseline", String(record.hasExistingDestinationBaseline)),
                              ("existing_destination", String(record.existingDestinationIdentity != nil)),
                              ("cleanup_items", "total=\(record.cleanupItems.count) "
                                  + "incomplete=\(record.cleanupItems.filter { !$0.completed }.count)"),
                              ("legacy_portals", "total=\(record.legacyPortals.count) "
                                  + "unretired=\(record.legacyPortals.filter { !$0.retired }.count)"),
                              ("signature_facts_committed", String(record.signatureFactsCommitted)),
                              ("destination_protected", String(record.destinationProtected)),
                              ("unclaimed_paths", String(record.unclaimedPaths.count)),
                              ("source_path", record.sourcePath),
                              ("destination_path", record.activeDestinationPath)],
                    level: "WARN")
                notes.append(record.appName + "：" + reason)
            } catch {
                AppLogger.shared.logError("无法收束应用位置记录，保留记录", error: error,
                    relatedURLs: [("record", transferStore.directoryURL.appendingPathComponent(
                        record.operationID.uuidString + ".plist"))])
            }
        }
        return notes
    }

    private func transferTransaction(retrying: Bool = false) -> AppTransferTransaction {
        AppTransferTransaction(store: transferStore, fileManager: fileManager, facts: signatureFactStore,
            buildPortal: { record, localURL in
                let external = URL(fileURLWithPath: record.destinationPath)
                if let override = self.portalCreationOverride {
                    try override(AppItem(name: record.appName, path: localURL, status: AppStatus.local,
                                         isFolder: record.usesFolderOperation), external)
                } else {
                    guard let raw = record.portalKind, let kind = LocalPortalKind(rawValue: raw) else {
                        throw AppTransferTransaction.failure("入口类型记录不完整。".localized, at: localURL)
                    }
                    try self.createLocalPortal(at: localURL, pointingTo: external, portalKind: kind,
                                               operationID: record.operationID.uuidString)
                }
            }, portalMatches: { self.localPortalKind(at: $0, linkedTo: $1) != nil },
            updateDock: retrying ? dockShortcutRetryUpdater : dockShortcutUpdater,
            runningApplications: runningApplications, hooks: transferHooks, allowsAdministratorPrompt: !retrying)
    }

    private func sameApplicationContainer(_ source: URL, _ destination: URL, folder: Bool) -> Bool {
        func identifier(_ url: URL) -> String? {
            guard let value = applicationMetadata(at: url)?["CFBundleIdentifier"] as? String, !value.isEmpty else { return nil }
            return value
        }
        if !folder { return identifier(source) != nil && identifier(source) == identifier(destination) }
        guard let sourceApps = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension.lowercased() == "app" }),
              let targetApps = try? fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension.lowercased() == "app" }),
              !sourceApps.isEmpty, Set(sourceApps.map(\.lastPathComponent)) == Set(targetApps.map(\.lastPathComponent)) else { return false }
        return sourceApps.allSatisfy { app in
            let other = destination.appendingPathComponent(app.lastPathComponent)
            return identifier(app) != nil && identifier(app) == identifier(other)
        }
    }

    /// Read-only choice for a UI confirmation. Root links/portals and unrelated
    /// application identities never qualify as a same-application replacement.
    func replacementChoice(for app: AppItem, destinationURL: URL) throws -> ReplacementChoice? {
        func canonical(_ url: URL) -> URL {
            url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL
        }
        let source = canonical(app.path), destination = canonical(destinationURL)
        guard source != destination, try AppTransferStore.exists(destination),
              try SignatureSnapshot.info(at: source).st_mode & S_IFMT == S_IFDIR,
              try SignatureSnapshot.info(at: destination).st_mode & S_IFMT == S_IFDIR,
              localPortalKind(at: destination) == nil else { return nil }
        let sourceIdentity = try DataPathIdentity.capture(source), destinationIdentity = try DataPathIdentity.capture(destination)
        guard sameApplicationContainer(source, destination, folder: app.usesFolderOperation) else { return nil }
        let paths = app.usesFolderOperation
            ? try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "app" }.map(\.lastPathComponent).sorted()
            : [""]
        var identifiers: [String: String] = [:]
        var comparisons: Set<ReplacementChoice.VersionComparison> = []
        for path in paths {
            let left = applicationMetadata(at: path.isEmpty ? source : source.appendingPathComponent(path)) ?? [:]
            let right = applicationMetadata(at: path.isEmpty ? destination : destination.appendingPathComponent(path)) ?? [:]
            guard let identifier = left["CFBundleIdentifier"] as? String, !identifier.isEmpty,
                  identifier == right["CFBundleIdentifier"] as? String else { return nil }
            identifiers[path] = identifier
            comparisons.insert(compareVersions(left, right))
        }
        guard sourceIdentity.matchesFilesystemObject(try DataPathIdentity.capture(source)),
              destinationIdentity.matchesFilesystemObject(try DataPathIdentity.capture(destination)) else {
            throw AppTransferTransaction.failure("检查替换选项时应用对象已改变，请重新检查。".localized, at: destination)
        }
        let differing = comparisons.subtracting([.same])
        let comparison: ReplacementChoice.VersionComparison = differing.isEmpty ? .same
            : differing.count == 1 ? differing.first! : .unrecognized
        return ReplacementChoice(id: UUID(), sourceURL: source, destinationURL: destination,
            sourceIdentity: sourceIdentity, destinationIdentity: destinationIdentity,
            applicationIdentifiers: identifiers, versionComparison: comparison)
    }

    private func compareVersions(_ source: [String: Any], _ destination: [String: Any]) -> ReplacementChoice.VersionComparison {
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            guard let left = source[key] as? String, let right = destination[key] as? String,
                  !left.isEmpty, !right.isEmpty,
                  left.allSatisfy({ $0.isNumber || $0 == "." }), right.allSatisfy({ $0.isNumber || $0 == "." }) else { return .unrecognized }
            let comparison = left.compare(right, options: .numeric)
            if comparison != .orderedSame { return comparison == .orderedDescending ? .newer : .older }
        }
        return .same
    }

    /// Foreground actions wait for maintenance, then resume the exact unfinished
    /// migration with permission to show an administrator prompt.
    func linkAppWhenReady(appToLink: AppItem, destinationURL: URL) async throws {
        try await Self.mutationCoordinator.begin()
        defer { Self.mutationCoordinator.end() }
        let operationLock = makeOperationLock()
        guard await operationLock.acquire(timeout: OperationLock.appWaitTimeout) else {
            throw AppTransferTransaction.failure(operationLock.admissionFailureReason
                ?? "其他操作正在使用应用记录，请稍后重试。".localized, at: destinationURL)
        }
        defer { operationLock.release() }
        let resumed = try await finishPendingMigration(external: appToLink.path, local: destinationURL)
        // Resuming may already have installed the requested entry. Do not
        // replace an entry still owned by its transfer's cleanup journal.
        if resumed && localPortalKind(at: destinationURL, linkedTo: appToLink.path) != nil { return }
        try linkAppWhileLocked(appToLink: appToLink, destinationURL: destinationURL)
    }

    func linkApp(appToLink: AppItem, destinationURL: URL) throws {
        try Self.mutationCoordinator.beginSynchronously()
        defer { Self.mutationCoordinator.end() }
        let operationLock = try acquireOperationLock(at: destinationURL)
        defer { operationLock.release() }
        try linkAppWhileLocked(appToLink: appToLink, destinationURL: destinationURL)
    }

    private func linkAppWhileLocked(appToLink: AppItem, destinationURL: URL) throws {
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
            try recheckWriterAdmission()
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
                    try recheckWriterAdmission()
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
        try recheckWriterAdmission()
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
        let operationLock = try acquireOperationLock(at: app.path)
        defer { operationLock.release() }
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

        try recheckWriterAdmission()
        try fileManager.removeItem(at: app.path)

        AppLogger.shared.logPathState("删除后-本地入口[\(operationID)]", url: app.path)
        operationResult = "success"
    }

    struct RestoreResult {
        let retiredLocalPortalURLs: [URL]
        let externalSourceRemains: Bool
        let transferResult: AppTransferResult
        var warnings: [String] { transferResult.warnings }
        var pendingTasks: [AppTransferPendingTask] { transferResult.pendingTasks }
        var isSwitchComplete: Bool { transferResult.isSwitchComplete }
    }

    @discardableResult
    func moveBack(
        app: AppItem,
        localDestinationURL: URL,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws -> RestoreResult {
        try await Self.mutationCoordinator.begin()
        defer { Self.mutationCoordinator.end() }
        let operationLock = makeOperationLock()
        guard await operationLock.acquire(timeout: OperationLock.appWaitTimeout) else {
            throw AppTransferTransaction.failure(operationLock.admissionFailureReason
                ?? "其他操作正在使用应用记录，请稍后重试。".localized, at: app.path)
        }
        defer { operationLock.release() }
        _ = try await finishPendingMigration(external: app.path, local: localDestinationURL, progress: progressHandler)
        try Self.checkWritePermission(at: localDestinationURL, fileManager: fileManager)
        let existing = localPortalKind(at: localDestinationURL, linkedTo: app.path)
        if existing == .folderMirror {
            try requireOnlyManagedFolderEntries(at: localDestinationURL, externalFolder: app.path)
        }
        let portals = app.usesFolderOperation
            ? folderPortalSnapshots(for: app.path, localAppsDir: localDestinationURL.deletingLastPathComponent())
                .map { ($0.localURL, $0.externalURL) } : []
        _ = retireUnrecoverableTransfersWhileLocked()
        let result = try await transferTransaction().start(app: app, destination: localDestinationURL, direction: .restore,
            portalKind: nil, protectDestination: false, mayReplaceDestination: existing != nil,
            legacyPortals: portals, progress: progressHandler)
        if result.isSwitchComplete {
            if app.usesFolderOperation { refreshLaunchServicesRecursive(for: localDestinationURL) }
            else { refreshLaunchServices(for: localDestinationURL) }
        }
        return RestoreResult(retiredLocalPortalURLs: result.retiredLocalPortalURLs,
                             externalSourceRemains: result.externalSourceRemains, transferResult: result)
    }

    /// Caller holds the coordinator and operation lock. Only the exact inverse
    /// migration is eligible; unrelated/overlapping records stay fail-closed.
    private func finishPendingMigration(external: URL, local: URL,
                                        progress: FileCopier.ProgressHandler? = nil) async throws -> Bool {
        _ = retireUnrecoverableTransfersWhileLocked()
        var resumed = false
        for record in try transferStore.inventory().records where record.direction == .migrate
            && !record.isSwitchComplete && record.phase != .cancelled
            && record.sourcePath == local.standardizedFileURL.path
            && record.destinationPath == external.standardizedFileURL.path {
            try AppTransferJournalIntegrity.requireVerifiedManifests(for: record, store: transferStore)
            let result = try await transferTransaction().resume(record.operationID, progress: progress)
            guard result.isSwitchComplete else {
                throw AppTransferTransaction.failure(result.pendingMessage ?? record.recoverableReason ??
                    "此位置的上次操作尚未完成。AppPorts 已保留数据并会继续尝试，请根据下面的原因处理后重试。".localized,
                    at: external)
            }
            resumed = true
        }
        return resumed
    }

    /// A folder marker identifies the entry, but does not authorize deleting
    /// personal real files later placed beside the managed links and app stubs.
    private func requireOnlyManagedFolderEntries(at localFolder: URL, externalFolder: URL) throws {
        for entry in try fileManager.contentsOfDirectory(at: localFolder, includingPropertiesForKeys: nil) {
            if [Self.folderPortalMarkerName, ".DS_Store"].contains(entry.lastPathComponent) { continue }
            let external = externalFolder.appendingPathComponent(entry.lastPathComponent).standardizedFileURL
            if resolveSymlinkDestination(at: entry) == external { continue }
            if entry.pathExtension.lowercased() == "app", localPortalKind(at: entry, linkedTo: external) != nil { continue }
            throw AppTransferTransaction.failure("本地套件入口包含个人文件或其他真实内容，请先将其移到其他位置后再还原。".localized, at: entry)
        }
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
        try Self.mutationCoordinator.beginSynchronously()
        defer { Self.mutationCoordinator.end() }
        let operationLock = try acquireOperationLock(at: app.path)
        defer { operationLock.release() }
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
        try Task.checkCancellation()
        try recheckWriterAdmission()
        return try dockShortcutUpdater(sourceURL, destinationURL)
    }

    /// Dock 属于迁移后的附加同步：失败应可重试，不能回滚已经完整迁移的应用。
    @discardableResult
    private func synchronizeDockShortcuts(from sourceURL: URL, to destinationURL: URL, operationID: String,
                                          using updater: DockShortcutUpdater? = nil) -> Bool {
        do {
            try recheckWriterAdmission()
            let updatedCount = try (updater ?? dockShortcutUpdater)(sourceURL, destinationURL)
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


    func lockExternalApp(at url: URL) {
        do {
            try Self.mutationCoordinator.beginSynchronously()
            defer { Self.mutationCoordinator.end() }
            let operationLock = try acquireOperationLock(at: url)
            defer { operationLock.release() }
            try AppUpdateProtectionStore(transferStore: transferStore).protect(url)
        }
        catch { AppLogger.shared.logError("应用更新保护未完成", error: error, relatedURLs: [("app", url)]) }
    }

    @discardableResult
    func unlockExternalApp(at url: URL) -> Bool {
        do {
            try Self.mutationCoordinator.beginSynchronously()
            defer { Self.mutationCoordinator.end() }
            let operationLock = try acquireOperationLock(at: url)
            defer { operationLock.release() }
            let protection = AppUpdateProtectionStore(transferStore: transferStore)
            let identity = try DataPathIdentity.capture(url)
            _ = try protection.suspend(url)
            try protection.forget(path: url.path, identity: identity)
            return true
        } catch {
            AppLogger.shared.logError("无法撤销应用更新保护；已有未知锁保持不变", error: error, relatedURLs: [("app", url)])
            return false
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
        try recheckWriterAdmission()
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
        try recheckWriterAdmission()
        try fm.createDirectory(at: localFolderURL, withIntermediateDirectories: false, attributes: nil)

        let entries = (try? fm.contentsOfDirectory(
            at: externalFolderURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []

        var stubCount = 0
        var linkCount = 0
        for entry in entries {
            try recheckWriterAdmission()
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
                    try recheckWriterAdmission()
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
        try recheckWriterAdmission()
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        // Prepare every entry before installing any of them. Invalid resources or
        // signing failures leave the original folder completely unchanged.
        for external in missing {
            try recheckWriterAdmission()
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
                try recheckWriterAdmission()
                guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, local.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                installed.append((local, identity))
            }
        } catch {
            for (local, identity) in installed.reversed() {
                if let current = try? fm.attributesOfItem(atPath: local.path)[.systemFileNumber] as? NSNumber,
                   current == identity {
                    do {
                        try recheckWriterAdmission()
                        try fm.removeItem(at: local)
                    }
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
        try recheckWriterAdmission()
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
        let operationLock = makeOperationLock()
        guard operationLock.tryAcquire() else { return }
        defer { operationLock.release() }
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
        try recheckWriterAdmission()
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

    /// macOS 应用的 Stub Portal. The private workspace owns only newly created files.
    private func createMacOSStubPortal(at destinationURL: URL, pointingTo externalURL: URL, register: Bool = true) throws {
        try recheckWriterAdmission()
        let localURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".appports-create-\(UUID().uuidString).app")
        let stage = try PortalStaging(at: localURL)
        defer { stage.cleanup() }
        do {
            let localContents = localURL.appendingPathComponent("Contents")
            let localMacOS = localContents.appendingPathComponent("MacOS")
            let localResources = localContents.appendingPathComponent("Resources")
            try stage.createDirectory("Contents")
            try stage.createDirectory("Contents/MacOS")
            try stage.createDirectory("Contents/Resources")
            try copyNativeLauncher(to: localMacOS, resourcesDir: localResources, externalURL: externalURL)
            try stage.recordGeneratedFiles(replacing: ["Contents/MacOS/launcher", "Contents/Resources/real_app_path.txt"])

            let externalContents = externalURL.appendingPathComponent("Contents")
            let pkgInfo = externalContents.appendingPathComponent("PkgInfo")
            var info = stat()
            if lstat(pkgInfo.path, &info) == 0 {
                let resolved = pkgInfo.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(externalURL.resolvingSymlinksInPath().path + "/"),
                      try PortalStaging.info(resolved).st_mode & S_IFMT == S_IFREG else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                try stage.copyFile(from: resolved, relativePath: "Contents/PkgInfo")
            } else if errno != ENOENT { throw PortalStaging.posixError(pkgInfo) }

            for warning in try PortalPresentation.write(from: externalContents, to: localContents) {
                AppLogger.shared.log(warning, level: "WARN")
            }
            try stage.recordPresentationFiles()
            try signAndVerifyPortal(at: localURL)
            try stage.recordGeneratedFiles(replacing: ["Contents/_CodeSignature", "Contents/MacOS/launcher"])
            try stage.prepareForInstall()
            try recheckWriterAdmission()
            guard renameatx_np(AT_FDCWD, localURL.path, AT_FDCWD, destinationURL.path, UInt32(RENAME_EXCL)) == 0 else {
                throw PortalStaging.posixError(destinationURL)
            }
            stage.relinquish()
            if register { refreshLaunchServices(for: destinationURL) }
            AppLogger.shared.log("已创建 macOS Stub Portal: \(destinationURL.lastPathComponent) -> \(externalURL.path)")
        } catch {
            AppLogger.shared.logError("创建应用入口失败", error: error, relatedURLs: [("stage", localURL), ("external", externalURL)])
            throw error
        }
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
        try signAndVerifyPortal(at: localURL)

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
        let operationLock = makeOperationLock()
        guard operationLock.tryAcquire() else { return false }
        defer { operationLock.release() }
        return refreshExistingStubPortal(at: localURL, from: externalURL, force: force)
    }

    @discardableResult
    private func refreshExistingStubPortal(at localURL: URL, from externalURL: URL, force: Bool = false) -> Bool {
        guard AppPortalMaintenance.targetIdentityMatches(localURL: localURL, externalURL: externalURL),
              hasRealStubStorage(at: localURL),
              localPortalKind(at: localURL, linkedTo: externalURL) == .stubPortal,
              let resolved = try? CodeSigner.resolveAppURL(at: localURL),
              resolved.resolvingSymlinksInPath() == externalURL.resolvingSymlinksInPath() else { return false }
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
        let stageURL = localURL.deletingLastPathComponent()
            .appendingPathComponent(".appports-refresh-\(UUID().uuidString).app")
        do {
            try recheckWriterAdmission()
            let original = try PortalStaging.snapshot(localURL)
            let stage = try PortalStaging(at: stageURL)
            defer { stage.cleanup() }
            // Copy bytes into independent files. Never inherit uchg or hard links from the old portal.
            try stage.copyContents(from: localURL, snapshot: original)
            let stagedContents = stageURL.appendingPathComponent("Contents")
            let stagedMacOS = stagedContents.appendingPathComponent("MacOS")
            try fileManager.removeItem(at: stagedMacOS.appendingPathComponent("launcher"))
            try copyNativeLauncher(to: stagedMacOS,
                                   resourcesDir: stagedContents.appendingPathComponent("Resources"),
                                   externalURL: externalURL)
            try stage.recordGeneratedFiles(replacing: ["Contents/MacOS/launcher", "Contents/Resources/real_app_path.txt"])
            for warning in try PortalPresentation.write(from: externalContents, to: stageURL.appendingPathComponent("Contents")) {
                AppLogger.shared.log(warning, level: "WARN")
            }
            try stage.recordPresentationFiles()
            try signAndVerifyPortal(at: stageURL)
            try stage.recordGeneratedFiles(replacing: ["Contents/_CodeSignature", "Contents/MacOS/launcher"])
            try stage.prepareForInstall()
            var coordinationError: NSError?
            var commitError: Error?
            var committed = false
            NSFileCoordinator().coordinate(writingItemAt: localURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                do {
                    guard AppPortalMaintenance.targetIdentityMatches(localURL: coordinatedURL, externalURL: externalURL),
                          hasRealStubStorage(at: coordinatedURL),
                          localPortalKind(at: coordinatedURL, linkedTo: externalURL) == .stubPortal else { return }
                    // Check the entire old tree, not just its root inode, before replacing it.
                    guard try PortalStaging.snapshot(coordinatedURL) == original else { return }
                    try stage.validate()
                    try recheckWriterAdmission()
                    if renameatx_np(AT_FDCWD, stageURL.path, AT_FDCWD, coordinatedURL.path, UInt32(RENAME_SWAP)) != 0 {
                        throw PortalStaging.posixError(coordinatedURL)
                    }
                    stage.adoptExchangedTree(original)
                    committed = true
                } catch { commitError = error }
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
        try recheckWriterAdmission()
        // codesign may write into _CodeSignature; it must never be a mirrored directory.
        let signature = appURL.appendingPathComponent("Contents/_CodeSignature")
        var signatureInfo = stat()
        if lstat(signature.path, &signatureInfo) == 0, signatureInfo.st_mode & S_IFMT != S_IFDIR {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        for entry in try PortalStaging.snapshot(appURL).values where entry.kind == S_IFREG {
            guard entry.links == 1 else { throw CocoaError(.fileWriteNoPermission) }
        }
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
            try recheckWriterAdmission()
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
            // A script fallback cannot participate in launch protection.
            // Preserve the existing portal when its replacement is unavailable.
            throw CocoaError(.fileReadNoSuchFile)
        }
        let launcherPath = macosDir.appendingPathComponent("launcher")
        try fileManager.copyItem(at: bundledLauncher, to: launcherPath)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath.path)

        // 写入 real_app_path.txt，原生 launcher 读取此文件获取真实应用路径
        let realAppPathFile = resourcesDir.appendingPathComponent("real_app_path.txt")
        try externalURL.path.write(to: realAppPathFile, atomically: true, encoding: .utf8)
    }

    /// iOS stub keeps its launch path, but shares the native localized error dialog.
    private func writeBashLauncher(at macosDir: URL, externalURL: URL) throws {
        let launcherPath = macosDir.appendingPathComponent("launcher")
        guard let bundledLauncher = Bundle.main.url(forResource: "StubLauncherBinary", withExtension: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let dialogPath = macosDir.appendingPathComponent("storage-dialog")
        try fileManager.copyItem(at: bundledLauncher, to: dialogPath)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dialogPath.path)
        let script = """
            #!/bin/bash
            REAL_APP='\(externalURL.path.replacingOccurrences(of: "'", with: "'\\''"))'
            if [ -d "$REAL_APP" ]; then
                open "$REAL_APP"
            else
                "$(dirname "$0")/storage-dialog" --storage-missing
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

/// Tracks the files of one portal workspace. Source flags and hard links never enter new files.
private final class PortalStaging {
    struct Entry: Equatable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t
        let links: nlink_t
        let flags: UInt32
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; kind = value.st_mode & S_IFMT
            links = value.st_nlink; flags = value.st_flags; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        }
        func sameIdentity(_ other: Entry) -> Bool { device == other.device && inode == other.inode && kind == other.kind }
    }
    let url: URL
    private var owned: [String: Entry] = [:]
    private var active = true

    init(at url: URL) throws {
        self.url = url
        guard mkdir(url.path, 0o700) == 0 else { throw Self.posixError(url) }
        owned[""] = Entry(try Self.info(url))
    }

    static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
    static func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw posixError(url) }
        return value
    }
    static func snapshot(_ root: URL) throws -> [String: Entry] {
        var entries: [String: Entry] = [:]
        func visit(_ relative: String) throws {
            let path = relative.isEmpty ? root : root.appendingPathComponent(relative)
            let value = try info(path)
            entries[relative] = Entry(value)
            if value.st_mode & S_IFMT == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: path.path).sorted() {
                    try visit(relative.isEmpty ? name : relative + "/" + name)
                }
            }
        }
        try visit("")
        return entries
    }

    private func verifyParents(of relative: String) throws {
        var parts = relative.split(separator: "/").map(String.init)
        parts.removeLast()
        for count in 0...parts.count {
            let key = parts.prefix(count).joined(separator: "/")
            let path = key.isEmpty ? url : url.appendingPathComponent(key)
            guard let expected = owned[key], expected.kind == S_IFDIR,
                  expected.sameIdentity(Entry(try Self.info(path))),
                  path.resolvingSymlinksInPath().standardizedFileURL.path == path.standardizedFileURL.path else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
    }

    func createDirectory(_ relative: String) throws {
        try verifyParents(of: relative)
        let path = url.appendingPathComponent(relative)
        guard mkdir(path.path, 0o755) == 0 else { throw Self.posixError(path) }
        owned[relative] = Entry(try Self.info(path))
    }

    func copyFile(from source: URL, relativePath: String, expected: Entry? = nil) throws {
        try verifyParents(of: relativePath)
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw Self.posixError(source) }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        defer { try? reader.close() }
        var before = stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              expected == nil || expected == Entry(before) else { throw CocoaError(.fileReadInvalidFileName) }
        let target = url.appendingPathComponent(relativePath)
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw Self.posixError(target) }
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        var created = stat()
        guard fstat(output, &created) == 0 else { try? writer.close(); throw Self.posixError(target) }
        owned[relativePath] = Entry(created)
        defer {
            // Record the same open file, including a partial write, without adopting a path replacement.
            var current = stat()
            if fstat(output, &current) == 0 { owned[relativePath] = Entry(current) }
            try? writer.close()
        }
        while let bytes = try reader.read(upToCount: 1_048_576), !bytes.isEmpty { try writer.write(contentsOf: bytes) }
        var after = stat()
        guard fstat(input, &after) == 0, Entry(after) == Entry(before) else { throw CocoaError(.fileReadCorruptFile) }
        guard fchmod(output, before.st_mode & 0o777) == 0 else { throw Self.posixError(target) }
    }

    func copyContents(from source: URL, snapshot: [String: Entry]) throws {
        for relative in snapshot.keys.sorted() where !relative.isEmpty {
            // A new signature is generated; no old signature path can redirect codesign.
            if relative == "Contents/_CodeSignature" || relative.hasPrefix("Contents/_CodeSignature/") { continue }
            let sourcePath = source.appendingPathComponent(relative)
            let expected = snapshot[relative]!
            guard Entry(try Self.info(sourcePath)) == expected else { throw CocoaError(.fileReadCorruptFile) }
            switch expected.kind {
            case S_IFDIR: try createDirectory(relative)
            case S_IFREG: try copyFile(from: sourcePath, relativePath: relative, expected: expected)
            case S_IFLNK:
                try verifyParents(of: relative)
                let target = url.appendingPathComponent(relative)
                let link = try FileManager.default.destinationOfSymbolicLink(atPath: sourcePath.path)
                guard symlink(link, target.path) == 0 else { throw Self.posixError(target) }
                owned[relative] = Entry(try Self.info(target))
            default: throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
    }

    func recordPresentationFiles() throws {
        // The presentation writer may rebuild .icon/lproj directories, but it cannot
        // replace the Resources root or the launcher's target marker.
        try recordGeneratedFiles(replacing: ["Contents/Info.plist", "Contents/Resources"],
                                 preserving: ["Contents/Resources", "Contents/Resources/real_app_path.txt"])
    }

    /// Admit changes only in the current writer's output paths. Core directories
    /// and unrelated files must still be the objects that this workspace created.
    func recordGeneratedFiles(replacing paths: Set<String>, preserving: Set<String> = []) throws {
        let updated = try Self.snapshot(url)
        for path in Set(owned.keys).union(updated.keys) {
            if !preserving.contains(path), paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            guard let previous = owned[path], let current = updated[path],
                  previous.kind == S_IFDIR ? previous.sameIdentity(current) : previous == current else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        owned = updated
    }
    func validate() throws {
        guard try Self.snapshot(url) == owned else { throw CocoaError(.fileWriteInvalidFileName) }
    }
    func prepareForInstall() throws {
        try validate()
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Self.posixError(url) }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, owned[""] == Entry(value) else { throw CocoaError(.fileWriteInvalidFileName) }
        guard fchmod(fd, 0o755) == 0 else { throw Self.posixError(url) }
    }
    func relinquish() { active = false }
    func adoptExchangedTree(_ snapshot: [String: Entry]) { owned = snapshot }

    func cleanup() {
        guard active else { return }
        let isolated = url.deletingLastPathComponent().appendingPathComponent(".appports-cleanup-\(UUID().uuidString).app")
        var coordinationError: NSError?
        var cleanupError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { path in
            do {
                // Directory timestamps change as children are created; ownership is device/inode/type.
                let current = try Self.snapshot(path)
                guard current.keys.sorted() == owned.keys.sorted(), current.allSatisfy({ key, entry in
                    guard let expected = owned[key] else { return false }
                    return expected.kind == S_IFDIR ? expected.sameIdentity(entry) : expected == entry
                }) else { throw CocoaError(.fileWriteInvalidFileName) }
                guard renameatx_np(AT_FDCWD, path.path, AT_FDCWD, isolated.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw Self.posixError(path)
                }
                let moved = try Self.snapshot(isolated)
                guard moved == current else { throw CocoaError(.fileWriteInvalidFileName) }
                try removeContents(isolated, snapshot: current)
            } catch { cleanupError = error }
        }
        if let error = cleanupError ?? coordinationError {
            AppLogger.shared.logError("应用入口临时副本清理失败，保留文件", error: error,
                                      relatedURLs: [("stage", url), ("preserved", isolated)])
        }
    }

    private func removeContents(_ root: URL, snapshot: [String: Entry]) throws {
        // Bind every operation to its parent directory descriptor. Replacing an
        // ancestor with a symlink cannot redirect a flag change into the real app.
        let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw Self.posixError(root) }
        defer { close(parent) }
        func current(_ parentFD: Int32, name: String) throws -> stat {
            var value = stat()
            guard fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posixError(root) }
            return value
        }
        func remove(_ parentFD: Int32, name: String, relative: String) throws {
            guard let expected = snapshot[relative] else { throw CocoaError(.fileWriteInvalidFileName) }
            let observed = Entry(try current(parentFD, name: name))
            guard expected.kind == S_IFDIR ? expected.sameIdentity(observed) : expected == observed else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            if expected.kind == S_IFLNK {
                guard unlinkat(parentFD, name, 0) == 0 else { throw Self.posixError(root) }
                return
            }
            guard expected.kind == S_IFREG || expected.kind == S_IFDIR else { throw CocoaError(.fileWriteInvalidFileName) }
            let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw Self.posixError(root) }
            defer { close(fd) }
            var value = stat()
            guard fstat(fd, &value) == 0, expected.sameIdentity(Entry(value)) else { throw CocoaError(.fileWriteInvalidFileName) }
            if expected.kind == S_IFREG, Entry(value) != expected { throw CocoaError(.fileWriteInvalidFileName) }
            if value.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                // Removing a link is safe, but changing flags on a shared inode would change its other owner.
                guard expected.kind != S_IFREG || value.st_nlink == 1 else { throw CocoaError(.fileWriteNoPermission) }
                guard fchflags(fd, value.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else { throw Self.posixError(root) }
            }
            if expected.kind == S_IFDIR {
                let prefix = relative.isEmpty ? "" : relative + "/"
                for child in snapshot.keys.sorted() where child.hasPrefix(prefix) && child != relative {
                    let suffix = String(child.dropFirst(prefix.count))
                    if !suffix.contains("/") { try remove(fd, name: suffix, relative: child) }
                }
            }
            guard expected.sameIdentity(Entry(try current(parentFD, name: name))) else { throw CocoaError(.fileWriteInvalidFileName) }
            // AT_REMOVEDIR refuses untracked children instead of recursively deleting them.
            guard unlinkat(parentFD, name, expected.kind == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw Self.posixError(root) }
        }
        try remove(parent, name: root.lastPathComponent, relative: "")
    }
}
