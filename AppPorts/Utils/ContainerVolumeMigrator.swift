//
//  ContainerVolumeMigrator.swift
//  AppPorts
//

import Darwin
import Foundation

// MARK: - 容器数据挂载迁移器

/// 沙盒应用容器数据的挂载迁移器。
///
/// 与 `DataDirMover` 的符号链接策略并列：沙盒应用无法透过符号链接访问容器外路径
/// （内核按解析后的真实路径判定），这里改为在外置盘的 APFS 容器中新建一个卷，
/// 把它挂载到容器内的原目录上。路径不离开容器，应用签名与 entitlements 不做任何修改。
///
/// ## 操作流程
/// - **迁移**：建卷 → 复制并核验 → 切换原路径 → 持久化记录 → 自动清理已核验的旧数据
/// - **还原**：定位当前卷 → 复制最新数据并核验 → 切回原路径 → 自动清理旧卷
/// - **挂载 / 卸载**：只处理已有记录。未挂载期间挂载点保持 500 权限，
///   应用在盘不在时只会看到空目录，不会把新数据写进本地形成分叉。
actor ContainerVolumeMigrator {

    enum MigrationError: LocalizedError {
        case sourceNotDirectory(URL)
        case alreadyManaged(URL)
        case externalNotAPFS(URL)
        case encryptedDestination
        case unexpectedMountedVolume(URL)
        case volumeCreationFailed(String)
        case mountFailed(URL, String)
        case mountVerificationFailed(URL)
        case mountPointNotEmpty(URL)
        case mountPointConflict(URL, String)
        case unmountFailed(URL, String)
        case volumeUnavailable(String)
        case insufficientSpace(required: Int64, available: Int64)
        case copyFailed(Error)
        case switchFailed(Error)
        case rollbackIncomplete(backup: URL, volumeName: String, volumeUUID: String, underlying: Error)
        /// 还原时本地副本已复制好，但没能换到原路径。外置卷和记录保持不变。
        case restoreIncomplete(staging: URL, underlying: Error)
        case restoreRecordRecovery(staging: URL, underlying: Error)
        case ownershipRollbackFailed(URL, operation: Error, rollback: Error)
        case cleanupRecordLocalUnavailable(URL)
        case cleanupRecordStillMounted(URL)
        case cleanupRecordStagingExists(URL)

        var errorDescription: String? {
            switch self {
            case .sourceNotDirectory(let url):
                return String(format: "该路径不是真实目录，无法挂载迁移：%@".localized, url.lastPathComponent)
            case .alreadyManaged(let url):
                return String(format: "该目录已经是挂载迁移项：%@".localized, url.lastPathComponent)
            case .externalNotAPFS(let url):
                return String(format: "外部存储不是 APFS 格式，无法创建挂载卷：%@".localized, url.path)
            case .encryptedDestination:
                return "请先为新数据卷设置加密密码，原数据尚未改动。".localized
            case .unexpectedMountedVolume(let url):
                return String(format: "此目录挂载的卷与迁移记录不一致，已停止操作并保留数据：%@".localized, url.path)
            case .volumeCreationFailed(let output):
                return String(format: "创建外置卷失败：%@".localized, output)
            case .mountFailed(let url, let output):
                return String(format: "挂载到容器目录失败：%@\n%@".localized, url.path, output)
            case .mountVerificationFailed(let url):
                return String(format: "挂载后校验失败，该路径不是挂载点：%@".localized, url.path)
            case .mountPointConflict(let url, let details):
                return ["数据入口无法安全切换，现有数据已保留。".localized, url.path, details].joined(separator: "\n")
            case .mountPointNotEmpty(let url):
                return String(format: "挂载点目录不为空，为避免覆盖数据已停止操作：%@".localized, url.path)
            case .unmountFailed(let url, let output):
                return String(format: "卸载失败，可能有应用正在使用该目录：%@\n%@".localized, url.path, output)
            case .volumeUnavailable(let name):
                return String(format: "找不到外置卷「%@」，请确认外部存储已连接".localized, name)
            case .insufficientSpace(let required, let available):
                return String(
                    format: "空间不足：需要约 %@ 可用空间，目前只有 %@。未做任何改动。".localized,
                    LocalizedByteCountFormatter.string(fromByteCount: required),
                    LocalizedByteCountFormatter.string(fromByteCount: available)
                )
            case .copyFailed(let error):
                return String(format: "复制失败：%@".localized, error.localizedDescription)
            case .switchFailed(let error):
                return String(format: "切换挂载点失败，数据已紧急还原：%@".localized, error.localizedDescription)
            case .rollbackIncomplete(let backup, let volumeName, let volumeUUID, let error):
                return ["数据入口无法安全切换，现有数据已保留。".localized,
                    backup.path, volumeName, volumeUUID, error.localizedDescription].joined(separator: "\n")
            case .restoreIncomplete(let staging, let error):
                return String(
                    format: "还原没有完成：外置卷上的数据和迁移记录保持不变，已复制到本机的副本保留在「%@」。%@".localized,
                    staging.path,
                    error.localizedDescription
                )
            case .restoreRecordRecovery(let staging, let error):
                return ["数据入口无法安全切换，现有数据已保留。".localized,
                    staging.path, error.localizedDescription].joined(separator: "\n")
            case .ownershipRollbackFailed(let url, let operation, let rollback):
                return ["自动恢复暂未完成，已保留恢复记录；再次操作时会继续检查实际数据位置。".localized,
                    url.path, operation.localizedDescription, rollback.localizedDescription].joined(separator: "\n")
            case .cleanupRecordLocalUnavailable(let url):
                return "未确认本地还原目录，未移除记录：".localized + url.path
            case .cleanupRecordStillMounted(let url):
                return ["数据入口无法安全切换，现有数据已保留。".localized, url.path].joined(separator: "\n")
            case .cleanupRecordStagingExists(let url):
                return ["暂存对象归属无法确认，已保留。".localized, url.path].joined(separator: "\n")
            }
        }
    }

    struct MigrationResult: Sendable {
        let record: ContainerMountRecord
        let cleanupWarning: CleanupWarning?
        let operationID: UUID
    }

    /// 主操作已完成，副本或记录清理尚未完成；调用方须按部分成功呈现。
    struct CleanupWarning: Sendable {
        let cleanup: ContainerCleanupRecord
        let details: String
        var needsRecordUpdateOnly = false
        var transferOperationID: UUID? = nil

        var message: String {
            if transferOperationID != nil {
                let format = cleanup.kind == .restoredVolume
                    ? "数据已还原到本地，但旧副本尚未全部清理。%@".localized
                    : "迁移已完成，但旧副本尚未全部清理。%@".localized
                return String(format: format, "\n" + details)
            }
            return (["旧版操作的安全收尾尚未完成，数据已保留。AppPorts 会继续检查；当前未完成的原因：".localized,
                     cleanup.localPath, "APFS · " + cleanup.mountRecord.volumeName + " · " + cleanup.mountRecord.volumeUUID]
                + [cleanup.restoreStagingPath, details.isEmpty ? nil : details].compactMap { $0 }).joined(separator: "\n")
        }
    }

    /// 卷现在挂在哪 —— 决定挂载前要不要先把它从别处卸下来。
    enum KnownMountPoint: Equatable {
        /// 还没查过，需要一次 `diskutil info`（开机时这条要一秒上下）。
        case unknown
        /// 查过，卷没挂在任何地方。
        case unmounted
        /// 卷挂在别的位置（多半是系统自动挂到了 `/Volumes`）。
        case mounted(at: URL)
    }

    struct RemountOutcome: Sendable {
        enum State: Equatable, Sendable {
            case alreadyMounted
            case mounted
            case unavailable
            case failed(String)
            case requiresIntervention(String)
        }

        let record: ContainerMountRecord
        let state: State
    }

    static let volumeMarkerFileName = ".appports-mount-metadata.plist"
    /// 系统自动挂载外置卷的位置：`/Volumes/<卷名>`。挂载前先看一眼这里能省掉一次 diskutil 查询。
    static let autoMountRoot = "/Volumes"
    /// 卷根的防索引标记：系统会把挂到容器路径上的卷当成普通外置卷索引，
    /// 两个微信卷实测留下过合计约 110 MB 的 `.Spotlight-V100`。空文件放在卷根，
    /// mds 就会跳过整个卷；标记写在卷上，跟着卷走，不需要任何系统设置。
    static let neverIndexFileName = ".metadata_never_index"
    private static let managedIdentifier = "com.shimoko.AppPorts"
    /// 挂载动作的尝试轮数：命令报告成功但挂载点没出现时（被系统自动挂载抢先）重来。
    static let maximumMountAttempts = 3
    /// 两次挂载尝试之间的间隔，给自动挂载留出落地时间。
    private static let mountRetrySettleNanoseconds: UInt64 = 500_000_000
    /// 卷根目录上由系统创建、不属于应用数据的条目，还原时不带回本地。
    static let volumeSystemArtifacts: Set<String> = [
        volumeMarkerFileName, neverIndexFileName, ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware"
    ]

    /// 复制这么多数据需要预留的可用空间：数据本身加 5% 余量，至少多留 256 MB 给文件系统元数据。
    static func requiredFreeBytes(forDataBytes bytes: Int64) -> Int64 {
        bytes + max(bytes / 20, 256 * 1024 * 1024)
    }

    private struct VolumeMarker: Codable {
        let schemaVersion: Int
        let managedBy: String
        let mountPointPath: String
        let volumeUUID: String
        let dataDirType: String
        let appName: String
        let createdAt: Date
    }

    private let fileManager = FileManager.default
    // Shared with the actor's automatic-recovery extension.
    let disk: DiskUtility
    let store: ContainerMountStore
    let isMountPoint: @Sendable (URL) -> Bool
    private let mountedVolumePath: @Sendable (URL) -> String?
    private let mountedVolumeUUID: @Sendable (URL) -> String?
    /// 读卷根迁移标记里的 Volume UUID。挂载前用它确认 `/Volumes/<卷名>` 上挂的就是我们要的卷，
    /// 测试注入假实现，避免真去读磁盘。
    private let volumeUUIDMarker: @Sendable (URL) -> String?
    /// 记录增删后同步登录代理的安装状态；测试注入空实现，避免动真实 LaunchAgents。
    let synchronizeAgent: @Sendable (ContainerMountStore) -> Void
    /// 路径所在卷的可用空间；返回 nil 表示查不到，此时不拦截。测试注入固定值。
    private let availableCapacity: @Sendable (URL) -> Int64?
    /// 挂载点的挂载标志，用来发现早期版本挂上、仍会显示在 Finder 里的卷。测试注入固定值。
    let mountFlags: @Sendable (URL) -> UInt32?
    let stagingMountRootURL: URL
    let automaticMountRootURL: URL
    let safety: DataOperationSafety
    private let makeMountPointLease: @Sendable (URL) throws -> any MountPointLeasing
    let synchronizeCleanupParent: @Sendable (URL) throws -> Void
    private var completingPaths: Set<String> = []
    private var runningCleanups: Set<UUID> = []

    private let encryption: APFSVolumeEncryption.Credentials?

    init(
        disk: DiskUtility = DiskUtility(),
        store: ContainerMountStore = .shared,
        stagingMountRootURL: URL? = nil,
        automaticMountRootURL: URL = URL(fileURLWithPath: ContainerVolumeMigrator.autoMountRoot),
        isMountPoint: @escaping @Sendable (URL) -> Bool = { DiskUtility.isMountPoint($0) },
        mountedVolumePath: @escaping @Sendable (URL) -> String? = { DiskUtility.mountedVolumePath(containing: $0) },
        mountedVolumeUUID: @escaping @Sendable (URL) -> String? = { DiskUtility.mountedVolumeUUID(at: $0) },
        volumeUUIDMarker: @escaping @Sendable (URL) -> String? = { ContainerVolumeMigrator.readVolumeMarkerUUID(at: $0) },
        synchronizeAgent: @escaping @Sendable (ContainerMountStore) -> Void = { ContainerMountAgentInstaller.installIfNeeded(store: $0) },
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { DiskUtility.availableCapacity(at: $0) },
        mountFlags: @escaping @Sendable (URL) -> UInt32? = { DiskUtility.mountFlags(at: $0) },
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        partialWeChatMigrationEnabled: Bool = false,
        weChatContainerIdentifier: String = PartialWeChatMigrationPolicy.bundleIdentifier,
        safetyRunner: any ShellCommandRunning = ProcessCommandRunner(),
        encryption: APFSVolumeEncryption.Credentials? = nil,
        makeMountPointLease: @escaping @Sendable (URL) throws -> any MountPointLeasing = { try MountPointLease(at: $0) },
        removeMigrationBackup: @escaping @Sendable (URL) throws -> Void = { try FileCopier.removeCopy(at: $0) },
        synchronizeCleanupParent: @escaping @Sendable (URL) throws -> Void = { try DurableFileIO.syncDirectory(at: $0) }
    ) {
        self.safety = DataOperationSafety(homeDirectory: homeDirectory, store: store, runner: safetyRunner,
                                          partialWeChatMigrationEnabled: partialWeChatMigrationEnabled,
                                    weChatContainerIdentifier: weChatContainerIdentifier)
        self.encryption = encryption
        self.makeMountPointLease = makeMountPointLease
        self.synchronizeCleanupParent = synchronizeCleanupParent
        self.disk = disk
        self.store = store
        self.isMountPoint = isMountPoint
        self.mountedVolumePath = mountedVolumePath
        self.mountedVolumeUUID = mountedVolumeUUID
        self.volumeUUIDMarker = volumeUUIDMarker
        self.synchronizeAgent = synchronizeAgent
        self.availableCapacity = availableCapacity
        self.mountFlags = mountFlags
        self.automaticMountRootURL = automaticMountRootURL.standardizedFileURL
        self.stagingMountRootURL = stagingMountRootURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AppPorts/mounts")
    }

    // MARK: - 迁移

    /// User operations finish verified cleanup under their outer operation
    /// lock. The low-level methods remain available for explicit recovery.
    func migrateAndComplete(item: DataDirItem, externalRootURL: URL, appName: String,
                            bundleIdentifier: String?, progressHandler: FileCopier.ProgressHandler?) async throws -> MigrationResult {
        let launchDirectory = store.fileURLForDeletionAuthorization.deletingLastPathComponent().appendingPathComponent("launch-locks", isDirectory: true)
        let launchIdentifier = bundleIdentifier
        if !ApplicationLaunchProtection.contains(launchIdentifier, directory: launchDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: launchIdentifier, directory: launchDirectory) {
                try await self.migrateAndComplete(item: item, externalRootURL: externalRootURL, appName: appName, bundleIdentifier: bundleIdentifier, progressHandler: progressHandler)
            }
        }
        if DataTransferSession.current == nil {
            return try await DataTransferSession.run {
                try await self.migrateAndComplete(item: item, externalRootURL: externalRootURL, appName: appName,
                    bundleIdentifier: bundleIdentifier, progressHandler: progressHandler)
            }
        }
        let path = item.path.standardizedFileURL.path
        guard completingPaths.insert(path).inserted else { throw DataOperationSafety.Failure.occupied(path) }
        defer { completingPaths.remove(path) }
        // Reconcile a completed legacy restore before overlap admission. The
        // foreground action must not depend on a background timer having run.
        for cleanup in try store.pendingCleanups() where cleanup.kind == .restoredVolume && cleanup.localPath == path {
            if let warning = await performCleanup(cleanup) {
                throw NSError(domain: "AppPorts.DataOperation", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: warning.message])
            }
        }
        if let pending = try pendingMountTransfer(at: path, direction: .migrate),
           case .completed = try await recoverWithIndependentBudget(pending) {
            guard let record = pending.recoveryMountRecord else { throw DataOperationSafety.Failure.inspection(path) }
            let warning = await completeSuccessfulTransfer(operationID: pending.operationID, direction: .migrate,
                record: record, progressHandler: progressHandler)
            return MigrationResult(record: record, cleanupWarning: warning, operationID: pending.operationID)
        }
        if let pending = try pendingMountTransfer(at: path, direction: .migrate) {
            throw AutomaticRecoveryError.restored(operation: DataOperationSafety.Failure.inspection(path),
                retainedDetails: pending.recoverableReason)
        }
        if let previous = try completedRestoreLineage(at: item.path.standardizedFileURL).last {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "正在清理旧副本...".localized, showsByteProgress: false, stage: .cleaning))
            do { try await cleanupRetainedLineage(operationID: previous.operationID) }
            catch {
                // The local restored object remains authoritative. An offline
                // old volume is still a visible cleanup task, not a global
                // prerequisite for creating an unrelated destination volume.
                try Task.checkCancellation()
            }
        }
        let result: MigrationResult
        do {
            result = try await migrate(item: item, externalRootURL: externalRootURL, appName: appName,
                bundleIdentifier: bundleIdentifier, progressHandler: progressHandler)
        } catch {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0,
                currentFile: "正在自动恢复数据入口...".localized, showsByteProgress: false, stage: .recovering))
            let completed = try await recoverFailedMountOperation(at: path, direction: .migrate, operation: error)
            guard let record = completed.recoveryMountRecord else { throw DataOperationSafety.Failure.inspection(path) }
            result = MigrationResult(record: record, cleanupWarning: nil, operationID: completed.operationID)
        }
        let warning = await completeSuccessfulTransfer(operationID: result.operationID, direction: .migrate,
            record: result.record, progressHandler: progressHandler)
        return MigrationResult(record: result.record, cleanupWarning: warning, operationID: result.operationID)
    }

    func restoreAndComplete(record: ContainerMountRecord, estimatedTotalBytes: Int64,
                            progressHandler: FileCopier.ProgressHandler?) async throws -> CleanupWarning? {
        let launchDirectory = store.fileURLForDeletionAuthorization.deletingLastPathComponent().appendingPathComponent("launch-locks", isDirectory: true)
        let launchIdentifier = record.bundleIdentifier
        if !ApplicationLaunchProtection.contains(launchIdentifier, directory: launchDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: launchIdentifier, directory: launchDirectory) {
                try await self.restoreAndComplete(record: record, estimatedTotalBytes: estimatedTotalBytes, progressHandler: progressHandler)
            }
        }
        if DataTransferSession.current == nil {
            return try await DataTransferSession.run {
                try await self.restoreAndComplete(record: record, estimatedTotalBytes: estimatedTotalBytes,
                    progressHandler: progressHandler)
            }
        }
        if let pending = try pendingMountTransfer(at: record.mountPointPath, direction: .restore) {
            guard pending.sourceIdentity.volumeUUID?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame,
                  pending.recoveryMountRecord == nil || pending.recoveryMountRecord == record else {
                throw DataOperationSafety.Failure.conflict(record.mountPointPath)
            }
            let message = try await resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: progressHandler)
            return message.map { CleanupWarning(cleanup: ContainerCleanupRecord(kind: .restoredVolume,
                mountRecord: record, localPath: record.mountPointPath), details: $0, transferOperationID: pending.operationID) }
        }
        try await completeInterruptedMigrationBeforeRestore(record: record, progressHandler: progressHandler)
        guard completingPaths.insert(record.mountPointPath).inserted else {
            throw DataOperationSafety.Failure.occupied(record.mountPointPath)
        }
        defer { completingPaths.remove(record.mountPointPath) }
        let previous = try store.transfers().last {
            $0.mode == .mount && $0.direction == .restore && $0.originalPath == record.mountPointPath
                && $0.sourceIdentity.volumeUUID?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame && $0.isDataSwitchComplete
        }
        if let previous {
            return await completeSuccessfulTransfer(operationID: previous.operationID, direction: .restore,
                record: record, progressHandler: progressHandler, requireUnchangedActive: false)
        }
        let operationID: UUID
        do {
            operationID = try await restoreRetainingOriginal(record: record, estimatedTotalBytes: estimatedTotalBytes,
                progressHandler: progressHandler)
        } catch {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0,
                currentFile: "正在自动恢复数据入口...".localized, showsByteProgress: false, stage: .recovering))
            operationID = try await recoverFailedMountOperation(at: record.mountPointPath, direction: .restore,
                operation: error).operationID
        }
        return await completeSuccessfulTransfer(operationID: operationID, direction: .restore,
            record: record, progressHandler: progressHandler)
    }

    func completeSuccessfulTransfer(operationID: UUID, direction: DataTransferRecord.Direction, record: ContainerMountRecord,
                                             progressHandler: FileCopier.ProgressHandler?, requireUnchangedActive: Bool = false) async -> CleanupWarning? {
        let warning = await DataTransferSession.measure(.cleanup) {
            await self.completeTransferCleanup(operationID: operationID, direction: direction, record: record,
                progressHandler: progressHandler, requireUnchangedActive: requireUnchangedActive)
        }
        AppDataShortcutService.update(for: record, removing: direction == .restore)
        return warning
    }

    private func completeTransferCleanup(operationID: UUID, direction: DataTransferRecord.Direction, record: ContainerMountRecord,
                                        progressHandler: FileCopier.ProgressHandler?, requireUnchangedActive: Bool) async -> CleanupWarning? {
        do {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "正在清理旧副本...".localized, showsByteProgress: false, stage: .cleaning))
            if let transfer = try store.transfer(operationID: operationID) {
                guard transfer.needsAutomaticCompletion else { return nil }
                try await requireActiveData(for: transfer)
                if requireUnchangedActive {
                    guard let encoded = transfer.baseline else { throw DataOperationSafety.Failure.inspection(transfer.activePath) }
                    try TreeCopySession.verifyCopy(at: URL(fileURLWithPath: transfer.activePath),
                        against: PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded), purpose: .activeData)
                }
                try await cleanupRetainedLineage(operationID: operationID)
            }
            let preserved = await cleanupPreservedRestoreMaterials(at: record.mountPointPath)
            let rolledBack = try store.transfers().filter {
                $0.originalPath == record.mountPointPath && $0.rollbackCompletedAt != nil
            }.compactMap(\.recoverableReason)
            let reasons = Array(Set(preserved + rolledBack)).sorted()
            if !reasons.isEmpty {
                return CleanupWarning(cleanup: ContainerCleanupRecord(kind: direction == .restore ? .restoredVolume : .migrationBackup,
                    mountRecord: record, localPath: record.mountPointPath), details: reasons.joined(separator: "\n"),
                    transferOperationID: operationID)
            }
            return nil
        } catch {
            let cleanup = ContainerCleanupRecord(kind: direction == .restore ? .restoredVolume : .migrationBackup,
                mountRecord: record, localPath: record.mountPointPath)
            return CleanupWarning(cleanup: cleanup, details: error.localizedDescription, transferOperationID: operationID)
        }
    }

    private func retainedLineage(endingAt operationID: UUID) throws -> [DataTransferRecord] {
        let records = try store.transfers()
        guard var current = records.first(where: { $0.operationID == operationID }) else { return [] }
        let original = current.originalPath
        var lineage: [DataTransferRecord] = []
        var visited: Set<UUID> = []
        while true {
            guard visited.insert(current.operationID).inserted,
                  current.originalPath == original, current.isDataSwitchComplete,
                  current.baseline != nil || current.retainedCopyRemovedAt != nil,
                  current.destinationIdentity != nil, current.backupPath != nil, current.backupIdentity != nil else {
                throw DataOperationSafety.Failure.inspection(original)
            }
            lineage.append(current)
            guard let priorID = current.priorOperationID,
                  let prior = records.first(where: { $0.operationID == priorID }) else { break }
            guard current.followsLocation(of: prior) else {
                throw DataOperationSafety.Failure.conflict(original)
            }
            current = prior
        }
        return Array(lineage.reversed())
    }

    private func completedRestoreLineage(at local: URL) throws -> [DataTransferRecord] {
        let history = try store.transfers()
        let related = history.filter { $0.originalPath == local.path && $0.rollbackCompletedAt == nil }
        let restores = related.filter { record in
            record.direction == .restore && record.isDataSwitchComplete
                && !history.contains(where: { $0.priorOperationID == record.operationID && $0.rollbackCompletedAt == nil })
        }
        guard !restores.isEmpty else { return [] }
        guard restores.count == 1, let terminal = restores.first else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        let lineage = try retainedLineage(endingAt: terminal.operationID)
        guard Set(lineage.map(\.operationID)) == Set(related.map(\.operationID)),
              terminal.activePath == local.path, terminal.destinationPath == local.path,
              !isSymbolicLink(at: local), !isMountPoint(local),
              try store.recordsStrict().allSatisfy({ $0.mountPointPath != local.path }),
              let identity = terminal.destinationIdentity,
              try DataPathIdentity.capture(local).matchesFilesystemObject(identity) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        return lineage
    }

    private func transferAncestors(of transfer: DataTransferRecord,
                                   in records: [DataTransferRecord]) throws -> Set<UUID> {
        var result: Set<UUID> = [transfer.operationID]
        var current = transfer
        while let priorID = current.priorOperationID,
              let prior = records.first(where: { $0.operationID == priorID }) {
            guard result.insert(priorID).inserted, current.followsLocation(of: prior) else {
                throw DataOperationSafety.Failure.conflict(transfer.originalPath)
            }
            current = prior
        }
        return result
    }

    func cleanupRetainedLineage(operationID: UUID) async throws {
        var firstFailure: Error?
        for transfer in try retainedLineage(endingAt: operationID) {
            try Task.checkCancellation()
            do {
                if transfer.mode == .mount { try await cleanupRetainedTransfer(operationID: transfer.operationID) }
                else {
                    try await DataDirMover(homeDir: safety.homeDirectory, store: store,
                        runner: safety.runner, mountMigrator: self).cleanupRetainedTransfer(operationID: transfer.operationID)
                }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private func copyPreparation(_ transfer: DataTransferRecord, source: URL, destination: URL,
                                 finalDestination: URL, logicalSourceRoot: URL? = nil,
                                 progressHandler: FileCopier.ProgressHandler?) async throws -> TreeCopySnapshot {
        let currentStore = store
        let operationID = transfer.operationID
        let destinationUUID = transfer.direction == .migrate ? transfer.createdVolumeUUID : nil
        return try await TreeCopySession().copy(from: source, to: destination,
            excludingRootEntries: Self.volumeSystemArtifacts, finalDestination: finalDestination,
            logicalSourceRoot: logicalSourceRoot, legacyRootOwnership: transfer.legacyRootOwnership,
            verifySourceAfterCopy: false,
            verifyDestinationAfterCopy: false,
            preparedHandler: { baseline in
                try currentStore.prepareCopy(operationID: operationID, path: destination,
                    parentIdentity: DataPathIdentity.capture(destination.deletingLastPathComponent()), baseline: baseline)
            }, destinationCreatedHandler: { captured in
                var identity = captured
                if let destinationUUID { identity.volumeUUID = destinationUUID }
                try currentStore.claimCopyDestination(operationID: operationID, identity: identity)
            }, progressHandler: progressHandler)
    }

    private func promoteCompletePreparation(_ expected: DataTransferRecord) async throws -> DataTransferRecord? {
        try await withPreparationOwnership(expected) {
            try await promoteCompletePreparationUsingOwners(expected)
        }
    }

    private func promoteCompletePreparationUsingOwners(_ expected: DataTransferRecord) async throws -> DataTransferRecord? {
        guard let encoded = expected.sourceBaseline, let identity = expected.destinationIdentity,
              expected.preparationRemovalBaseline == nil, let path = expected.preparationPath,
              let parent = expected.preparationParentIdentity else { return nil }
        let source = try await mountPreparationSource(expected, verifyContents: true)
        let candidate = URL(fileURLWithPath: path)
        guard try verifiedResumeEntryExists(candidate) else { return nil }
        if expected.direction == .migrate {
            guard let uuid = expected.createdVolumeUUID, isMountPoint(candidate) else { return nil }
            try await requireExpectedVolume(uuid, at: candidate)
        } else if isMountPoint(candidate) { throw DataOperationSafety.Failure.conflict(path) }
        guard try DataPathIdentity.capture(candidate.deletingLastPathComponent()).matchesFilesystemObject(parent),
              try DataPathIdentity.capture(candidate, volumeUUID: expected.direction == .migrate ? expected.createdVolumeUUID : nil)
                .matchesFilesystemObject(identity) else { throw DataOperationSafety.Failure.conflict(path) }
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        do { try TreeCopySession.verifyCopy(at: candidate, against: baseline) }
        catch { return nil }
        try await safety.requireNoKnownWriters(at: source, bundleIdentifier: expected.bundleIdentifier)
        _ = try await mountPreparationSource(expected, verifyContents: true)
        try TreeCopySession.verifyCopy(at: candidate, against: baseline)
        try DurableFileIO.syncTree(at: candidate, excludingRootEntries: Self.volumeSystemArtifacts)
        var verified = expected
        verified.baseline = encoded
        verified.phase = .verified
        verified.recoverableReason = nil
        if verified.direction == .restore { verified.backupIdentity = verified.sourceIdentity }
        try store.updateTransfer(verified)
        return verified
    }

    private func completeInterruptedMigrationBeforeRestore(record: ContainerMountRecord,
                                                           progressHandler: FileCopier.ProgressHandler?) async throws {
        for transfer in try store.transfers() where transfer.mode == .mount && transfer.direction == .migrate
            && transfer.originalPath == record.mountPointPath && transfer.isVerifiedSwitchRecoverable
            && transfer.createdVolumeUUID?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame {
            _ = try await resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: progressHandler)
        }
    }

    func cancelPreparation(operationID: UUID, preserveUnclaimedMaterials: Bool = false) async throws {
        guard let saved = try store.transfer(operationID: operationID) else { return }
        let expected = try store.adoptLegacyRestoreOwnership(saved)
        guard completingPaths.insert(expected.originalPath).inserted else {
            throw DataOperationSafety.Failure.occupied(expected.originalPath)
        }
        defer { completingPaths.remove(expected.originalPath) }
        try await cancelPreparation(expected, preserveUnclaimedMaterials: preserveUnclaimedMaterials)
    }

    private func restartPreparation(_ expected: DataTransferRecord,
                                    progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
        let record = try expected.recoveryMountRecord ?? store.recordsStrict().first { $0.mountPointPath == expected.originalPath }
        guard let record else { throw DataOperationSafety.Failure.inspection(expected.originalPath) }
        try await cancelPreparation(expected, preserveUnclaimedMaterials: false)
        if expected.direction == .restore {
            let id = try await restoreRetainingOriginal(record: record, estimatedTotalBytes: 0,
                progressHandler: progressHandler, reusingOperationID: expected.operationID)
            return await completeSuccessfulTransfer(operationID: id, direction: .restore,
                record: record, progressHandler: progressHandler)?.message
        }
        let local = URL(fileURLWithPath: expected.originalPath)
        let item = DataDirItem(name: local.lastPathComponent, path: local,
            type: DataDirType(rawValue: expected.dataDirType) ?? .custom, priority: .recommended,
            description: "", associatedAppName: expected.appName, associatedBundleIdentifier: expected.bundleIdentifier)
        let result = try await migrate(item: item, externalRootURL: URL(fileURLWithPath: record.externalRootPath),
            appName: expected.appName, bundleIdentifier: expected.bundleIdentifier,
            progressHandler: progressHandler, reusingOperationID: expected.operationID)
        return await completeSuccessfulTransfer(operationID: result.operationID, direction: .migrate,
            record: result.record, progressHandler: progressHandler)?.message
    }

    private func requirePreparationLedger(_ transfer: DataTransferRecord) throws {
        guard transfer.mode == .mount, transfer.isPreparationRecoverable,
              try store.transfer(operationID: transfer.operationID) == transfer,
              !(try store.transfers()).contains(where: { $0.priorOperationID == transfer.operationID }) else {
            throw RecoveryJournalChanged(operation: DataOperationSafety.Failure.conflict(transfer.originalPath))
        }
        if transfer.direction == .restore {
            guard let mount = try store.recordsStrict().first(where: { $0.mountPointPath == transfer.originalPath }),
                  mount.volumeUUID.caseInsensitiveCompare(transfer.sourceIdentity.volumeUUID ?? "") == .orderedSame,
                  transfer.recoveryMountRecord == nil || transfer.recoveryMountRecord == mount else {
                throw RecoveryJournalChanged(operation: DataOperationSafety.Failure.conflict(transfer.originalPath))
            }
        }
    }

    /// A synchronous topology check can be repeated under the store writer
    /// lock. No record read is performed from that final closure.
    private func requireUnswitchedMountEntry(_ transfer: DataTransferRecord) throws {
        let local = URL(fileURLWithPath: transfer.originalPath)
        guard !isSymbolicLink(at: local) else { throw DataOperationSafety.Failure.conflict(local.path) }
        if transfer.direction == .migrate {
            guard !isMountPoint(local), try DataPathIdentity.capture(local).matchesFilesystemObject(transfer.sourceIdentity),
                  let backup = transfer.backupPath, try !verifiedResumeEntryExists(URL(fileURLWithPath: backup)) else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        } else if isMountPoint(local) {
            guard let uuid = transfer.sourceIdentity.volumeUUID,
                  (mountedVolumeUUID(local) ?? DiskUtility.mountedVolumeUUID(at: local))?.caseInsensitiveCompare(uuid) == .orderedSame else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            if transfer.sourceIdentity.isResolved {
                guard try DataPathIdentity.capture(local, volumeUUID: uuid).matchesFilesystemObject(transfer.sourceIdentity) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
            }
        } else if try verifiedResumeEntryExists(local) {
            guard existingRealDirectory(at: local),
                  transfer.destinationIdentity.map({ (try? DataPathIdentity.capture(local).matchesFilesystemObject($0)) != true }) ?? true else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            var before = stat()
            guard lstat(local.path, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard before.st_mode & S_IFMT == S_IFDIR else { throw DataOperationSafety.Failure.conflict(local.path) }
            if MountPointLease.isProtectedMode(before.st_mode & 0o7777) {
                // Normal unmount leaves an empty read-only placeholder. Its existing
                // lease checks the anchored contents while keeping it locked;
                // legacy 000 entries must also remain recoverable.
                try store.recheckWriterAdmission()
                let lease = try makeMountPointLease(local)
                try lease.verifyBeforeMount()
                var current = stat()
                guard !isMountPoint(local), lstat(local.path, &current) == 0,
                      current.st_dev == before.st_dev, current.st_ino == before.st_ino,
                      current.st_mode & 0o7777 == MountPointLease.protectedMode else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
            } else if try !fileManager.contentsOfDirectory(atPath: local.path).isEmpty {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        }
    }

    private func mountPreparationSource(_ transfer: DataTransferRecord, verifyContents: Bool) async throws -> URL {
        try requirePreparationLedger(transfer)
        try requireUnswitchedMountEntry(transfer)
        let local = URL(fileURLWithPath: transfer.originalPath)
        let source: URL
        if transfer.direction == .migrate { source = local }
        else {
            guard let uuid = transfer.sourceIdentity.volumeUUID, let backupPath = transfer.backupPath else {
                throw DataOperationSafety.Failure.inspection(local.path)
            }
            let info = try await disk.volumeInfo(for: uuid)
            try requirePreparationLedger(transfer)
            guard info.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame else {
                throw DataOperationSafety.Failure.inspection(backupPath)
            }
            if let mounted = info.mountPoint, !mounted.isEmpty,
               [local.path, backupPath].contains(where: { DiskUtility.pathsMatch($0, mounted) }) {
                source = URL(fileURLWithPath: mounted)
            } else {
                // Reconnection can leave a copied/partially copied restore's
                // source unmounted or at the system automount location. Rebind
                // only the saved UUID/marker; keep its candidate and journal.
                guard let record = try transfer.recoveryMountRecord
                    ?? store.recordsStrict().first(where: { $0.mountPointPath == transfer.originalPath }),
                      record.volumeUUID.caseInsensitiveCompare(uuid) == .orderedSame else {
                    throw DataOperationSafety.Failure.inspection(backupPath)
                }
                if let mounted = info.mountPoint, !mounted.isEmpty {
                    let automatic = URL(fileURLWithPath: mounted)
                    guard automatic.deletingLastPathComponent().path == Self.autoMountRoot,
                          automatic.lastPathComponent == record.volumeName else {
                        throw DataOperationSafety.Failure.conflict(mounted)
                    }
                    try requireVolumeMarker(at: automatic, record: record)
                    try await requireExpectedVolume(uuid, at: automatic)
                    try await safety.requireNoKnownWriters(at: automatic, bundleIdentifier: transfer.bundleIdentifier)
                }
                try safety.requireApplicationStopped(at: local, bundleIdentifier: transfer.bundleIdentifier)
                let ignoresOwnership: Bool
                if let encoded = transfer.sourceBaseline {
                    ignoresOwnership = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
                        .ownershipCompatibility?.sourceIgnoresOwnership == true
                } else { ignoresOwnership = record.ownershipPolicy != .owners }
                try await mountVolume(uuid, at: local, operationID: transfer.operationID.uuidString,
                    knownMountPoint: Self.knownMountPoint(from: info), requireOwnership: !ignoresOwnership) {
                        try self.requirePreparationLedger(transfer)
                        try self.requireUnswitchedMountEntry(transfer)
                    }
                source = local
            }
            try await requireExpectedVolume(uuid, at: source)
            if transfer.sourceIdentity.isResolved {
                guard try DataPathIdentity.capture(source, volumeUUID: uuid).matchesFilesystemObject(transfer.sourceIdentity) else {
                    throw DataOperationSafety.Failure.conflict(source.path)
                }
            }
        }
        if verifyContents, let encoded = transfer.sourceBaseline {
            let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
            if transfer.direction == .restore, let uuid = transfer.sourceIdentity.volumeUUID {
                try TreeCopySession.verifyUnchanged(at: source, against: baseline, expectedVolumeUUID: uuid)
            } else { try TreeCopySession.verifyUnchanged(at: source, against: baseline) }
        }
        try requirePreparationLedger(transfer)
        try requireUnswitchedMountEntry(transfer)
        return source
    }

    /// A stopped restore may have put noowners back after capturing an owners
    /// baseline. Re-enable it only for this attempt, using freshly checked
    /// mount flags, and restore those flags on every exit that leaves it mounted.
    private func withPreparationOwnership<Result>(_ transfer: DataTransferRecord,
                                                   required: Bool = true,
                                                   operation: () async throws -> Result) async throws -> Result {
        guard required, transfer.direction == .restore, transfer.sourceBaseline != nil else {
            return try await operation()
        }
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: transfer.sourceBaseline!)
        if baseline.ownershipCompatibility?.sourceIgnoresOwnership == true {
            return try await operation()
        }
        let source = try await mountPreparationSource(transfer, verifyContents: false)
        guard let uuid = transfer.sourceIdentity.volumeUUID, let flags = mountFlags(source) else {
            throw DataOperationSafety.Failure.inspection(source.path)
        }
        guard flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 else { return try await operation() }
        try await safety.requireNoKnownWriters(at: source, bundleIdentifier: transfer.bundleIdentifier)
        _ = try await mountPreparationSource(transfer, verifyContents: false)
        guard mountFlags(source) == flags else { throw DataOperationSafety.Failure.conflict(source.path) }
        let result: Result
        do {
            try await setOwnershipForRestore(mountPoint: source, originalFlags: flags, enabled: true)
            try await requireExpectedVolume(uuid, at: source)
            try requireOwners(at: source)
            result = try await operation()
        } catch {
            do { try await restoreFreshPreparationOwnership(transfer, at: source, flags: flags) }
            catch let rollback { throw MigrationError.ownershipRollbackFailed(source, operation: error, rollback: rollback) }
            throw error
        }
        try await restoreFreshPreparationOwnership(transfer, at: source, flags: flags)
        return result
    }

    private func restoreFreshPreparationOwnership(_ transfer: DataTransferRecord, at source: URL, flags: UInt32) async throws {
        guard isMountPoint(source) else { return }
        guard let uuid = transfer.sourceIdentity.volumeUUID else { throw DataOperationSafety.Failure.inspection(source.path) }
        try await requireExpectedVolume(uuid, at: source)
        let mask = UInt32(MNT_IGNORE_OWNERSHIP | MNT_DONTBROWSE | MNT_RDONLY | MNT_NODEV | MNT_NOSUID | MNT_NOEXEC)
        let original = (flags | UInt32(MNT_DONTBROWSE)) & mask
        guard let currentFlags = mountFlags(source) else { throw DataOperationSafety.Failure.inspection(source.path) }
        if currentFlags & mask == original { return }
        guard currentFlags & mask == original & ~UInt32(MNT_IGNORE_OWNERSHIP),
              let current = try store.transfer(operationID: transfer.operationID),
              current.originalPath == transfer.originalPath, current.direction == .restore,
              current.sourceIdentity.matchesFilesystemObject(transfer.sourceIdentity),
              try DataPathIdentity.capture(source, volumeUUID: uuid).matchesFilesystemObject(transfer.sourceIdentity) else {
            throw DataOperationSafety.Failure.conflict(source.path)
        }
        try await restoreOriginalMountOptions(mountPoint: source, volumeUUID: uuid, originalFlags: flags)
        try await requireExpectedVolume(uuid, at: source)
        guard mountFlags(source).map({ $0 & mask == original }) == true else {
            throw DataOperationSafety.Failure.inspection(source.path)
        }
    }

    func cancelPreparation(_ expected: DataTransferRecord, preserveUnclaimedMaterials: Bool) async throws {
        try await withPreparationOwnership(expected, required: !preserveUnclaimedMaterials) {
            try await cancelPreparationUsingOwners(expected, preserveUnclaimedMaterials: preserveUnclaimedMaterials)
        }
    }

    private func cancelPreparationUsingOwners(_ expected: DataTransferRecord, preserveUnclaimedMaterials: Bool) async throws {
        var transfer = expected
        try requirePreparationLedger(transfer)
        try requireUnswitchedMountEntry(transfer)
        if preserveUnclaimedMaterials {
            try await restorePreparationMountOptions(transfer)
            if transfer.recoveryMountPointIdentity != nil, transfer.stagingParentIdentity != nil {
                try await releasePrivateRestoreMount(transfer)
            }
            try store.endUnswitchedTransfer(transfer,
                preserving: "已结束未切换的尝试；卷和暂存材料保留在已知位置，未按卷名或路径猜测并删除。".localized) {
                try requireUnswitchedMountEntry(transfer)
            }
            synchronizeAgent(store)
            return
        }
        if transfer.direction == .migrate {
            try await removeUnactivatedMigrationVolume(transfer)
            transfer = try store.transfer(operationID: transfer.operationID) ?? transfer
            try requirePreparationLedger(transfer)
            try store.endUnswitchedTransfer(transfer) { try requireUnswitchedMountEntry(transfer) }
            synchronizeAgent(store)
            return
        }
        let source: URL
        if transfer.direction == .restore, transfer.sourceBaseline == nil,
           transfer.destinationIdentity == nil, let staging = transfer.stagingPath,
           try !verifiedResumeEntryExists(URL(fileURLWithPath: staging)) {
            // Includes source-inspected/no-target-created. No content is
            // discarded, so an offline source does not block ending this intent.
            try await restorePreparationMountOptions(transfer)
            try await releasePrivateRestoreMount(transfer)
            try store.endUnswitchedTransfer(transfer) { try requireUnswitchedMountEntry(transfer) }
            synchronizeAgent(store)
            return
        } else { source = try await mountPreparationSource(transfer, verifyContents: true) }
        try await safety.requireNoKnownWriters(at: source, bundleIdentifier: transfer.bundleIdentifier)
        _ = try await mountPreparationSource(transfer, verifyContents: true)
        do {
            guard let path = transfer.stagingPath, let parentIdentity = transfer.preparationParentIdentity,
                  let destinationIdentity = transfer.destinationIdentity, let encoded = transfer.sourceBaseline else {
                throw DataOperationSafety.Failure.inspection(transfer.originalPath)
            }
            let staging = URL(fileURLWithPath: path), parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            guard try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity) else {
                throw DataOperationSafety.Failure.conflict(parent.path)
            }
            if let actual = try TreeCopySession.retainedRemovalURL(at: staging, removalID: transfer.operationID) {
                guard !isMountPoint(actual), !isSymbolicLink(at: actual),
                      try DataPathIdentity.capture(actual).matchesFilesystemObject(destinationIdentity) else {
                    throw DataOperationSafety.Failure.conflict(actual.path)
                }
                let wasRemoving = transfer.preparationRemovalBaseline != nil
                let partial: TreeCopySnapshot
                if let saved = transfer.preparationRemovalBaseline { partial = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: saved) }
                else {
                    partial = try TreeCopySession.partialCopySnapshot(at: staging, source: source,
                        against: PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded),
                        sourceVolumeUUID: transfer.sourceIdentity.volumeUUID)
                    transfer.preparationRemovalBaseline = try PropertyListEncoder().encode(partial)
                    transfer.preparationRemovalParentIdentity = parentIdentity
                    try store.updateTransfer(transfer)
                }
                try DurableFileIO.syncTree(at: source, excludingRootEntries: Self.volumeSystemArtifacts)
                try store.recheckWriterAdmission()
                try TreeCopySession.removeVerifiedCopy(at: staging, against: partial, allowPartialRemoval: wasRemoving,
                    expectedVolumeUUID: destinationIdentity.volumeUUID, removalID: transfer.operationID)
            } else if transfer.preparationRemovalParentIdentity == nil {
                throw DataOperationSafety.Failure.inspection(staging.path)
            }
            try DurableFileIO.syncDirectory(at: parent)
            try await restorePreparationMountOptions(transfer)
            try await releasePrivateRestoreMount(transfer)
        }
        try requirePreparationLedger(transfer)
        try store.endUnswitchedTransfer(transfer) { try requireUnswitchedMountEntry(transfer) }
        synchronizeAgent(store)
    }

    private func restorePreparationMountOptions(_ transfer: DataTransferRecord) async throws {
        let local = URL(fileURLWithPath: transfer.originalPath)
        guard let flags = transfer.originalSourceMountFlags ?? transfer.legacyMountFlags,
              flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0, isMountPoint(local),
              let uuid = transfer.sourceIdentity.volumeUUID else { return }
        try await requireExpectedVolume(uuid, at: local)
        let mask = UInt32(MNT_IGNORE_OWNERSHIP | MNT_DONTBROWSE | MNT_RDONLY | MNT_NODEV | MNT_NOSUID | MNT_NOEXEC)
        guard let current = mountFlags(local) else { throw DataOperationSafety.Failure.inspection(local.path) }
        if current & UInt32(MNT_IGNORE_OWNERSHIP) != 0 { return }
        guard current & mask == (flags | UInt32(MNT_DONTBROWSE)) & mask & ~UInt32(MNT_IGNORE_OWNERSHIP) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        try requirePreparationLedger(transfer)
        try await restoreOriginalMountOptions(mountPoint: local, volumeUUID: uuid, originalFlags: flags)
        guard mountFlags(local).map({ $0 & mask == (flags | UInt32(MNT_DONTBROWSE)) & mask }) == true else {
            throw DataOperationSafety.Failure.inspection(local.path)
        }
    }

    private func releasePrivateRestoreMount(_ transfer: DataTransferRecord) async throws {
        guard let path = transfer.backupPath else { return }
        let recovery = URL(fileURLWithPath: path)
        let parent = recovery.deletingLastPathComponent()
        let exists = try verifiedResumeEntryExists(recovery)
        guard let parentIdentity = transfer.stagingParentIdentity else {
            // An online restore may never create a private mount point. No
            // recorded claim plus an absent entry has no removal to finish.
            guard transfer.recoveryMountPointIdentity == nil, !exists else {
                throw DataOperationSafety.Failure.conflict(parent.path)
            }
            return
        }
        guard try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity) else {
            throw DataOperationSafety.Failure.conflict(parent.path)
        }
        if exists {
            guard let identity = transfer.recoveryMountPointIdentity else {
                throw DataOperationSafety.Failure.inspection(path)
            }
            if isMountPoint(recovery) {
                guard let uuid = transfer.sourceIdentity.volumeUUID else { throw DataOperationSafety.Failure.inspection(path) }
                try await requireExpectedVolume(uuid, at: recovery)
                try requirePreparationLedger(transfer)
                try requireUnswitchedMountEntry(transfer)
                guard try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity) else {
                    throw DataOperationSafety.Failure.conflict(parent.path)
                }
                if transfer.sourceIdentity.isResolved,
                   try !DataPathIdentity.capture(recovery, volumeUUID: uuid).matchesFilesystemObject(transfer.sourceIdentity) {
                    throw DataOperationSafety.Failure.conflict(path)
                }
                try await unmountVolume(mountPoint: recovery)
            }
            if try verifiedResumeEntryExists(recovery) {
                try store.recheckWriterAdmission()
                guard !isMountPoint(recovery),
                      try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity),
                      try DataPathIdentity.capture(recovery).matchesFilesystemObject(identity) else {
                    throw DataOperationSafety.Failure.conflict(path)
                }
                try removeEmptyMountPoint(at: recovery)
            }
        }
        // This parent differs from the local restore staging parent. Even an
        // already removed mount point still owes its own durable barrier.
        try requirePreparationLedger(transfer)
        try requireUnswitchedMountEntry(transfer)
        guard try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity) else {
            throw DataOperationSafety.Failure.conflict(parent.path)
        }
        try synchronizeCleanupParent(parent)
        guard try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity),
              try !verifiedResumeEntryExists(recovery) else {
            throw DataOperationSafety.Failure.conflict(parent.path)
        }
    }

    struct VerifiedMountResume {
        var transfer: DataTransferRecord
        var transfers: [DataTransferRecord]
        var mounts: [ContainerMountRecord]
        let links: [ManagedDataLinkRecord]
        let cleanups: [ContainerCleanupRecord]
    }

    struct RecoveryJournalChanged: LocalizedError {
        let operation: Error
        var errorDescription: String? { operation.localizedDescription }

        static func isContained(in error: Error) -> Bool {
            if error is Self { return true }
            if case MigrationError.ownershipRollbackFailed(_, let operation, let rollback) = error {
                return isContained(in: operation) || isContained(in: rollback)
            }
            return false
        }
    }

    /// Continue only the already verified copy, under the caller's operation
    /// lock. A restart must never create another volume or recopy over either
    /// surviving tree just because the last record write failed.
    func resumeVerifiedTransfer(operationID: UUID, progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
        let launchDirectory = store.fileURLForDeletionAuthorization.deletingLastPathComponent().appendingPathComponent("launch-locks", isDirectory: true)
        let launchIdentifier = try store.transfer(operationID: operationID)?.bundleIdentifier
        if !ApplicationLaunchProtection.contains(launchIdentifier, directory: launchDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: launchIdentifier, directory: launchDirectory) {
                try await self.resumeVerifiedTransfer(operationID: operationID, progressHandler: progressHandler)
            }
        }
        if DataTransferSession.current == nil {
            return try await DataTransferSession.run {
                try await self.resumeVerifiedTransfer(operationID: operationID, progressHandler: progressHandler)
            }
        }
        guard let saved = try store.transfer(operationID: operationID) else { return nil }
        let transfer = try store.adoptLegacyRestoreOwnership(saved)
        guard transfer.mode == .mount else { throw DataOperationSafety.Failure.inspection(operationID.uuidString) }
        if transfer.rollbackCompletedAt != nil {
            // Surface a typed unlock request to manual recovery instead of burying it in a cleanup warning.
            if transfer.recoveryMountRecord?.isEncrypted == true, let uuid = transfer.createdVolumeUUID,
               let container = transfer.volumeCreationContainerUUID,
               try await disk.apfsVolumeIsPresent(uuid, inContainer: container) {
                try await unlockIfNeeded(try await disk.volumeInfo(for: uuid))
            }
            if case .rolledBack(let details) = try await recoverWithIndependentBudget(transfer) { return details }
            return nil
        }
        let path = URL(fileURLWithPath: transfer.originalPath).standardizedFileURL.path
        DataTransferSession.progress?.setDirectory(URL(fileURLWithPath: path))
        DataTransferSession.progress?.observeDirectoryWorkflow()
        // Admission failures belong to the caller that failed to acquire the
        // path. They must never recover or cancel the operation that owns it.
        guard completingPaths.insert(path).inserted else { throw DataOperationSafety.Failure.occupied(path) }
        defer { completingPaths.remove(path) }
        do { return try await resumeMountTransfer(transfer, progressHandler: progressHandler) }
        catch let changed as RecoveryJournalChanged { throw changed.operation }
        catch {
            guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
            guard let pending = try store.transfer(operationID: operationID), pending.mode == .mount else { throw error }
            let completed = try await recoverFailedMountOperation(at: pending.originalPath, direction: pending.direction,
                operation: error)
            return await completeVerifiedMountResume(completed, progressHandler: progressHandler, requireUnchangedActive: false)
        }
    }

    private func resumeMountTransfer(_ expected: DataTransferRecord, progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
        var transfer = expected
        if transfer.isPreparationRecoverable {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "重试".localized, showsByteProgress: false, stage: .recovering))
            try requirePreparationLedger(transfer)
            if let verified = try await promoteCompletePreparation(transfer) { transfer = verified }
            else { return try await restartPreparation(transfer, progressHandler: progressHandler) }
        }
        guard transfer.mode == .mount else {
            throw DataOperationSafety.Failure.inspection(transfer.operationID.uuidString)
        }
        let path = URL(fileURLWithPath: transfer.originalPath).standardizedFileURL.path
        if transfer.isDataSwitchComplete {
            DataTransferSession.progress?.observeResumedCopy(cleanup: true)
            return await completeVerifiedMountResume(transfer, progressHandler: progressHandler, requireUnchangedActive: false)
        }
        guard transfer.isVerifiedSwitchRecoverable, transfer.cleanupVolumeContainerUUID == nil,
              let encoded = transfer.baseline else {
            throw DataOperationSafety.Failure.inspection(transfer.operationID.uuidString)
        }
        DataTransferSession.progress?.observeResumedCopy(cleanup: false)
        var state = VerifiedMountResume(transfer: transfer, transfers: try store.transfers(), mounts: try store.recordsStrict(),
            links: try store.managedLinks(), cleanups: try store.pendingCleanups())
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        do {
            try requireVerifiedResumeLedger(state)
            try requireVerifiedResumeTopology(state)
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0,
                currentFile: "正在切换本地入口...".localized, showsByteProgress: false, stage: .switching))
            try requireVerifiedResumeLedger(state)
            if transfer.direction == .migrate {
                try await resumeVerifiedMountMigration(&state, baseline: baseline)
            } else {
                try await resumeVerifiedMountRestore(&state, baseline: baseline)
            }
        } catch {
            // Never replace a record changed by another operation while a disk
            // or process inspection was suspended.
            do {
                try requireVerifiedResumeLedger(state)
                var failed = state.transfer
                failed.phase = .needsRecovery
                failed.recoverableReason = error.localizedDescription
                try store.updateTransfer(failed)
            } catch {
                AppLogger.shared.logError("无法更新迁移恢复记录，原事务仍保留", error: error)
                throw RecoveryJournalChanged(operation: error)
            }
            throw error
        }
        synchronizeAgent(store)
        invalidateSizeCache(for: URL(fileURLWithPath: path))
        return await completeVerifiedMountResume(state.transfer, progressHandler: progressHandler, requireUnchangedActive: false)
    }

    private func completeVerifiedMountResume(_ transfer: DataTransferRecord, progressHandler: FileCopier.ProgressHandler?,
                                             requireUnchangedActive: Bool = true) async -> String? {
        if let record = transfer.recoveryMountRecord {
            return await completeSuccessfulTransfer(operationID: transfer.operationID, direction: transfer.direction,
                record: record, progressHandler: progressHandler, requireUnchangedActive: requireUnchangedActive)?.message
        }
        // Historical restores may predate the saved mount record. Their exact
        // local destination still proves completion; an offline old volume is
        // a cleanup warning, not a reason to leave restored data locked.
        do {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0,
                currentFile: "正在清理旧副本...".localized, showsByteProgress: false, stage: .cleaning))
            guard let current = try store.transfer(operationID: transfer.operationID) else { return nil }
            try await requireActiveData(for: current)
            if requireUnchangedActive, let baseline = current.baseline {
                try TreeCopySession.verifyCopy(at: URL(fileURLWithPath: current.activePath),
                    against: PropertyListDecoder().decode(TreeCopySnapshot.self, from: baseline), purpose: .activeData)
            }
            try await cleanupRetainedLineage(operationID: transfer.operationID)
            return nil
        } catch {
            let format = transfer.direction == .restore
                ? "数据已还原到本地，但旧副本尚未全部清理。%@".localized
                : "迁移已完成，但旧副本尚未全部清理。%@".localized
            return String(format: format, "\n" + error.localizedDescription)
        }
    }

    func requireVerifiedResumeLedger(_ state: VerifiedMountResume) throws {
        guard try store.transfers() == state.transfers,
              try store.recordsStrict() == state.mounts,
              try store.managedLinks() == state.links,
              try store.pendingCleanups() == state.cleanups else {
            throw DataOperationSafety.Failure.conflict(state.transfer.originalPath)
        }
    }

    private func saveVerifiedResume(_ transfer: DataTransferRecord, state: inout VerifiedMountResume) throws {
        try requireVerifiedResumeLedger(state)
        try store.updateTransfer(transfer)
        state.transfer = transfer
        state.transfers = state.transfers.map { $0.operationID == transfer.operationID ? transfer : $0 }
    }

    func requireVerifiedResumeTopology(_ state: VerifiedMountResume) throws {
        let transfer = state.transfer
        let local = URL(fileURLWithPath: transfer.originalPath).standardizedFileURL
        guard local.path == transfer.originalPath, transfer.destinationPath == local.path,
              let backupPath = transfer.backupPath, let stagingPath = transfer.stagingPath,
              !state.transfers.contains(where: { $0.priorOperationID == transfer.operationID }) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        let backup = URL(fileURLWithPath: backupPath).standardizedFileURL
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL
        guard backup.path == backupPath, staging.path == stagingPath else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        if transfer.direction == .migrate {
            let prefix = ".appports-migration-backup-\(local.lastPathComponent)-"
            guard backup.deletingLastPathComponent().path == local.deletingLastPathComponent().path,
                  backup.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(backup.lastPathComponent.dropFirst(prefix.count))) != nil,
                  staging.path == stagingMountRootURL.appendingPathComponent(transfer.operationID.uuidString).standardizedFileURL.path,
                  let record = transfer.recoveryMountRecord,
                  record.mountPointPath == local.path,
                  record.volumeUUID.caseInsensitiveCompare(transfer.createdVolumeUUID ?? "") == .orderedSame else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            if !isMountPoint(local) {
                try safety.requireExistingMigrationPolicy(at: local, bundleIdentifier: transfer.bundleIdentifier)
            }
        } else {
            guard staging.path == local.deletingLastPathComponent()
                    .appendingPathComponent(".appports-restore-staging-\(transfer.operationID.uuidString)").path,
                  backup.path == stagingMountRootURL.appendingPathComponent("recovery-\(transfer.operationID.uuidString)").standardizedFileURL.path else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            try safety.requireLocalRestoreParent(at: local, isMountPoint: isMountPoint)
        }
        let ownedIDs = try transferAncestors(of: transfer, in: state.transfers)
        let mount = state.mounts.first { $0.mountPointPath == transfer.originalPath }
        if let mount, let expected = transfer.recoveryMountRecord, mount != expected {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        for url in [local, backup, staging] {
            try safety.requireNoOverlap(at: url, ownedMount: mount, ownedTransferIDs: ownedIDs, ownedRetainedPath: url.path)
            try safety.requireNoManagedFileSystemAncestor(at: url)
        }
    }

    func verifiedResumeEntryExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw DataOperationSafety.Failure.inspection(url.path) }
        return false
    }

    private func requireVerifiedResumeCopy(at url: URL, identity: DataPathIdentity,
                                           baseline: TreeCopySnapshot, volumeUUID: String? = nil) throws {
        guard !isSymbolicLink(at: url),
              try DataPathIdentity.capture(url, volumeUUID: volumeUUID).matchesFilesystemObject(identity) else {
            throw DataOperationSafety.Failure.conflict(url.path)
        }
        try TreeCopySession.verifyCopy(at: url, against: baseline)
    }

    private func requireVerifiedResumeOriginal(at url: URL, identity: DataPathIdentity,
                                               baseline: TreeCopySnapshot, volumeUUID: String? = nil) throws {
        guard !isSymbolicLink(at: url),
              try DataPathIdentity.capture(url, volumeUUID: volumeUUID).matchesFilesystemObject(identity) else {
            throw DataOperationSafety.Failure.conflict(url.path)
        }
        if let volumeUUID {
            try TreeCopySession.verifyUnchanged(at: url, against: baseline, expectedVolumeUUID: volumeUUID)
        } else {
            try TreeCopySession.verifyUnchanged(at: url, against: baseline)
        }
    }

    private func verifiedResumeAutomaticPath(_ uuid: String, state: VerifiedMountResume) -> URL? {
        let record = state.transfer.recoveryMountRecord ?? state.mounts.first {
            $0.mountPointPath == state.transfer.originalPath && $0.volumeUUID.caseInsensitiveCompare(uuid) == .orderedSame
        }
        guard let record, record.volumeUUID.caseInsensitiveCompare(uuid) == .orderedSame else { return nil }
        let candidate = URL(fileURLWithPath: Self.autoMountRoot).appendingPathComponent(record.volumeName).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == Self.autoMountRoot,
              !isSymbolicLink(at: candidate), isMountPoint(candidate),
              volumeUUIDMarker(candidate)?.caseInsensitiveCompare(uuid) == .orderedSame else { return nil }
        return candidate
    }

    /// Accept recorded landing locations and the exact, marked automatic mount
    /// of this saved volume. Other user-selected mount locations stay untouched.
    private func verifiedResumeVolume(_ uuid: String, allowedAt paths: [URL], state: VerifiedMountResume) async throws -> URL? {
        let info = try await disk.volumeInfo(for: uuid)
        try requireVerifiedResumeLedger(state)
        guard info.isAPFS, info.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame else {
            throw DataOperationSafety.Failure.inspection(uuid)
        }
        guard let path = info.mountPoint, !path.isEmpty else { return nil }
        let automatic = verifiedResumeAutomaticPath(uuid, state: state)
        guard let known = paths.first(where: { DiskUtility.pathsMatch($0.path, path) })
                ?? automatic.flatMap({ DiskUtility.pathsMatch($0.path, path) ? $0 : nil }) else {
            throw DataOperationSafety.Failure.conflict(path)
        }
        if known == automatic {
            try safety.requireNoOverlap(at: known)
            try safety.requireNoManagedFileSystemAncestor(at: known)
        }
        try await requireExpectedVolume(uuid, at: known)
        try requireVerifiedResumeLedger(state)
        return known
    }

    func resumeVerifiedMountMigration(_ state: inout VerifiedMountResume, baseline: TreeCopySnapshot) async throws {
        let transfer = state.transfer
        let requiresOwnership = baseline.ownershipCompatibility?.destinationIgnoresOwnership != true
        guard let record = transfer.recoveryMountRecord, let uuid = transfer.createdVolumeUUID,
              let destinationIdentity = transfer.destinationIdentity,
              let backupPath = transfer.backupPath, let stagingPath = transfer.stagingPath else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let local = URL(fileURLWithPath: transfer.originalPath)
        let backup = URL(fileURLWithPath: backupPath)
        let staging = URL(fileURLWithPath: stagingPath)
        if !isMountPoint(local), transfer.backupIdentity != nil {
            DataTransferSession.progress?.observeEntrySwitch()
            // The source was already moved after successful copy verification.
            // Following a reboot the same destination may contain application
            // writes at /Volumes. Finish its activation; never replace it with
            // the old baseline or require newer data to equal that baseline.
            if try verifiedResumeEntryExists(backup) {
                try requireVerifiedResumeOriginal(at: backup, identity: transfer.sourceIdentity, baseline: baseline)
            }
            let current = try await verifiedResumeVolume(uuid, allowedAt: [staging], state: state)
            if let current {
                try await safety.requireNoKnownWriters(at: current, bundleIdentifier: transfer.bundleIdentifier)
                try requireVolumeMarker(at: current, record: record)
                guard try DataPathIdentity.capture(current, volumeUUID: uuid).matchesFilesystemObject(destinationIdentity) else {
                    throw DataOperationSafety.Failure.conflict(current.path)
                }
            }
            try requireVerifiedResumeLedger(state)
            try safety.requireLocalRestoreParent(at: local, isMountPoint: isMountPoint)
            var activating = state.transfer
            activating.candidateActivationAttempted = true
            try saveVerifiedResume(activating, state: &state)
            let expectedState = state
            DataTransferSession.progress?.observeEntrySwitch()
            try await mountVolume(uuid, at: local, operationID: transfer.operationID.uuidString,
                knownMountPoint: current.map { .mounted(at: $0) } ?? .unmounted,
                requireOwnership: requiresOwnership,
                validateBeforeMutation: {
                    try self.requireVerifiedResumeLedger(expectedState)
                    try self.requireVerifiedResumeTopology(expectedState)
                    if try self.verifiedResumeEntryExists(backup) {
                        try self.requireVerifiedResumeOriginal(at: backup, identity: transfer.sourceIdentity, baseline: baseline)
                    }
                })
            try requireVolumeMarker(at: local, record: record)
        }
        // The saved verified root, exact UUID and marker prove activation.
        // Application writes after this point do not invalidate that fact; the
        // old baseline remains reserved for checking the retained original.
        if isMountPoint(local) {
            try await requireExpectedVolume(uuid, at: local)
            try requireVerifiedResumeLedger(state)
            guard (volumeUUIDMarker(local) ?? Self.readVolumeMarkerUUID(at: local))?.caseInsensitiveCompare(uuid) == .orderedSame,
                  try DataPathIdentity.capture(local, volumeUUID: uuid).matchesFilesystemObject(destinationIdentity) else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            DataTransferSession.progress?.observeEntrySwitch()
            var completed = state.transfer
            // Activation is proven by the live volume. A missing or replaced
            // old backup may prevent cleanup, but cannot prevent data retrieval.
            completed.backupIdentity = completed.backupIdentity ?? transfer.sourceIdentity
            completed.phase = .switching
            completed.candidateActivationAttempted = true
            completed.recoverableReason = nil
            try saveVerifiedResume(completed, state: &state)
            try DurableFileIO.syncTree(at: local, excludingRootEntries: Self.volumeSystemArtifacts)
            try DurableFileIO.syncDirectory(at: local.deletingLastPathComponent())
            try store.commitMigration(record: record, transfer: state.transfer)
            return
        }
        let hasBackup = try verifiedResumeEntryExists(backup)
        let original = hasBackup ? backup : local
        guard !isMountPoint(original) else { throw DataOperationSafety.Failure.conflict(original.path) }
        try requireVerifiedResumeOriginal(at: original, identity: transfer.sourceIdentity, baseline: baseline)
        if let expected = transfer.backupIdentity {
            guard hasBackup, try DataPathIdentity.capture(backup).matchesFilesystemObject(expected) else {
                throw DataOperationSafety.Failure.conflict(backup.path)
            }
        }
        try await safety.requireNoKnownWriters(at: original, bundleIdentifier: transfer.bundleIdentifier)
        try requireVerifiedResumeLedger(state)
        var volumeRoot = try await verifiedResumeVolume(uuid, allowedAt: [local, staging], state: state)
        if volumeRoot == local, !hasBackup { throw DataOperationSafety.Failure.conflict(local.path) }
        if isMountPoint(local), volumeRoot != local { throw DataOperationSafety.Failure.conflict(local.path) }
        if let automatic = volumeRoot, automatic != local, automatic != staging {
            try await safety.requireNoKnownWriters(at: automatic, bundleIdentifier: transfer.bundleIdentifier)
            try await requireExpectedVolume(uuid, at: automatic)
            try requireVerifiedResumeLedger(state)
            guard verifiedResumeAutomaticPath(uuid, state: state) == automatic else {
                throw DataOperationSafety.Failure.conflict(automatic.path)
            }
            try requireVerifiedResumeOriginal(at: original, identity: transfer.sourceIdentity, baseline: baseline)
            // Relocate the same proven volume privately, keeping the policy
            // recorded by its copy. New noowners copies stay noowners.
            try await unmountVolume(mountPoint: automatic)
            try requireVerifiedResumeLedger(state)
            guard !isMountPoint(automatic) else { throw MigrationError.unmountFailed(automatic, "") }
            volumeRoot = nil
        }
        if volumeRoot == nil {
            guard !isMountPoint(staging), !isSymbolicLink(at: staging) else {
                throw DataOperationSafety.Failure.conflict(staging.path)
            }
            try requireVerifiedResumeOriginal(at: original, identity: transfer.sourceIdentity, baseline: baseline)
            try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            let expectedState = state
            try await mountVolume(uuid, at: staging, operationID: transfer.operationID.uuidString, allowRelocation: false,
                requireOwnership: requiresOwnership,
                validateBeforeMutation: {
                    try self.requireVerifiedResumeLedger(expectedState)
                    try self.requireVerifiedResumeTopology(expectedState)
                    guard !self.isMountPoint(original), !self.isMountPoint(staging) else {
                        throw DataOperationSafety.Failure.conflict(original.path)
                    }
                    try self.requireVerifiedResumeOriginal(at: original, identity: transfer.sourceIdentity, baseline: baseline)
                })
            volumeRoot = staging
        }
        guard let copied = volumeRoot else { throw DataOperationSafety.Failure.inspection(staging.path) }
        try await requireExpectedVolume(uuid, at: copied)
        try await safety.requireNoKnownWriters(at: copied, bundleIdentifier: transfer.bundleIdentifier)
        try await requireExpectedVolume(uuid, at: copied)
        try requireVerifiedResumeLedger(state)
        if requiresOwnership { try requireOwners(at: copied) }
        try requireVerifiedResumeCopy(at: copied, identity: destinationIdentity, baseline: baseline, volumeUUID: uuid)
        try requireVerifiedResumeOriginal(at: original, identity: transfer.sourceIdentity, baseline: baseline)
        var switching = state.transfer
        switching.phase = .switching
        switching.recoverableReason = nil
        if hasBackup, switching.backupIdentity == nil { switching.backupIdentity = try DataPathIdentity.capture(backup) }
        try saveVerifiedResume(switching, state: &state)
        if copied != local {
            try await requireExpectedVolume(uuid, at: copied)
            try requireVerifiedResumeLedger(state)
            try requireVerifiedResumeCopy(at: copied, identity: destinationIdentity, baseline: baseline, volumeUUID: uuid)
            try requireVerifiedResumeOriginal(at: original, identity: transfer.sourceIdentity, baseline: baseline)
            try DurableFileIO.syncTree(at: copied, excludingRootEntries: Self.volumeSystemArtifacts)
            try await unmountVolume(mountPoint: copied)
            try requireVerifiedResumeLedger(state)
            guard !isMountPoint(copied) else { throw MigrationError.unmountFailed(copied, "") }
            removeEmptyDirectoryQuietly(at: copied)
            if !hasBackup {
                guard try !verifiedResumeEntryExists(backup), !isMountPoint(local) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
                try requireVerifiedResumeOriginal(at: local, identity: transfer.sourceIdentity, baseline: baseline)
                DataTransferSession.progress?.observeEntrySwitch()
                try moveTree(local, to: backup)
                try DurableFileIO.syncDirectory(at: local.deletingLastPathComponent())
                var moved = state.transfer
                moved.backupIdentity = try DataPathIdentity.capture(backup)
                try saveVerifiedResume(moved, state: &state)
            }
            try requireVerifiedResumeOriginal(at: backup, identity: transfer.sourceIdentity, baseline: baseline)
            try requireVerifiedResumeLedger(state)
            var activating = state.transfer
            activating.candidateActivationAttempted = true
            try saveVerifiedResume(activating, state: &state)
            let expectedState = state
            DataTransferSession.progress?.observeEntrySwitch()
            try await mountVolume(uuid, at: local, operationID: transfer.operationID.uuidString, allowRelocation: false,
                requireOwnership: requiresOwnership,
                validateBeforeMutation: {
                    try self.requireVerifiedResumeLedger(expectedState)
                    try self.requireVerifiedResumeTopology(expectedState)
                    guard !self.isMountPoint(local), !self.isMountPoint(backup) else {
                        throw DataOperationSafety.Failure.conflict(local.path)
                    }
                    try self.requireVerifiedResumeOriginal(at: backup, identity: transfer.sourceIdentity, baseline: baseline)
                })
        }
        try await requireExpectedVolume(uuid, at: local)
        try requireVerifiedResumeLedger(state)
        if requiresOwnership { try requireOwners(at: local) }
        guard try DataPathIdentity.capture(local, volumeUUID: uuid).matchesFilesystemObject(destinationIdentity) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        try DurableFileIO.syncTree(at: local, excludingRootEntries: Self.volumeSystemArtifacts)
        try DurableFileIO.syncDirectory(at: local.deletingLastPathComponent())
        try store.commitMigration(record: record, transfer: state.transfer)
    }

    private func beginVerifiedResumeRestore(_ state: inout VerifiedMountResume) throws {
        var switching = state.transfer
        switching.phase = .switching
        switching.recoverableReason = nil
        let recorded = state.mounts.first { $0.mountPointPath == switching.originalPath }
        if let recorded {
            guard recorded.volumeUUID.caseInsensitiveCompare(switching.sourceIdentity.volumeUUID ?? "") == .orderedSame,
                  recorded.appName == switching.appName, recorded.bundleIdentifier == switching.bundleIdentifier,
                  recorded.dataDirType == switching.dataDirType,
                  switching.recoveryMountRecord == nil || switching.recoveryMountRecord == recorded else {
                throw DataOperationSafety.Failure.conflict(switching.originalPath)
            }
            switching.recoveryMountRecord = switching.recoveryMountRecord ?? recorded
        }
        if let record = switching.recoveryMountRecord {
            try requireVerifiedResumeLedger(state)
            try store.beginRestore(transfer: switching, removingMount: record)
            state.transfer = switching
            state.transfers = state.transfers.map { $0.operationID == switching.operationID ? switching : $0 }
            state.mounts.removeAll { $0 == record }
        } else {
            // Older transactions can already have removed their mount entry.
            // There is no record to reconstruct or delete in that case.
            try saveVerifiedResume(switching, state: &state)
        }
        synchronizeAgent(store)
    }

    func resumeVerifiedMountRestore(_ state: inout VerifiedMountResume, baseline: TreeCopySnapshot) async throws {
        let transfer = state.transfer
        let requiresOwnership = baseline.ownershipCompatibility?.sourceIgnoresOwnership != true
        guard let destinationIdentity = transfer.destinationIdentity, let uuid = transfer.sourceIdentity.volumeUUID,
              let backupPath = transfer.backupPath, let stagingPath = transfer.stagingPath,
              transfer.backupIdentity?.matchesFilesystemObject(transfer.sourceIdentity) == true else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let local = URL(fileURLWithPath: transfer.originalPath)
        let staging = URL(fileURLWithPath: stagingPath)
        let recovery = URL(fileURLWithPath: backupPath)
        if !isMountPoint(local), !isSymbolicLink(at: local),
           let identity = try? DataPathIdentity.capture(local), identity.matchesFilesystemObject(destinationIdentity) {
            guard try !verifiedResumeEntryExists(staging) else { throw DataOperationSafety.Failure.conflict(staging.path) }
            try requireVerifiedResumeLedger(state)
            try safety.requireLocalRestoreParent(at: local, isMountPoint: isMountPoint)
            DataTransferSession.progress?.observeEntrySwitch()
            try beginVerifiedResumeRestore(&state)
            try requireVerifiedResumeLedger(state)
            try DurableFileIO.syncTree(at: local, excludingRootEntries: Self.volumeSystemArtifacts)
            try DurableFileIO.syncDirectory(at: local.deletingLastPathComponent())
            try store.finalizeTransfer(operationID: transfer.operationID, baseline: transfer.baseline!)
            return
        }
        guard !isMountPoint(staging) else { throw DataOperationSafety.Failure.conflict(staging.path) }
        try requireVerifiedResumeCopy(at: staging, identity: destinationIdentity, baseline: baseline)
        var volumeRoot = try await verifiedResumeVolume(uuid, allowedAt: [local, recovery], state: state)
        if isMountPoint(local), volumeRoot != local { throw DataOperationSafety.Failure.conflict(local.path) }
        if volumeRoot == nil {
            guard !isMountPoint(recovery), !isSymbolicLink(at: recovery) else {
                throw DataOperationSafety.Failure.conflict(recovery.path)
            }
            try requireVerifiedResumeCopy(at: staging, identity: destinationIdentity, baseline: baseline)
            try fileManager.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
            let expectedState = state
            try await mountVolume(uuid, at: recovery, operationID: transfer.operationID.uuidString, allowRelocation: false,
                requireOwnership: requiresOwnership,
                validateBeforeMutation: {
                    try self.requireVerifiedResumeLedger(expectedState)
                    try self.requireVerifiedResumeTopology(expectedState)
                    guard !self.isMountPoint(staging), !self.isMountPoint(recovery), !self.isMountPoint(local) else {
                        throw DataOperationSafety.Failure.conflict(staging.path)
                    }
                    try self.requireVerifiedResumeCopy(at: staging, identity: destinationIdentity, baseline: baseline)
                })
            volumeRoot = recovery
        }
        guard let source = volumeRoot else { throw DataOperationSafety.Failure.inspection(recovery.path) }
        var ownershipUpdate: (path: URL, flags: UInt32)?
        do {
            try await requireExpectedVolume(uuid, at: source)
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: transfer.bundleIdentifier)
            try await requireExpectedVolume(uuid, at: source)
            try requireVerifiedResumeLedger(state)
            guard let flags = mountFlags(source) else { throw DataOperationSafety.Failure.inspection(source.path) }
            if requiresOwnership, flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 {
                ownershipUpdate = (source, flags)
                try await setOwnershipForRestore(mountPoint: source, originalFlags: flags, enabled: true)
                try await requireExpectedVolume(uuid, at: source)
            }
            try await safety.requireNoKnownWriters(at: staging, bundleIdentifier: transfer.bundleIdentifier)
            try await requireExpectedVolume(uuid, at: source)
            try requireVerifiedResumeLedger(state)
            if requiresOwnership { try requireOwners(at: source) }
            try requireVerifiedResumeOriginal(at: source, identity: transfer.sourceIdentity, baseline: baseline, volumeUUID: uuid)
            try requireVerifiedResumeCopy(at: staging, identity: destinationIdentity, baseline: baseline)
            try DurableFileIO.syncTree(at: staging, excludingRootEntries: Self.volumeSystemArtifacts)
            if source != local, source != recovery, verifiedResumeAutomaticPath(uuid, state: state) != source {
                throw DataOperationSafety.Failure.conflict(source.path)
            }
            try safety.requireLocalRestoreParent(at: local, isMountPoint: isMountPoint)
            try safety.requireMountPointParentAccess(at: local)
            if source != local {
                let lease = try makeMountPointLease(local)
                try lease.verifyBeforeMount()
            }
            try beginVerifiedResumeRestore(&state)
            try await requireExpectedVolume(uuid, at: source)
            try requireVerifiedResumeLedger(state)
            try requireVerifiedResumeOriginal(at: source, identity: transfer.sourceIdentity, baseline: baseline, volumeUUID: uuid)
            try requireVerifiedResumeCopy(at: staging, identity: destinationIdentity, baseline: baseline)
            if source != local, source != recovery, verifiedResumeAutomaticPath(uuid, state: state) != source {
                throw DataOperationSafety.Failure.conflict(source.path)
            }
            try safety.requireMountPointParentAccess(at: local)
            if source == local { DataTransferSession.progress?.observeEntrySwitch() }
            try await unmountVolume(mountPoint: source)
            try requireVerifiedResumeLedger(state)
            guard !isMountPoint(source) else { throw MigrationError.unmountFailed(source, "") }
            try safety.requireLocalRestoreParent(at: local, isMountPoint: isMountPoint)
            if source == recovery { removeEmptyDirectoryQuietly(at: source) }
            if try verifiedResumeEntryExists(local) { try removeEmptyMountPoint(at: local) }
            try requireVerifiedResumeCopy(at: staging, identity: destinationIdentity, baseline: baseline)
            DataTransferSession.progress?.observeEntrySwitch()
            try moveTree(staging, to: local)
            try DurableFileIO.syncDirectory(at: local.deletingLastPathComponent())
            try requireVerifiedResumeLedger(state)
            try store.finalizeTransfer(operationID: transfer.operationID, baseline: transfer.baseline!)
        } catch {
            if let update = ownershipUpdate, isMountPoint(update.path) {
                do {
                    try await restoreOriginalMountOptions(mountPoint: update.path, volumeUUID: uuid, originalFlags: update.flags)
                } catch let rollback {
                    throw MigrationError.ownershipRollbackFailed(update.path, operation: error, rollback: rollback)
                }
            }
            throw error
        }
    }

    /// 把容器内目录迁移到外置盘上的新 APFS 卷，并挂载回原路径。
    ///
    /// - Parameters:
    ///   - item: 要迁移的容器内目录（必须是真实目录，不能是符号链接或挂载点）
    ///   - externalRootURL: 用户选择的外部存储根目录，用来定位外置盘的 APFS 容器
    ///   - appName: 关联应用显示名
    ///   - bundleIdentifier: 关联应用 Bundle ID
    ///   - progressHandler: 复制进度回调
    /// - Returns: 已保存的挂载记录，以及需要向用户显示的清理提示。
    @discardableResult
    func migrate(
        item: DataDirItem,
        externalRootURL: URL,
        appName: String,
        bundleIdentifier: String?,
        progressHandler: FileCopier.ProgressHandler?,
        reusingOperationID: UUID? = nil
    ) async throws -> MigrationResult {
        DataTransferSession.progress?.setDirectory(item.path)
        DataTransferSession.progress?.observeDirectoryWorkflow()
        await progressHandler?(.working(.preparing))
        let source = item.path.standardizedFileURL
        let restored = try completedRestoreLineage(at: source)
        try await safety.requireNewMigration(at: source, bundleIdentifier: bundleIdentifier,
            ownedTransferIDs: Set(restored.map(\.operationID)))
        guard existingRealDirectory(at: source) else { throw MigrationError.sourceNotDirectory(source) }
        guard !isMountPoint(source) else { throw MigrationError.alreadyManaged(source) }
        guard !DataPathTopology.overlaps(DataPathTopology.relationship(source.path, externalRootURL.path)) else {
            throw DataOperationSafety.Failure.conflict(externalRootURL.path)
        }
        // Names reserved for volume management must never hide pre-existing source data.
        let names = try fileManager.contentsOfDirectory(atPath: source.path)
        guard Set(names).isDisjoint(with: Self.volumeSystemArtifacts) else {
            throw DataOperationSafety.Failure.conflict(source.path)
        }
        let externalVolumePath = mountedVolumePath(externalRootURL) ?? externalRootURL.path
        let externalInfo = try await disk.volumeInfo(for: externalVolumePath)
        guard externalInfo.isAPFS, let container = externalInfo.apfsContainerReference else {
            throw MigrationError.externalNotAPFS(externalRootURL)
        }
        guard !externalInfo.isEncrypted || encryption != nil else { throw MigrationError.encryptedDestination }
        if let encryption { try APFSVolumeEncryption.validate(encryption.passphrase) }
        if item.sizeBytes > 0, let available = availableCapacity(externalRootURL) {
            let required = Self.requiredFreeBytes(forDataBytes: item.sizeBytes)
            guard available >= required else { throw MigrationError.insufficientSpace(required: required, available: available) }
        }
        let backup = makeMigrationBackupURL(for: source)
        var transfer = DataTransferRecord(operationID: reusingOperationID ?? UUID(), mode: .mount, direction: .migrate, sourceID: item.id,
            appName: appName, bundleIdentifier: bundleIdentifier, dataDirType: item.type.rawValue,
            originalPath: source.path, activePath: source.path, destinationPath: source.path,
            backupPath: backup.path, sourceIdentity: try DataPathIdentity.capture(source),
            priorOperationID: restored.last?.operationID)
        let operationID = transfer.operationID.uuidString
        let volumeName = DiskUtility.makeVolumeName(bundleIdentifier: bundleIdentifier, appName: appName,
                                                    directoryName: source.lastPathComponent)
        let staging = stagingMountRootURL.appendingPathComponent(operationID)
        transfer.stagingPath = staging.path
        transfer.preparationPath = staging.path
        transfer.candidateActivationAttempted = false
        transfer.volumeCreationContainerUUID = try await disk.apfsCreationContainerUUID(container)
        transfer.volumeCreationName = volumeName
        try store.beginTransfer(transfer)
        do {
            try store.recheckWriterAdmission()
            await progressHandler?(.working(.preparing, detail: "正在创建外置卷...".localized))
            let device = try await disk.createAPFSVolume(inContainer: container, name: volumeName, encryption: encryption)
            let info = try await disk.volumeInfo(for: device)
            guard let uuid = info.volumeUUID else { throw MigrationError.volumeCreationFailed(device) }
            transfer.createdVolumeUUID = uuid
            let record = ContainerMountRecord(appName: appName, bundleIdentifier: bundleIdentifier,
                dataDirType: item.type.rawValue, mountPointPath: source.path, volumeUUID: uuid,
                volumeName: volumeName, externalRootPath: externalRootURL.standardizedFileURL.path,
                createdAt: transfer.createdAt, isEncrypted: encryption == nil ? nil : true)
            transfer.recoveryMountRecord = record
            try store.updateTransfer(transfer)
            if let encryption {
                guard info.isEncrypted else { throw APFSVolumeEncryption.Failure.encryptionNotVerified }
                if info.isLocked { try await disk.unlockVolume(uuid, passphrase: encryption.passphrase) }
                let unlocked = try await disk.volumeInfo(for: uuid)
                guard unlocked.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame,
                      unlocked.isEncrypted, !unlocked.isLocked else {
                    throw APFSVolumeEncryption.Failure.encryptionNotVerified
                }
                try APFSVolumeEncryption.save(encryption, for: uuid)
            }
            try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            transfer.stagingParentIdentity = try DataPathIdentity.capture(staging.deletingLastPathComponent())
            try store.updateTransfer(transfer)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            try DurableFileIO.syncDirectory(at: staging.deletingLastPathComponent())
            transfer.stagingIdentity = try DataPathIdentity.capture(staging)
            try store.updateTransfer(transfer)
            try await mountVolume(uuid, at: staging, operationID: operationID, requireOwnership: false)
            guard try DataPathIdentity.capture(source) == transfer.sourceIdentity else {
                throw DataOperationSafety.Failure.conflict(source.path)
            }
            writeNeverIndexMarkerIfNeeded(at: staging, operationID: operationID)
            // Initialize management files while the new volume is writable. The
            // strict copier applies the source root's final mode (including 0555).
            try writeVolumeMarker(at: staging, mountPointPath: source.path, volumeUUID: uuid,
                                  dataDirType: item.type.rawValue, appName: appName)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copyPreparation(transfer, source: source, destination: staging,
                finalDestination: source, progressHandler: progressHandler)
            transfer = try store.transfer(operationID: transfer.operationID) ?? transfer
            // Read back once after all copy/switch callbacks and inspections.
            // Until then only the preparation baseline authorizes recovery.
            let destinationIdentity = try DataPathIdentity.capture(staging, volumeUUID: uuid)
            await progressHandler?(FileCopier.Progress(copiedBytes: baseline.logicalBytes,
                totalBytes: baseline.logicalBytes, currentFile: "正在切换本地入口...".localized, showsByteProgress: false, stage: .switching))
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: bundleIdentifier)
            try await requireExpectedVolume(uuid, at: staging)
            try TreeCopySession.verifyCopy(at: staging, against: baseline, purpose: .beforeSwitch)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.destinationIdentity = destinationIdentity
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            try await unmountVolume(mountPoint: staging)
            removeEmptyDirectoryQuietly(at: staging)
            transfer.phase = .switching
            try store.updateTransfer(transfer)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            DataTransferSession.progress?.observeEntrySwitch()
            try moveTree(source, to: backup)
            try DurableFileIO.syncDirectory(at: source.deletingLastPathComponent())
            transfer.backupIdentity = try DataPathIdentity.capture(backup)
            try store.updateTransfer(transfer)
            // 同盘改名不复制内容；检查仍为原目录，删除前再核对保留副本。
            guard transfer.backupIdentity?.matchesFilesystemObject(transfer.sourceIdentity) == true else {
                throw DataOperationSafety.Failure.conflict(backup.path)
            }
            transfer.candidateActivationAttempted = true
            try store.updateTransfer(transfer)
            try await mountVolume(uuid, at: source, operationID: operationID, requireOwnership: false)
            // The destination was synchronized before unmount. Cleanup flushes
            // any newly active data before deleting the retained original.
            try DurableFileIO.syncDirectory(at: source.deletingLastPathComponent())
            try store.commitMigration(record: record, transfer: transfer)
            synchronizeAgent(store)
            invalidateSizeCache(for: source)
            return MigrationResult(record: record, cleanupWarning: nil, operationID: transfer.operationID)
        } catch {
            // Never erase a partial or switched copy on an error. Durable intent
            // keeps all known identities available for explicit recovery.
            transfer = (try? store.transfer(operationID: transfer.operationID)) ?? transfer
            if transfer.isDataSwitchComplete { throw error }
            transfer.phase = .needsRecovery
            transfer.recoverableReason = error.localizedDescription
            do { try store.updateTransfer(transfer) }
            catch { AppLogger.shared.logError("无法更新迁移恢复记录，原事务仍保留", error: error) }
            throw error
        }
    }

    // MARK: - 挂载 / 卸载

    /// 把记录对应的卷重新挂到容器内挂载点上；已挂载则直接返回。
    func mount(record: ContainerMountRecord) async throws {
        try await mount(record: record, resumingManualPause: false)
    }

    func mount(record: ContainerMountRecord, resumingManualPause: Bool) async throws {
        if !resumingManualPause, try store.isManuallyUnmounted(record) {
            throw ManualMountPauseError.paused
        }
        try await mountRecordedVolume(record)
        if resumingManualPause { try store.setManuallyUnmounted(false, record: record) }
    }

    private func mountRecordedVolume(_ record: ContainerMountRecord) async throws {
        let mountPoint = record.mountPointURL
        guard try !DiskEjectionPauseStore(store: store).snapshot().blocks(volumeUUIDs: [record.volumeUUID],
            paths: [record.mountPointPath, record.externalRootPath]) else { throw DiskEjectionError.paused }
        guard try store.recordsStrict().contains(record) else { throw DataOperationSafety.Failure.conflict(mountPoint.path) }
        try safety.requireExistingMigrationPolicy(at: mountPoint, bundleIdentifier: record.bundleIdentifier)
        let ownedIDs = try ownedMigrationTransferIDs(for: record)
        if !isMountPoint(mountPoint),
           let pending = try pendingMountTransfer(at: record.mountPointPath, direction: .restore),
           pending.isPreparationRecoverable, !pending.isUnstartedMountRestore {
            guard pending.needsAutomaticCompletion else { throw RecoveryPaused() }
            // A partial restore still owns this source. Reconnect through its
            // recovery transaction instead of rejecting its own reservation or
            // treating the unfinished candidate as authoritative data.
            try safety.requireNoOverlap(at: mountPoint, ownedMount: record,
                ownedTransferIDs: ownedIDs.union([pending.operationID]))
            try requirePreparationLedger(pending)
            try requireUnswitchedMountEntry(pending)
            _ = try await recoverWithIndependentBudget(pending, finishPreparedRestore: false)
            return try await mountRecordedVolume(record)
        }
        let compatibleRestores = try await remountCompatibleRestoreIDs(record: record)
        let requiresOwnership = record.ownershipPolicy == .owners
        if isMountPoint(mountPoint) {
            try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
            if try store.remountIntervention(forVolumeUUID: record.volumeUUID) != nil {
                throw DataOperationSafety.Failure.conflict(mountPoint.path)
            }
            if requiresOwnership { try requireOwners(at: mountPoint) }
            if !compatibleRestores.isEmpty {
                try safety.requireNoOverlap(at: mountPoint, ownedMount: record,
                    ownedTransferIDs: ownedIDs.union(compatibleRestores))
            }
            AppDataShortcutService.update(for: record)
            return
        }
        try safety.requireNoOverlap(at: mountPoint, ownedMount: record,
                                    ownedTransferIDs: ownedIDs.union(compatibleRestores))
        try safety.requireNoManagedFileSystemAncestor(at: mountPoint)
        let operationID = AppLogger.shared.makeOperationID(prefix: "container-mount")
        let hint = try await knownMountPoint(for: record, operationID: operationID)
        try await mountVolume(record.volumeUUID, at: mountPoint, operationID: operationID, knownMountPoint: hint,
                              requireOwnership: requiresOwnership)
        try store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: nil)
        invalidateSizeCache(for: mountPoint)
        AppDataShortcutService.update(for: record)
        AppLogger.shared.logContext(
            "容器卷已挂载",
            details: [("operation_id", operationID), ("volume", record.volumeName), ("mount_point", mountPoint.path)]
        )
    }

    /// 卷现在挂在哪。
    ///
    /// 先试**零成本**的快路径：开机和插盘时系统几乎总是先把卷挂到 `/Volumes/<卷名>`，
    /// 用 `statfs` 看一眼这个路径、再读一次卷根标记就能确认是不是我们要的卷
    /// —— 2026-09-23 开机实测那次 `diskutil info` 花了 **9 秒**（登录后系统正忙），
    /// 是整条挂载链路上最贵的一步，能省就省。
    /// 认不出来（卷名被系统改名、标记缺失、卷根本没挂上）才退回一次 `diskutil` 查询，
    /// 那一次同时回答「卷在不在线」和「现在挂在哪」。
    /// Keep the current operation usable even when the user chose not to save its password.
    func unlockIfNeeded(_ info: DiskUtility.VolumeInfo) async throws {
        if info.isLocked, let encryption {
            try await disk.unlockVolume(info.volumeUUID ?? info.deviceIdentifier, passphrase: encryption.passphrase)
        } else {
            try await disk.unlockIfNeeded(info)
        }
    }

    func knownMountPoint(for record: ContainerMountRecord, operationID: String) async throws -> KnownMountPoint {
        if let autoMounted = autoMountedPath(for: record) {
            AppLogger.shared.logContext(
                "卷已由系统挂在自动挂载点，直接切换",
                details: [
                    ("operation_id", operationID),
                    ("volume", record.volumeName),
                    ("current_mount_point", autoMounted.path),
                    ("mount_point", record.mountPointPath)
                ],
                level: "TRACE"
            )
            return .mounted(at: autoMounted)
        }
        guard let info = try? await disk.volumeInfo(for: record.volumeUUID) else {
            AppLogger.shared.logContext(
                "挂载失败：外置卷不在线",
                details: [("operation_id", operationID), ("volume", record.volumeName), ("uuid", record.volumeUUID), ("mount_point", record.mountPointPath)],
                level: "WARN"
            )
            throw MigrationError.volumeUnavailable(record.volumeName)
        }
        try await unlockIfNeeded(info)
        guard let current = info.mountPoint, !current.isEmpty else { return .unmounted }
        return .mounted(at: URL(fileURLWithPath: current))
    }

    /// `/Volumes/<卷名>` 上挂的是不是这个记录的卷。是就返回那个路径，否则 nil。
    private func autoMountedPath(for record: ContainerMountRecord) -> URL? {
        let candidate = URL(fileURLWithPath: Self.autoMountRoot).appendingPathComponent(record.volumeName)
        guard isMountPoint(candidate) else { return nil }
        // 只看"挂上了"还不够：得确认挂的就是我们的卷（卷名可能被系统改名，也可能撞上别的盘）。
        guard volumeUUIDMarker(candidate) == record.volumeUUID else { return nil }
        guard mountedVolumeUUID(candidate)?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame else { return nil }
        return candidate
    }

    /// 卸载记录对应的卷，并把空挂载点重新锁住。
    func unmount(record: ContainerMountRecord, force: Bool = false) async throws {
        let mountPoint = record.mountPointURL
        guard try store.recordsStrict().contains(record) else { throw DataOperationSafety.Failure.conflict(mountPoint.path) }
        try store.setManuallyUnmounted(true, record: record)
        guard isMountPoint(mountPoint) else {
            if fileManager.fileExists(atPath: mountPoint.path) {
                let lease = try makeMountPointLease(mountPoint)
                try lease.verifyBeforeMount()
            }
            return
        }
        let operationID = AppLogger.shared.makeOperationID(prefix: "container-unmount")
        try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
        try await safety.requireNoKnownWriters(at: mountPoint, bundleIdentifier: record.bundleIdentifier)
        do {
            try await unmountVolume(mountPoint: mountPoint, force: force)
        } catch {
            AppLogger.shared.logError(
                "卸载容器卷失败",
                error: error,
                errorCode: "CONTAINER-UNMOUNT-FAILED",
                context: [("operation_id", operationID), ("volume", record.volumeName)],
                relatedURLs: [("mount_point", mountPoint)]
            )
            throw MigrationError.unmountFailed(mountPoint, error.localizedDescription)
        }
        let lease = try makeMountPointLease(mountPoint)
        try lease.verifyBeforeMount()
        invalidateSizeCache(for: mountPoint)
        AppLogger.shared.logContext(
            "容器卷已卸载",
            details: [("operation_id", operationID), ("volume", record.volumeName), ("mount_point", mountPoint.path)]
        )
    }

    /// 重挂载所有在线但尚未挂载的记录。启动、插盘和后台代理都走这里。
    func remountAvailableRecords() async -> [RemountOutcome] {
        var outcomes: [RemountOutcome] = []
        let records: [ContainerMountRecord]
        let ejection: DiskEjectionPauseStore.Snapshot
        do {
            ejection = try await DiskEjectionPauseStore(store: store).refreshed(using: disk)
            records = try store.recordsStrict()
        }
        catch {
            AppLogger.shared.logError("无法读取挂载记录，自动挂载已停止", error: error)
            return []
        }
        for record in records {
            do {
                try await upgradeLegacyOfflineGuard(for: record)
                if try store.isManuallyUnmounted(record) {
                    outcomes.append(RemountOutcome(record: record, state: .requiresIntervention(ManualMountPauseError.paused.localizedDescription)))
                    continue
                }
            } catch {
                outcomes.append(RemountOutcome(record: record, state: .failed(error.localizedDescription)))
                continue
            }
            if ejection.blocks(volumeUUIDs: [record.volumeUUID], paths: [record.mountPointPath, record.externalRootPath]) {
                outcomes.append(RemountOutcome(record: record, state: .requiresIntervention(DiskEjectionError.paused.localizedDescription)))
                continue
            }
            do {
                if let reason = try store.remountIntervention(forVolumeUUID: record.volumeUUID) {
                    // A mounted volume may have failed the post-mount lease check.
                    // Never clear that evidence without inspecting its hidden directory.
                    if isMountPoint(record.mountPointURL) {
                        outcomes.append(RemountOutcome(record: record, state: .requiresIntervention(reason)))
                        continue
                    }
                    // The volume is no longer hiding a directory. A fresh
                    // anchored lease can safely recheck even an old failure.
                    try store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: nil)
                }
                let alreadyMounted = isMountPoint(record.mountPointURL)
                // 在线检查放在 mount(record:) 里，和「当前挂载点」共用同一次 diskutil 查询。
                try await mount(record: record)
                outcomes.append(RemountOutcome(record: record, state: alreadyMounted ? .alreadyMounted : .mounted))
            } catch let error as MigrationError {
                if case .volumeUnavailable = error {
                    outcomes.append(RemountOutcome(record: record, state: .unavailable))
                } else if case .mountPointConflict = error {
                    try? store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: error.localizedDescription)
                    outcomes.append(RemountOutcome(record: record, state: .requiresIntervention(error.localizedDescription)))
                } else {
                    outcomes.append(RemountOutcome(record: record, state: .failed(error.localizedDescription)))
                }
            } catch let error as APFSVolumeEncryption.Failure {
                outcomes.append(RemountOutcome(record: record, state: .requiresIntervention(error.localizedDescription)))
            } catch {
                outcomes.append(RemountOutcome(record: record, state: .failed(error.localizedDescription)))
            }
        }
        // A successful remount changes the visible filesystem without changing
        // the saved record. Notify observers only when a mount actually occurred.
        if outcomes.contains(where: { $0.state == .mounted }) {
            NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: store)
        }
        return outcomes
    }

    private func ownedMigrationTransferIDs(for record: ContainerMountRecord) throws -> Set<UUID> {
        let history = try store.transfers()
        let related = history.filter {
            $0.mode == .mount && $0.direction == .migrate
                && $0.createdVolumeUUID?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame
                && $0.originalPath == record.mountPointPath && [.awaitingUserVerification, .cleanupRequested].contains($0.phase)
        }
        return try related.reduce(into: Set<UUID>()) { result, transfer in
            result.formUnion(try transferAncestors(of: transfer, in: history))
        }
    }

    private func upgradeLegacyOfflineGuard(for record: ContainerMountRecord) async throws {
        let url = record.mountPointURL
        guard !isMountPoint(url) else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o7777 == 0 else { return }
        // A started restore owns its placeholder and upgrades it through its
        // existing recovery path, rather than through background maintenance.
        guard try !store.transfers().contains(where: {
            $0.mode == .mount && $0.direction == .restore && $0.originalPath == url.path && !$0.isUnstartedMountRestore
        }) else { return }
        try safety.requireExistingMigrationPolicy(at: url, bundleIdentifier: record.bundleIdentifier)
        let ownedIDs = try ownedMigrationTransferIDs(for: record)
        let restores = try await remountCompatibleRestoreIDs(record: record)
        try safety.requireNoOverlap(at: url, ownedMount: record, ownedTransferIDs: ownedIDs.union(restores))
        try safety.requireNoManagedFileSystemAncestor(at: url)
        try safety.requireMountPointParentAccess(at: url)
        try store.recheckWriterAdmission()
        let lease = try makeMountPointLease(url)
        try lease.verifyBeforeMount()
    }

    // MARK: - 还原

    /// Copy back to local storage and retain the source volume for explicit cleanup.
    @discardableResult
    func restore(
        record: ContainerMountRecord,
        estimatedTotalBytes: Int64,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws -> CleanupWarning? {
        try await completeInterruptedMigrationBeforeRestore(record: record, progressHandler: progressHandler)
        _ = try await restoreRetainingOriginal(record: record, estimatedTotalBytes: estimatedTotalBytes, progressHandler: progressHandler)
        return nil
    }

    private func restoreRetainingOriginal(record: ContainerMountRecord, estimatedTotalBytes: Int64,
                                          progressHandler: FileCopier.ProgressHandler?, reusingOperationID: UUID? = nil) async throws -> UUID {
        DataTransferSession.progress?.setDirectory(record.mountPointURL)
        DataTransferSession.progress?.observeDirectoryWorkflow()
        await progressHandler?(.working(.preparing))
        let mountPoint = record.mountPointURL
        // Exact history ownership is required. A stale UI value cannot authorize recovery.
        guard try store.recordsStrict().contains(record) else { throw MigrationError.alreadyManaged(mountPoint) }
        try store.reconcileLegacyCleanups(for: record)
        let transfers = try store.transfers()
        let prior = transfers.first {
            $0.mode == .mount && $0.direction == .migrate && $0.originalPath == record.mountPointPath
                && $0.createdVolumeUUID?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame
                && [.awaitingUserVerification, .cleanupRequested].contains($0.phase)
        }
        let resumable = transfers.filter {
            $0.isUnstartedMountRestore && $0.originalPath == record.mountPointPath
                && $0.sourceIdentity.volumeUUID?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame
                && $0.priorOperationID == prior?.operationID
        }
        guard resumable.count <= 1 else { throw DataOperationSafety.Failure.conflict(mountPoint.path) }
        if let pending = resumable.first { try await validateUnstartedRestorePaths(pending, record: record) }
        var ownedIDs = try prior.map { try transferAncestors(of: $0, in: transfers) } ?? []
        if let pending = resumable.first { ownedIDs.insert(pending.operationID) }
        try safety.requireNoOverlap(at: mountPoint, ownedMount: record, ownedTransferIDs: ownedIDs)
        try safety.requireLocalRestoreParent(at: mountPoint, isMountPoint: isMountPoint)
        if estimatedTotalBytes > 0, let available = availableCapacity(mountPoint.deletingLastPathComponent()) {
            let required = Self.requiredFreeBytes(forDataBytes: estimatedTotalBytes)
            guard available >= required else { throw MigrationError.insufficientSpace(required: required, available: available) }
        }
        // Online inspection is read-only and must finish before creating an intent.
        let originallyOnline = isMountPoint(mountPoint)
        var originalFlags: UInt32?
        if originallyOnline {
            try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
            try await safety.requireNoKnownWriters(at: mountPoint, bundleIdentifier: record.bundleIdentifier)
            guard let flags = mountFlags(mountPoint) else { throw DataOperationSafety.Failure.inspection(mountPoint.path) }
            originalFlags = flags
        }
        let id = resumable.first?.operationID ?? reusingOperationID ?? UUID()
        let staging = mountPoint.deletingLastPathComponent().appendingPathComponent(".appports-restore-staging-\(id.uuidString)")
        let recovery = stagingMountRootURL.appendingPathComponent("recovery-\(id.uuidString)")
        var transfer = DataTransferRecord(operationID: id, mode: .mount, direction: .restore,
            sourceID: prior?.sourceID, appName: record.appName, bundleIdentifier: record.bundleIdentifier,
            dataDirType: record.dataDirType, originalPath: mountPoint.path, activePath: mountPoint.path,
            destinationPath: mountPoint.path, backupPath: recovery.path, stagingPath: staging.path,
            sourceIdentity: DataPathIdentity(volumeUUID: record.volumeUUID), priorOperationID: prior?.operationID)
        transfer.recoveryMountRecord = record
        transfer.preparationPath = staging.path
        transfer.preparationParentIdentity = try DataPathIdentity.capture(staging.deletingLastPathComponent())
        transfer.originalSourceMountFlags = originalFlags
        if let pending = resumable.first {
            let useProjectedOwnership = record.ownershipPolicy == nil && prior == nil
                && pending.sourceBaseline == nil && pending.preparationRemovalBaseline == nil
                && pending.preparationRemovalParentIdentity == nil
                && originalFlags.map({ $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 }) == true
            if useProjectedOwnership, try verifiedResumeEntryExists(staging) {
                throw DataOperationSafety.Failure.conflict(staging.path)
            }
            transfer = try store.resumeUnstartedMountRestore(pending, record: record,
                                                            useProjectedOwnership: useProjectedOwnership)
            if transfer.recoveryMountRecord == nil {
                transfer.recoveryMountRecord = record
                try store.updateTransfer(transfer)
            }
        } else {
            try store.beginTransfer(transfer)
        }
        // Old volumes were used with projected ownership. Capture that same
        // view directly instead of exposing hidden owners via a privileged
        // remount. Existing strict records/intents keep their original contract.
        let requiresOwnership: Bool
        if let encoded = transfer.sourceBaseline {
            let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
            requiresOwnership = baseline.ownershipCompatibility?.sourceIgnoresOwnership != true
        } else {
            requiresOwnership = record.ownershipPolicy == .owners || transfer.legacyRootOwnership != nil
        }
        let operationID = id.uuidString
        var ownershipUpdateFlags: UInt32?
        do {
            let source: URL
            if isMountPoint(mountPoint) {
                try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
                if requiresOwnership, let flags = originalFlags, flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 {
                    // Do not overwrite mount options changed since the initial preflight.
                    try await safety.requireNoKnownWriters(at: mountPoint, bundleIdentifier: record.bundleIdentifier)
                    try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
                    guard mountFlags(mountPoint) == flags else { throw DataOperationSafety.Failure.conflict(mountPoint.path) }
                    ownershipUpdateFlags = flags
                    try await setOwnershipForRestore(mountPoint: mountPoint, originalFlags: flags, enabled: true)
                    try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
                }
                source = mountPoint
            } else {
                // Recovery never reintroduces a forbidden mount at Data/tmp or a container root.
                let hint = try await knownMountPoint(for: record, operationID: operationID)
                if case .mounted(let current) = hint {
                    try await safety.requireNoKnownWriters(at: current, bundleIdentifier: record.bundleIdentifier)
                }
                try fileManager.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
                if transfer.recoveryMountPointIdentity == nil {
                    transfer.stagingParentIdentity = try DataPathIdentity.capture(recovery.deletingLastPathComponent())
                    try store.updateTransfer(transfer)
                    // Creation must be exclusive; a pre-existing directory is not our intent.
                    try fileManager.createDirectory(at: recovery, withIntermediateDirectories: false)
                    try DurableFileIO.syncDirectory(at: recovery.deletingLastPathComponent())
                    transfer.recoveryMountPointIdentity = try DataPathIdentity.capture(recovery)
                    try store.updateTransfer(transfer)
                }
                if isMountPoint(recovery) {
                    // A prior attempt may have mounted successfully before its postcheck failed.
                    // Inspect the retained volume directly; a new lease would inspect its payload.
                    try await requireExpectedVolume(record.volumeUUID, at: recovery)
                    try await safety.requireNoKnownWriters(at: recovery, bundleIdentifier: record.bundleIdentifier)
                } else {
                    try await mountVolume(record.volumeUUID, at: recovery, operationID: operationID, knownMountPoint: hint,
                                          requireOwnership: requiresOwnership)
                }
                source = recovery
            }
            if requiresOwnership { try requireOwners(at: source) }
            // A legacy volume can already use owners after a normal remount.
            // Without a prior verified manifest, the old creator's root-owned
            // volume root needs the same destination projection online or offline.
            // Descendants and the retained source keep their actual ownership.
            if record.ownershipPolicy == nil, prior == nil, transfer.legacyRootOwnership == nil,
               mountFlags(source).map({ $0 & UInt32(MNT_IGNORE_OWNERSHIP) == 0 }) == true {
                var info = stat()
                guard lstat(source.path, &info) == 0 else { throw DataOperationSafety.Failure.inspection(source.path) }
                if info.st_uid == 0 {
                    transfer.legacyRootOwnership = .init(uid: geteuid(), gid: getegid())
                    try store.updateTransfer(transfer)
                }
            }
            transfer.sourceIdentity = try DataPathIdentity.capture(source, volumeUUID: record.volumeUUID)
            try store.updateTransfer(transfer)
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: record.bundleIdentifier)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copyPreparation(transfer, source: source, destination: staging,
                finalDestination: mountPoint, logicalSourceRoot: mountPoint, progressHandler: progressHandler)
            transfer = try store.transfer(operationID: id) ?? transfer
            await progressHandler?(FileCopier.Progress(copiedBytes: baseline.logicalBytes,
                totalBytes: baseline.logicalBytes, currentFile: "正在切换本地入口...".localized, showsByteProgress: false, stage: .switching))
            try safety.requireLocalRestoreParent(at: mountPoint, isMountPoint: isMountPoint)
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: record.bundleIdentifier)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try TreeCopySession.verifyCopy(at: staging, against: baseline, purpose: .beforeSwitch)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.destinationIdentity = try DataPathIdentity.capture(staging)
            transfer.backupIdentity = transfer.sourceIdentity
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            try safety.requireLocalRestoreParent(at: mountPoint, isMountPoint: isMountPoint)
            try safety.requireMountPointParentAccess(at: mountPoint)
            DataTransferSession.progress?.observeEntrySwitch()
            try store.beginRestore(transfer: transfer, removingMount: record)
            transfer.phase = .switching
            synchronizeAgent(store)
            try await requireExpectedVolume(record.volumeUUID, at: source)
            try safety.requireMountPointParentAccess(at: mountPoint)
            try await unmountVolume(mountPoint: source)
            try safety.requireLocalRestoreParent(at: mountPoint, isMountPoint: isMountPoint)
            if source != mountPoint { removeEmptyDirectoryQuietly(at: source) }
            if fileManager.fileExists(atPath: mountPoint.path) {
                try removeEmptyMountPoint(at: mountPoint)
            } else if isSymbolicLink(at: mountPoint) {
                throw DataOperationSafety.Failure.conflict(mountPoint.path)
            }
            try moveTree(staging, to: mountPoint)
            try DurableFileIO.syncDirectory(at: mountPoint.deletingLastPathComponent())
            try store.finalizeTransfer(operationID: id, baseline: transfer.baseline!)
            invalidateSizeCache(for: mountPoint)
            // Completion cleans this verified source after the restore commits.
            return id
        } catch {
            var reportedError: Error = error
            transfer = (try? store.transfer(operationID: transfer.operationID)) ?? transfer
            if transfer.isDataSwitchComplete { throw error }
            transfer.phase = .needsRecovery
            // Revert only an update attempted by this invocation, using its fresh
            // flags. Persisted historical flags must not override a later user edit.
            if let flags = ownershipUpdateFlags, isMountPoint(mountPoint) {
                do {
                    try await restoreOriginalMountOptions(mountPoint: mountPoint, volumeUUID: record.volumeUUID, originalFlags: flags)
                }
                catch {
                    AppLogger.shared.logError("还原失败后无法恢复原挂载选项", error: error, relatedURLs: [("mount_point", mountPoint)])
                    reportedError = MigrationError.ownershipRollbackFailed(mountPoint, operation: reportedError, rollback: error)
                }
            }
            transfer.recoverableReason = reportedError.localizedDescription
            do { try store.updateTransfer(transfer) }
            catch { AppLogger.shared.logError("无法更新还原恢复记录，原事务仍保留", error: error) }
            throw reportedError
        }
    }

    /// A cleanup can update its own phase and removal checkpoint without
    /// changing this location. A different successor must be inspected and
    /// synchronized by a new cleanup attempt before any old copy is removed.
    private struct ActiveDataLocation: Equatable {
        let operationID: UUID
        let mode: DataTransferRecord.Mode
        let direction: DataTransferRecord.Direction
        let originalPath: String
        let activePath: String
        let identity: DataPathIdentity?
        let volumeUUID: String?

        init(_ transfer: DataTransferRecord) {
            operationID = transfer.operationID
            mode = transfer.mode
            direction = transfer.direction
            originalPath = transfer.originalPath
            activePath = transfer.activePath
            identity = transfer.destinationIdentity
            volumeUUID = transfer.createdVolumeUUID
        }
    }

    /// Verify current data independently of the age of its retained copy.
    /// Run this again after asynchronous disk/process inspections.
    @discardableResult
    func requireActiveData(for transfer: DataTransferRecord) async throws -> URL {
        try await requireActiveData(for: transfer, matching: nil)
    }

    @discardableResult
    private func requireActiveData(for transfer: DataTransferRecord,
                                   matching expectedLocation: ActiveDataLocation?) async throws -> URL {
        let current = try store.completedLocation(after: transfer.operationID)
        let location = ActiveDataLocation(current)
        guard expectedLocation == nil || expectedLocation == location else {
            throw DataOperationSafety.Failure.conflict(current.activePath)
        }
        let active = URL(fileURLWithPath: current.activePath)
        if current.direction == .migrate, current.mode == .mount,
           let uuid = current.createdVolumeUUID, isMountPoint(active) {
            try await requireExpectedVolume(uuid, at: active)
            guard let expected = current.destinationIdentity,
                  try DataPathIdentity.capture(active, volumeUUID: uuid).matchesFilesystemObject(expected) else {
                throw DataOperationSafety.Failure.conflict(active.path)
            }
        } else if current.direction == .migrate, current.mode == .symlink {
            let local = URL(fileURLWithPath: current.originalPath)
            guard let expected = current.destinationIdentity,
                  let link = try store.managedLink(forOriginalPath: current.originalPath),
                  link.operationID == current.operationID, link.destinationPath == active.path,
                  link.destinationIdentity.matchesFilesystemObject(expected),
                  !isSymbolicLink(at: active),
                  try DataPathIdentity.capture(active).matchesFilesystemObject(expected) else {
                throw DataOperationSafety.Failure.conflict(active.path)
            }
            if isSymbolicLink(at: local) {
                guard DataPathTopology.relationship(local.path, active.path) == .same else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
            } else if try verifiedResumeEntryExists(local) { throw DataOperationSafety.Failure.conflict(local.path) }
        } else {
            guard current.direction == .restore, current.isDataSwitchComplete,
                  let expected = current.destinationIdentity, !isMountPoint(active), !isSymbolicLink(at: active),
                  try DataPathIdentity.capture(active).matchesFilesystemObject(expected) else {
                throw DataOperationSafety.Failure.conflict(active.path)
            }
        }
        guard ActiveDataLocation(try store.completedLocation(after: transfer.operationID)) == location else {
            throw DataOperationSafety.Failure.conflict(active.path)
        }
        return active
    }

    /// Retained cleanup is resumable without reverting a completed data switch.
    func cleanupRetainedTransfer(operationID: UUID) async throws {
        guard let transfer = try store.transfer(operationID: operationID),
              transfer.needsAutomaticCompletion, !CleanupRetryContext.shouldDefer(transfer) else { return }
        let launchDirectory = store.fileURLForDeletionAuthorization.deletingLastPathComponent().appendingPathComponent("launch-locks", isDirectory: true)
        if !ApplicationLaunchProtection.contains(transfer.bundleIdentifier, directory: launchDirectory) {
            return try await ApplicationLaunchProtection.run(identifier: transfer.bundleIdentifier, directory: launchDirectory) {
                try await self.cleanupRetainedTransfer(operationID: operationID)
            }
        }
        do {
            try await performRetainedTransferCleanup(operationID: operationID)
            CleanupRetryContext.record(.transfer(operationID), failed: false, store: store)
        } catch {
            if !(error is CancellationError) {
                CleanupRetryContext.record(.transfer(operationID), failed: true, store: store)
            }
            throw error
        }
    }

    private func performRetainedTransferCleanup(operationID: UUID) async throws {
        if DataTransferSession.current == nil {
            return try await DataTransferSession.run { try await self.performRetainedTransferCleanup(operationID: operationID) }
        }
        guard runningCleanups.insert(operationID).inserted else { throw DataOperationSafety.Failure.occupied(operationID.uuidString) }
        defer { runningCleanups.remove(operationID) }
        guard var transfer = try store.transfer(operationID: operationID) else { return }
        DataTransferSession.progress?.setDirectory(URL(fileURLWithPath: transfer.originalPath))
        guard transfer.needsAutomaticCompletion else { return }
        if transfer.retainedCopyRemovedAt != nil {
            try store.finishTransfer(operationID: operationID, deletionConfirmed: true)
            synchronizeAgent(store)
            return
        }
        guard transfer.mode == .mount, transfer.isDataSwitchComplete,
              let encoded = transfer.baseline, let backupPath = transfer.backupPath,
              let expectedBackup = transfer.backupIdentity else {
            throw DataOperationSafety.Failure.inspection(operationID.uuidString)
        }
        DataTransferSession.progress?.observeResumedCopy(cleanup: true)
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        let location = ActiveDataLocation(try store.completedLocation(after: operationID))
        let active = try await requireActiveData(for: transfer, matching: location)
        let backup = URL(fileURLWithPath: backupPath)
        let parent = backup.deletingLastPathComponent().resolvingSymlinksInPath()
        let deletionPreviouslyStarted = transfer.cleanupParentIdentity != nil
        try safety.requireNoOverlap(at: backup, ownedTransferIDs: [operationID], ownedRetainedPath: backup.path)
        if let expectedParent = transfer.cleanupParentIdentity {
            guard try DataPathIdentity.capture(parent).matchesFilesystemObject(expectedParent) else {
                throw DataOperationSafety.Failure.conflict(parent.path)
            }
        }
        try await safety.requireNoKnownWriters(at: active, bundleIdentifier: transfer.bundleIdentifier)
        try await requireActiveData(for: transfer, matching: location)
        try DurableFileIO.syncTree(at: active, excludingRootEntries: Self.volumeSystemArtifacts)
        try DurableFileIO.syncDirectory(at: active.deletingLastPathComponent())
        do {
            if transfer.direction == .migrate {
                let retained = try TreeCopySession.retainedRemovalURL(at: backup, removalID: operationID)
                if let retained {
                    guard !isMountPoint(retained), !isSymbolicLink(at: retained),
                          try DataPathIdentity.capture(retained).matchesFilesystemObject(expectedBackup) else {
                        throw DataOperationSafety.Failure.conflict(retained.path)
                    }
                    try await safety.requireNoKnownWriters(at: retained, bundleIdentifier: transfer.bundleIdentifier)
                    try await requireActiveData(for: transfer, matching: location)
                    let activeIdentity = try DataPathIdentity.capture(active)
                    guard try store.transfer(operationID: operationID) == transfer else {
                        throw DataOperationSafety.Failure.conflict(backup.path)
                    }
                    let parentIdentity = try DataPathIdentity.capture(parent)
                    guard try store.transfer(operationID: operationID) == transfer,
                          try DataPathIdentity.capture(retained).matchesFilesystemObject(expectedBackup) else {
                        throw DataOperationSafety.Failure.conflict(backup.path)
                    }
                    try store.recheckWriterAdmission()
                    try TreeCopySession.removeVerifiedCopy(at: backup, against: baseline, allowPartialRemoval: deletionPreviouslyStarted,
                        expectedVolumeUUID: expectedBackup.volumeUUID, removalID: operationID, requireSourceIdentity: true, willRemove: {
                        guard try self.store.transfer(operationID: operationID) == transfer,
                              try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity),
                              try DataPathIdentity.capture(retained).matchesFilesystemObject(expectedBackup) else {
                            throw DataOperationSafety.Failure.conflict(backup.path)
                        }
                        // A missing node cannot become an authorized prior
                        // deletion: the complete scan precedes this checkpoint.
                        try self.store.requestCleanup(operationID: operationID)
                        transfer.phase = .cleanupRequested
                        transfer.recoverableReason = nil
                        try self.store.beginCleanupDeletion(operationID: operationID, parentIdentity: parentIdentity)
                        transfer.cleanupParentIdentity = transfer.cleanupParentIdentity ?? parentIdentity
                        // Keep the post-journal activation check synchronous:
                        // the checkpoint writer itself may reveal a replaced
                        // entry, and no disk query may split scan from deletion.
                        guard ActiveDataLocation(try self.store.completedLocation(after: operationID)) == location,
                              try DataPathIdentity.capture(active) == activeIdentity,
                              !self.isSymbolicLink(at: active),
                              self.isMountPoint(active) == (location.mode == .mount && location.direction == .migrate) else {
                            throw DataOperationSafety.Failure.conflict(active.path)
                        }
                    })
                } else {
                    guard transfer.cleanupParentIdentity != nil else { throw DataOperationSafety.Failure.inspection(backup.path) }
                    try await requireActiveData(for: transfer, matching: location)
                    // The same online parent and absent original/quarantine prove
                    // that only the ledger write remains after a prior deletion.
                    guard try DataPathIdentity.capture(parent).matchesFilesystemObject(transfer.cleanupParentIdentity!) else {
                        throw DataOperationSafety.Failure.conflict(parent.path)
                    }
                    try store.requestCleanup(operationID: operationID)
                    transfer.phase = .cleanupRequested
                    transfer.recoverableReason = nil
                }
            } else {
                guard let uuid = transfer.sourceIdentity.volumeUUID else { throw DataOperationSafety.Failure.inspection(backup.path) }
                // A different operation may still own this UUID even when it
                // has no active mount record. A matching volume name is not authority.
                let lineage = Set(try retainedLineage(endingAt: location.operationID).map(\.operationID))
                guard try !store.transfers().contains(where: { other in
                    !lineage.contains(other.operationID) && (other.createdVolumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame
                        || other.rollbackCompletedAt == nil && other.sourceIdentity.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame)
                }) else { throw DataOperationSafety.Failure.conflict(backup.path) }
                if let container = transfer.cleanupVolumeContainerUUID,
                   try await !disk.apfsVolumeIsPresent(uuid, inContainer: container) {
                    try await requireActiveData(for: transfer, matching: location)
                    try store.requestCleanup(operationID: operationID)
                    transfer.phase = .cleanupRequested
                    transfer.recoverableReason = nil
                } else {
                    let info = try await disk.volumeInfo(for: uuid)
                    guard info.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame else {
                        throw DataOperationSafety.Failure.conflict(backup.path)
                    }
                    if let current = info.mountPoint, !current.isEmpty {
                        if !DiskUtility.pathsMatch(current, backup.path) {
                            let automatic = URL(fileURLWithPath: current)
                            guard let record = transfer.recoveryMountRecord,
                                  automatic.deletingLastPathComponent().path == Self.autoMountRoot,
                                  automatic.lastPathComponent == record.volumeName,
                                  try store.recordsStrict().allSatisfy({ $0.volumeUUID.caseInsensitiveCompare(uuid) != .orderedSame }) else {
                                throw DataOperationSafety.Failure.conflict(current)
                            }
                            try requireVolumeMarker(at: automatic, record: record)
                            try await requireExpectedVolume(uuid, at: automatic)
                            try await safety.requireNoKnownWriters(at: automatic, bundleIdentifier: transfer.bundleIdentifier)
                            guard try store.transfer(operationID: operationID) == transfer else {
                                throw DataOperationSafety.Failure.conflict(current)
                            }
                            try await unmountVolume(mountPoint: automatic)
                        } else { try await requireExpectedVolume(uuid, at: backup) }
                    }
                    if !isMountPoint(backup) {
                        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                        try await mountVolume(uuid, at: backup, operationID: operationID.uuidString, allowRelocation: false,
                                              requireOwnership: baseline.ownershipCompatibility?.sourceIgnoresOwnership != true)
                    }
                    if baseline.ownershipCompatibility?.sourceIgnoresOwnership != true { try requireOwners(at: backup) }
                    guard try DataPathIdentity.capture(backup, volumeUUID: uuid).matchesFilesystemObject(expectedBackup) else {
                        throw DataOperationSafety.Failure.conflict(backup.path)
                    }
                    try await safety.requireNoKnownWriters(at: backup, bundleIdentifier: transfer.bundleIdentifier)
                    let container = try await disk.apfsContainerUUID(containingVolume: uuid)
                    try await requireExpectedVolume(uuid, at: backup)
                    try await requireActiveData(for: transfer, matching: location)
                    guard try store.transfer(operationID: operationID) == transfer else {
                        throw DataOperationSafety.Failure.conflict(backup.path)
                    }
                    // Whole-volume removal has no partially deleted tree to
                    // authorize. Persist intent first, then verify once after
                    // journal callbacks and the last active-location query.
                    try store.requestCleanup(operationID: operationID)
                    transfer.phase = .cleanupRequested
                    transfer.recoverableReason = nil
                    let parentIdentity = try DataPathIdentity.capture(parent)
                    try store.beginCleanupDeletion(operationID: operationID, parentIdentity: parentIdentity, volumeContainerUUID: container)
                    transfer.cleanupParentIdentity = transfer.cleanupParentIdentity ?? parentIdentity
                    transfer.cleanupVolumeContainerUUID = container
                    try await requireActiveData(for: transfer, matching: location)
                    try TreeCopySession.verifyUnchanged(at: backup, against: baseline, expectedVolumeUUID: uuid, purpose: .retainedCopy)
                    try await unmountVolume(mountPoint: backup)
                    removeEmptyDirectoryQuietly(at: backup)
                    try await requireActiveData(for: transfer, matching: location)
                    try await deleteAPFSVolume(uuid)
                    guard try await !disk.apfsVolumeIsPresent(uuid, inContainer: container) else {
                        throw DataOperationSafety.Failure.inspection(uuid)
                    }
                }
            }
            // A confirmed absent volume still owes this same barrier after
            // interruption. Neither a new parent nor a failed sync can retire
            // the original manifest and its deletion checkpoint.
            guard let expectedParent = transfer.cleanupParentIdentity,
                  try store.transfer(operationID: operationID) == transfer,
                  try DataPathIdentity.capture(parent).matchesFilesystemObject(expectedParent) else {
                throw DataOperationSafety.Failure.conflict(parent.path)
            }
            try synchronizeCleanupParent(parent)
            guard try DataPathIdentity.capture(parent).matchesFilesystemObject(expectedParent) else {
                throw DataOperationSafety.Failure.conflict(parent.path)
            }
            try store.finishTransfer(operationID: operationID, deletionConfirmed: true)
            synchronizeAgent(store)
        } catch {
            // Read/mount/delete failures are retryable housekeeping. The durable
            // checkpoint and baseline prevent treating foreign data as leftovers.
            if transfer.phase == .cleanupRequested {
                transfer.recoverableReason = error.localizedDescription
                do { try store.updateTransfer(transfer) }
                catch { AppLogger.shared.logError("无法更新副本清理恢复记录，原事务仍保留", error: error) }
            }
            throw error
        }
    }

    /// Resume internal cleanup without repeating the completed data transfer.
    func retryCleanup(_ warning: CleanupWarning) async -> CleanupWarning? {
        if let operationID = warning.transferOperationID {
            return await completeSuccessfulTransfer(operationID: operationID,
                direction: warning.cleanup.kind == .restoredVolume ? .restore : .migrate,
                record: warning.cleanup.mountRecord, progressHandler: nil)
        }
        return await performCleanup(warning.cleanup, recordUpdateOnly: warning.needsRecordUpdateOnly)
    }

    /// 用户明确确认后仅移除清理记录，保留所有副本；用于无法分辨卷已删除还是已断开的情况。
    /// 未完成的本地切换仍需保留恢复信息，不能通过此入口遗忘。
    func discardCleanupRecord(_ cleanup: ContainerCleanupRecord) throws {
        guard let current = try store.pendingCleanups().first(where: { $0.id == cleanup.id }) else { return }
        guard current == cleanup else { throw DataOperationSafety.Failure.conflict(cleanup.localPath) }
        try store.finishCleanup(current) {
            if current.kind == .restoredVolume {
                let localURL = URL(fileURLWithPath: current.localPath)
                guard existingRealDirectory(at: localURL) else {
                    throw MigrationError.cleanupRecordLocalUnavailable(localURL)
                }
                guard !isMountPoint(localURL) else {
                    throw MigrationError.cleanupRecordStillMounted(localURL)
                }
                if let path = current.restoreStagingPath {
                    let staging = URL(fileURLWithPath: path)
                    if try verifiedResumeEntryExists(staging) { throw MigrationError.cleanupRecordStagingExists(staging) }
                }
            }
        }
        AppLogger.shared.logContext(
            "用户仅移除清理记录，保留副本",
            details: [("cleanup_id", current.id.uuidString), ("local_path", current.localPath),
                      ("volume_uuid", current.mountRecord.volumeUUID)],
            level: "WARN"
        )
    }

    private func performCleanup(_ cleanup: ContainerCleanupRecord, recordUpdateOnly: Bool = false) async -> CleanupWarning? {
        do {
            guard try store.pendingCleanups().contains(where: { $0.id == cleanup.id }) else { return nil }
            // Old releases recorded a completed restore without a content or
            // identity baseline. Retain that volume internally, but do not let
            // the obsolete task reserve an already restored local directory.
            guard cleanup.kind == .restoredVolume else {
                throw DataOperationSafety.Failure.inspection(cleanup.localPath)
            }
            let local = URL(fileURLWithPath: cleanup.localPath)
            try store.finishCleanup(cleanup, preservingDetachedVolume: true) {
                guard existingRealDirectory(at: local), !isSymbolicLink(at: local), !isMountPoint(local) else {
                    throw MigrationError.cleanupRecordLocalUnavailable(local)
                }
                if let path = cleanup.restoreStagingPath, try verifiedResumeEntryExists(URL(fileURLWithPath: path)) {
                    throw MigrationError.cleanupRecordStagingExists(URL(fileURLWithPath: path))
                }
            }
            return nil
        } catch {
            return CleanupWarning(cleanup: cleanup, details: error.localizedDescription)
        }
    }

    // MARK: - 私有辅助：挂载点

    /// 把卷挂到容器内的挂载点，并确认它**真的**挂在这个路径上。
    ///
    /// 挂完必须校验：`diskutil mount -mountPoint` 在卷已经挂载时会忽略挂载点参数、
    /// 照样打印 "mounted" 并返回 0 —— 开机/插盘时 macOS 的自动挂载常常抢在前面，
    /// 于是命令成功、挂载点却是空的（2026-09-21 与 09-23 各一次，微信随后读到空目录）。
    /// 实测：先把卷挂到 `/Volumes` 再对它执行 `mount -mountPoint <别处>`，退出码 0 而卷仍在 `/Volumes`。
    ///
    /// 校验不过就重新查一次卷挂在哪、把它从别的挂载点卸下来再挂一遍，最多 `maximumMountAttempts` 轮。
    func mountVolume(
        _ volumeUUID: String,
        at mountPoint: URL,
        operationID: String,
        knownMountPoint: KnownMountPoint = .unknown,
        allowRelocation: Bool = true,
        requireOwnership: Bool = false,
        validateBeforeMutation: (() throws -> Void)? = nil
    ) async throws {
        guard try !DiskEjectionPauseStore(store: store).snapshot().blocks(volumeUUIDs: [volumeUUID], paths: [mountPoint.path]) else {
            throw DiskEjectionError.paused
        }
        if !DataTransferSession.isMeasuring(.switching) {
            return try await DataTransferSession.measure(.switching) {
                try await self.mountVolume(volumeUUID, at: mountPoint, operationID: operationID, knownMountPoint: knownMountPoint,
                    allowRelocation: allowRelocation, requireOwnership: requireOwnership, validateBeforeMutation: validateBeforeMutation)
            }
        }
        var hint = knownMountPoint
        // Recovery can supply an unmounted hint directly, bypassing knownMountPoint(for:).
        // Check encryption before any lease/directory mutation on those paths as well.
        if case .unmounted = hint {
            let inspection = try store.recordsForInspection()
            if let error = inspection.validationError { throw error }
            let records = inspection.mounts + inspection.transfers.compactMap(\.recoveryMountRecord)
            if records.contains(where: { $0.volumeUUID.caseInsensitiveCompare(volumeUUID) == .orderedSame && $0.isEncrypted == true }) {
                try await unlockIfNeeded(try await disk.volumeInfo(for: volumeUUID))
            }
        }
        for attempt in 1...Self.maximumMountAttempts {
            // Resolve read-only disk state before preparing the directory so
            // a journal change during that query prevents every mutation.
            if allowRelocation {
                if case .unknown = hint {
                    let info = try await disk.volumeInfo(for: volumeUUID)
                    try await unlockIfNeeded(info)
                    hint = Self.knownMountPoint(from: info)
                }
            } else {
                let info = try await disk.volumeInfo(for: volumeUUID)
                try await unlockIfNeeded(info)
                guard info.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame,
                      info.mountPoint?.isEmpty ?? true else {
                    throw DataOperationSafety.Failure.conflict(mountPoint.path)
                }
            }
            try validateBeforeMutation?()
            let lease: any MountPointLeasing
            do {
                try store.recheckWriterAdmission()
                lease = try makeMountPointLease(mountPoint)
                try lease.verifyBeforeMount()
            } catch MountPointLease.Failure.notEmpty {
                throw MigrationError.mountPointNotEmpty(mountPoint)
            }
            // Prepare and protect the destination before detaching a usable
            // source. Permission/identity failures must leave that source up.
            try validateBeforeMutation?()
            if allowRelocation {
                try await detachForeignMountPoint(
                    volumeUUID: volumeUUID,
                    target: mountPoint,
                    operationID: operationID,
                    knownMountPoint: hint
                )
            }
            try validateBeforeMutation?()
            try lease.verifyBeforeMount()
            try await performMount(volumeUUID, at: mountPoint, requireOwnership: requireOwnership)
            do { try lease.verifyUnderlyingDirectory() }
            catch { throw MigrationError.mountPointConflict(mountPoint, error.localizedDescription) }

            let landing = try await mountLanding(volumeUUID: volumeUUID, at: mountPoint)
            switch landing.landing {
            case .mountPointVisible:
                if attempt > 1 {
                    AppLogger.shared.logContext(
                        "重试后挂载点已就位",
                        details: [
                            ("operation_id", operationID),
                            ("attempt", "\(attempt)/\(Self.maximumMountAttempts)"),
                            ("mount_point", mountPoint.path)
                        ]
                    )
                }
                if requireOwnership { try requireOwners(at: mountPoint) }
                // 迁移前建的卷（或标记被删掉的卷）在这里补上防索引标记；失败只记日志，不影响挂载。
                return
            case .reportedByDiskUtil:
                // statfs 还没看到挂载表更新，但磁盘仲裁已经确认卷在目标路径上了，按成功处理。
                // 这时不写防索引标记：标记是普通文件，写错地方会落在容器里的空目录上。
                AppLogger.shared.logContext(
                    "挂载校验以磁盘仲裁结果为准（statfs 尚未刷新）",
                    details: [("operation_id", operationID), ("mount_point", mountPoint.path)],
                    level: "WARN"
                )
                throw MigrationError.mountVerificationFailed(mountPoint)
            case .notMounted:
                break
            }

            // 校验没过：`mountLanding` 顺手查到的"卷现在挂在哪"就是 diskarbitrationd 的权威答案，
            // 直接交给下一轮判断要不要先把卷从别处卸下来，不重复查。
            hint = Self.knownMountPoint(from: landing.info)
            AppLogger.shared.logContext(
                "挂载后校验失败，准备重试",
                details: [
                    ("operation_id", operationID),
                    ("attempt", "\(attempt)/\(Self.maximumMountAttempts)"),
                    ("mount_point", mountPoint.path),
                    ("current_mount_point", landing.info?.mountPoint ?? "")
                ],
                level: "WARN"
            )
            guard attempt < Self.maximumMountAttempts else {
                throw MigrationError.mountVerificationFailed(mountPoint)
            }
            try? await Task.sleep(nanoseconds: Self.mountRetrySettleNanoseconds)
        }
    }

    /// A command failure never opens the local directory for a second attempt.
    private func performMount(_ volumeUUID: String, at mountPoint: URL, requireOwnership: Bool) async throws {
        try store.recheckWriterAdmission()
        do {
            try await disk.mount(volume: volumeUUID, at: mountPoint, requireOwnership: requireOwnership)
        }
        catch { throw MigrationError.mountFailed(mountPoint, error.localizedDescription) }
    }

    /// 这次挂载动作的真实落点。
    private enum MountLanding: Equatable {
        /// `statfs` 确认目标路径就是挂载点。
        case mountPointVisible
        /// `statfs` 还没刷新，但磁盘仲裁报告卷挂在目标路径上。
        case reportedByDiskUtil
        /// 卷不在目标路径上（多半是又被系统自动挂到了 `/Volumes`）。
        case notMounted
    }

    private func mountLanding(
        volumeUUID: String,
        at mountPoint: URL
    ) async throws -> (landing: MountLanding, info: DiskUtility.VolumeInfo?) {
        if isMountPoint(mountPoint) {
            try await requireExpectedVolume(volumeUUID, at: mountPoint)
            return (.mountPointVisible, nil)
        }
        let info = try? await disk.volumeInfo(for: volumeUUID)
        guard let current = info?.mountPoint, !current.isEmpty else {
            return (.notMounted, info)
        }
        return (DiskUtility.pathsMatch(current, mountPoint.path) ? .reportedByDiskUtil : .notMounted, info)
    }

    /// An intent saved before any copy or switch must not strand the application.
    /// Retain its history for explicit restore retry; only exempt the exact intent
    /// after proving that none of its temporary paths or saved copies exist.
    private func remountCompatibleRestoreIDs(record: ContainerMountRecord) async throws -> Set<UUID> {
        let transfers = try store.transfers()
        let pending = transfers.filter {
            $0.isUnstartedMountRestore && $0.originalPath == record.mountPointPath
                && $0.sourceIdentity.volumeUUID?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame
        }
        guard pending.count <= 1 else { throw DataOperationSafety.Failure.conflict(record.mountPointPath) }
        guard let intent = pending.first else { return [] }
        let prior = transfers.first {
            $0.mode == .mount && $0.direction == .migrate && $0.originalPath == record.mountPointPath
                && $0.createdVolumeUUID == record.volumeUUID
                && [.awaitingUserVerification, .cleanupRequested].contains($0.phase)
        }
        guard intent.priorOperationID == prior?.operationID,
              intent.recoveryMountPointIdentity == nil else {
            throw DataOperationSafety.Failure.conflict(record.mountPointPath)
        }
        try await validateUnstartedRestorePaths(intent, record: record)
        return [intent.operationID]
    }

    private func validateUnstartedRestorePaths(_ transfer: DataTransferRecord, record: ContainerMountRecord) async throws {
        let root = record.mountPointURL
        let staging = root.deletingLastPathComponent().appendingPathComponent(".appports-restore-staging-\(transfer.operationID.uuidString)")
        let recovery = stagingMountRootURL.appendingPathComponent("recovery-\(transfer.operationID.uuidString)")
        guard transfer.isUnstartedMountRestore, transfer.appName == record.appName,
              transfer.bundleIdentifier == record.bundleIdentifier, transfer.dataDirType == record.dataDirType,
              transfer.stagingPath == staging.path, transfer.backupPath == recovery.path else {
            throw DataOperationSafety.Failure.conflict(root.path)
        }
        var info = stat()
        guard lstat(staging.path, &info) != 0, errno == ENOENT else {
            throw DataOperationSafety.Failure.conflict(staging.path)
        }
        if let expected = transfer.recoveryMountPointIdentity {
            if isMountPoint(recovery) {
                try await requireExpectedVolume(record.volumeUUID, at: recovery)
            } else {
                guard lstat(recovery.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                      try DataPathIdentity.capture(recovery).matchesFilesystemObject(expected) else {
                    throw DataOperationSafety.Failure.conflict(recovery.path)
                }
                // mountVolume's descriptor-backed lease checks emptiness before any mount.
            }
        } else {
            guard lstat(recovery.path, &info) != 0, errno == ENOENT else {
                throw DataOperationSafety.Failure.conflict(recovery.path)
            }
        }
    }

    func requireOwners(at url: URL) throws {
        guard let flags = mountFlags(url) else { throw DataOperationSafety.Failure.inspection(url.path) }
        guard flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else {
            AppLogger.shared.logContext("文件所有权检查失败", details: [("path", url.path), ("mount_flags", String(flags)), ("reason", "noowners")], level: "ERROR")
            throw TreeCopyError.ownershipDisabled(url.path)
        }
    }

    func requireExpectedVolume(_ uuid: String, at mountPoint: URL) async throws {
        guard isMountPoint(mountPoint) else { throw MigrationError.mountVerificationFailed(mountPoint) }
        let actual: String?
        if let cached = mountedVolumeUUID(mountPoint) {
            actual = cached
        } else {
            actual = try await disk.volumeInfo(for: mountPoint.path).volumeUUID
        }
        guard actual?.caseInsensitiveCompare(uuid) == .orderedSame else {
            throw MigrationError.unexpectedMountedVolume(mountPoint)
        }
    }

    /// 卷已挂在别的位置时先卸载它。
    ///
    /// macOS 开机和插盘时会把 APFS 卷自动挂到 `/Volumes` 下；而 `diskutil mount -mountPoint`
    /// 对已挂载的卷会忽略挂载点参数并直接报告成功，此时容器路径依然是空目录。
    /// 所以挂载前必须先让卷回到"未挂载"状态，挂载动作才是幂等的。
    /// - Parameter knownMountPoint: 调用方**已经知道**的卷挂载位置（开机和插盘时来自 `/Volumes/<卷名>`
    ///   的 `statfs` + 卷根标记）。`.unknown` 表示不知道，这里自己查一次 diskutil
    ///   （开机时那次查询要一秒上下，能省就省）。
    private func detachForeignMountPoint(
        volumeUUID: String,
        target: URL,
        operationID: String,
        knownMountPoint: KnownMountPoint = .unknown
    ) async throws {
        let currentPath: String?
        switch knownMountPoint {
        case .mounted(let url): currentPath = url.path
        case .unmounted: currentPath = nil
        case .unknown: currentPath = (try? await disk.volumeInfo(for: volumeUUID))?.mountPoint
        }
        guard let currentPath, !currentPath.isEmpty else { return }
        let currentURL = URL(fileURLWithPath: currentPath)
        guard !DiskUtility.pathsMatch(currentURL.path, target.path) else { return }
        AppLogger.shared.logContext(
            "容器卷已挂在其它位置，先卸载再挂到容器路径",
            details: [
                ("operation_id", operationID),
                ("volume", volumeUUID),
                ("current_mount_point", currentPath),
                ("target_mount_point", target.path)
            ]
        )
        do {
            try await requireExpectedVolume(volumeUUID, at: currentURL)
            try await unmountVolume(mountPoint: currentURL)
        } catch {
            AppLogger.shared.logError(
                "卸载占用其它挂载点的容器卷失败，无法把它挂到容器路径",
                error: error,
                errorCode: "CONTAINER-MOUNT-DETACH-FAILED",
                context: [
                    ("operation_id", operationID),
                    ("volume", volumeUUID),
                    ("current_mount_point", currentPath)
                ],
                relatedURLs: [("target_mount_point", target)]
            )
            throw MigrationError.unmountFailed(currentURL, error.localizedDescription)
        }
    }

    func removeEmptyDirectoryQuietly(at url: URL) {
        guard (try? store.recheckWriterAdmission()) != nil, !isMountPoint(url), !isSymbolicLink(at: url),
              let lease = try? makeMountPointLease(url), (try? lease.verifyBeforeMount()) != nil else { return }
        _ = rmdir(url.path)
    }

    /// Never follow a replacement link or delete a name-based exemption.
    func removeEmptyMountPoint(at url: URL) throws {
        guard !isMountPoint(url), !isSymbolicLink(at: url) else { throw MigrationError.unexpectedMountedVolume(url) }
        let lease: any MountPointLeasing
        do { lease = try makeMountPointLease(url); try lease.verifyBeforeMount() }
        catch MountPointLease.Failure.notEmpty { throw MigrationError.mountPointNotEmpty(url) }
        try store.recheckWriterAdmission()
        guard rmdir(url.path) == 0 else {
            let code = errno
            if code == ENOTEMPTY || code == EEXIST { throw MigrationError.mountPointNotEmpty(url) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    // MARK: - Volume metadata

    private func writeVolumeMarker(
        at volumeRoot: URL,
        mountPointPath: String,
        volumeUUID: String,
        dataDirType: String,
        appName: String
    ) throws {
        try store.recheckWriterAdmission()
        let marker = VolumeMarker(
            schemaVersion: ContainerMountRecord.currentSchemaVersion,
            managedBy: Self.managedIdentifier,
            mountPointPath: mountPointPath,
            volumeUUID: volumeUUID,
            dataDirType: dataDirType,
            appName: appName,
            createdAt: Date()
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try DurableFileIO.write(encoder.encode(marker), to: volumeRoot.appendingPathComponent(Self.volumeMarkerFileName))
    }

    /// `diskutil info` 的结果 → 卷挂在哪。
    static func knownMountPoint(from info: DiskUtility.VolumeInfo?) -> KnownMountPoint {
        guard let info else { return .unknown }
        guard let current = info.mountPoint, !current.isEmpty else { return .unmounted }
        return .mounted(at: URL(fileURLWithPath: current))
    }

    /// 读卷根迁移标记里的 Volume UUID；认不出来（文件不在、格式变了）返回 nil。
    static func readVolumeMarkerUUID(at volumeRoot: URL) -> String? {
        let url = volumeRoot.appendingPathComponent(volumeMarkerFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListDecoder().decode(VolumeMarker.self, from: data))?.volumeUUID
    }

    func requireVolumeMarker(at root: URL, record: ContainerMountRecord) throws {
        guard !isSymbolicLink(at: root), isMountPoint(root) else { throw MigrationError.unexpectedMountedVolume(root) }
        let markerURL = root.appendingPathComponent(Self.volumeMarkerFileName)
        guard !isSymbolicLink(at: markerURL),
              let marker = try? PropertyListDecoder().decode(VolumeMarker.self, from: Data(contentsOf: markerURL)),
              marker.managedBy == Self.managedIdentifier,
              marker.volumeUUID.caseInsensitiveCompare(record.volumeUUID) == .orderedSame,
              marker.mountPointPath == record.mountPointPath, marker.dataDirType == record.dataDirType,
              marker.appName == record.appName else { throw DataOperationSafety.Failure.conflict(root.path) }
    }

    /// 在卷根放一个空的 `.metadata_never_index`，让 Spotlight 跳过整个卷。
    ///
    /// 幂等：标记已存在就原样返回，连索引目录也不动。真正写入时顺手清掉系统已经建好的
    /// 索引目录，那份索引会一直白占卷上几十到上百 MB。
    /// - Returns: 本次真的写了标记返回 `true`，标记早就存在返回 `false`。
    @discardableResult
    static func writeNeverIndexMarker(at volumeRoot: URL, fileManager: FileManager = .default) throws -> Bool {
        let markerURL = volumeRoot.appendingPathComponent(neverIndexFileName)
        guard !fileManager.fileExists(atPath: markerURL.path) else { return false }
        try Data().write(to: markerURL, options: .atomic)
        let indexDirectory = volumeRoot.appendingPathComponent(".Spotlight-V100")
        if fileManager.fileExists(atPath: indexDirectory.path) {
            try? fileManager.removeItem(at: indexDirectory)
        }
        return true
    }

    /// 挂载/迁移后补标记。任何失败都只记日志 —— 防索引是优化，
    /// 不该让挂载本身失败（例如卷以只读方式挂上时）。
    private func writeNeverIndexMarkerIfNeeded(at volumeRoot: URL, operationID: String) {
        do {
            try store.recheckWriterAdmission()
            guard try Self.writeNeverIndexMarker(at: volumeRoot, fileManager: fileManager) else { return }
            AppLogger.shared.logContext(
                "卷根已写入防索引标记",
                details: [("operation_id", operationID), ("volume_root", volumeRoot.path)]
            )
        } catch {
            AppLogger.shared.logError(
                "卷根写入防索引标记失败，Spotlight 可能继续索引该卷",
                error: error,
                errorCode: "CONTAINER-MOUNT-NEVER-INDEX-WRITE-FAILED",
                context: [("operation_id", operationID)],
                relatedURLs: [("volume_root", volumeRoot)]
            )
        }
    }

    // MARK: - 私有辅助：文件系统

    func moveTree(_ source: URL, to destination: URL) throws {
        try store.recheckWriterAdmission()
        try DataTransferSession.measure(.switching) { try DataTreeRelocator.move(source, to: destination) }
    }

    func unmountVolume(mountPoint: URL, force: Bool = false) async throws {
        try store.recheckWriterAdmission()
        try await DataTransferSession.measure(.switching) { try await disk.unmount(mountPoint: mountPoint, force: force) }
    }

    func deleteAPFSVolume(_ uuid: String, requireUnmounted: Bool = false,
                          authorizationEvidence: DiskUtility.DeletionAuthorizationEvidence? = nil,
                          beforeDeletion: @escaping () throws -> Void = {}) async throws {
        DataTransferSession.progress?.begin(.cleaning)
        try store.recheckWriterAdmission()
        try await disk.deleteAPFSVolume(uuid, requireUnmounted: requireUnmounted,
            authorizationEvidence: authorizationEvidence, beforeDeletion: beforeDeletion)
    }

    private func setOwnershipForRestore(mountPoint: URL, originalFlags: UInt32, enabled: Bool) async throws {
        if enabled, originalFlags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 {
            try safety.requireMountPointParentAccess(at: mountPoint)
        }
        try store.recheckWriterAdmission()
        try await disk.setOwnershipForRestore(mountPoint: mountPoint, originalFlags: originalFlags, enabled: enabled)
    }

    /// A denied or cancelled update can leave every option unchanged. Verify
    /// that state before requesting another privileged command for rollback.
    func restoreOriginalMountOptions(mountPoint: URL, volumeUUID: String, originalFlags: UInt32) async throws {
        try await requireExpectedVolume(volumeUUID, at: mountPoint)
        let mask = UInt32(MNT_IGNORE_OWNERSHIP | MNT_DONTBROWSE | MNT_RDONLY | MNT_NODEV | MNT_NOSUID | MNT_NOEXEC)
        guard let current = mountFlags(mountPoint) else { throw DataOperationSafety.Failure.inspection(mountPoint.path) }
        let original = originalFlags & mask
        let restored = original | UInt32(MNT_DONTBROWSE)
        if current & mask == original || current & mask == restored { return }
        // Only reverse this attempt's owners update, retaining any independent
        // mount-option change as a conflict instead of overwriting it.
        guard current & mask == (restored & ~UInt32(MNT_IGNORE_OWNERSHIP)) else {
            throw DataOperationSafety.Failure.conflict(mountPoint.path)
        }
        // Undo the old, unnecessary owners update with a normal mount. This
        // avoids a second privileged `mount -u` after a failed legacy restore.
        guard originalFlags & UInt32(MNT_IGNORE_OWNERSHIP) != 0,
              originalFlags & UInt32(MNT_RDONLY | MNT_NOEXEC) == 0 else {
            throw DataOperationSafety.Failure.conflict(mountPoint.path)
        }
        let identity = try DataPathIdentity.capture(mountPoint, volumeUUID: volumeUUID)
        try await safety.requireNoKnownWriters(at: mountPoint, bundleIdentifier: nil)
        try await requireExpectedVolume(volumeUUID, at: mountPoint)
        guard mountFlags(mountPoint) == current,
              try DataPathIdentity.capture(mountPoint, volumeUUID: volumeUUID).matchesFilesystemObject(identity) else {
            throw DataOperationSafety.Failure.conflict(mountPoint.path)
        }
        try safety.requireMountPointParentAccess(at: mountPoint)
        do {
            try await unmountVolume(mountPoint: mountPoint)
            try await mountVolume(volumeUUID, at: mountPoint, operationID: "legacy-ownership-recovery",
                                  knownMountPoint: .unmounted, requireOwnership: false)
            try await requireExpectedVolume(volumeUUID, at: mountPoint)
            guard mountFlags(mountPoint).map({ $0 & mask == restored }) == true else {
                throw DataOperationSafety.Failure.inspection(mountPoint.path)
            }
        } catch {
            let operationError = error
            // A failed option correction is not permission to strand data.
            // Restore the prior usable mount if the volume is still unmounted;
            // never detach a volume that appeared elsewhere in the meantime.
            if !isMountPoint(mountPoint) {
                do {
                    let info = try await disk.volumeInfo(for: volumeUUID)
                    guard info.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame,
                          info.mountPoint?.isEmpty ?? true else { throw operationError }
                    try safety.requireMountPointParentAccess(at: mountPoint)
                    try await mountVolume(volumeUUID, at: mountPoint, operationID: "legacy-ownership-recovery-rollback",
                        knownMountPoint: .unmounted, allowRelocation: false,
                        requireOwnership: current & UInt32(MNT_IGNORE_OWNERSHIP) == 0)
                    try await requireExpectedVolume(volumeUUID, at: mountPoint)
                    guard try DataPathIdentity.capture(mountPoint, volumeUUID: volumeUUID).matchesFilesystemObject(identity),
                          mountFlags(mountPoint).map({ $0 & mask == current & mask }) == true else {
                        throw DataOperationSafety.Failure.conflict(mountPoint.path)
                    }
                } catch let rollbackError {
                    throw MigrationError.ownershipRollbackFailed(mountPoint, operation: operationError, rollback: rollbackError)
                }
            }
            throw operationError
        }
    }

    func existingRealDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !isSymbolicLink(at: url)
    }

    func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func makeMigrationBackupURL(for sourcePath: URL) -> URL {
        let parentURL = sourcePath.deletingLastPathComponent()
        let backupName = ".appports-migration-backup-\(sourcePath.lastPathComponent)-\(UUID().uuidString)"
        return parentURL.appendingPathComponent(backupName)
    }

}
