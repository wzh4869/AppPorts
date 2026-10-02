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
/// - **迁移**：建卷 → 临时挂载并复制 → 卸载 → 原目录改名为安全备份 → 在原路径挂载 → 写记录 → 保留原件待验证
/// - **还原**：确保已挂载 → 复制到暂存目录 → 卸载 → 暂存目录改回原路径 → 保留外置卷待验证
/// - **挂载 / 卸载**：只处理已有记录。未挂载期间挂载点保持 000 权限，
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

        var errorDescription: String? {
            switch self {
            case .sourceNotDirectory(let url):
                return String(format: "该路径不是真实目录，无法挂载迁移：%@".localized, url.lastPathComponent)
            case .alreadyManaged(let url):
                return String(format: "该目录已经是挂载迁移项：%@".localized, url.lastPathComponent)
            case .externalNotAPFS(let url):
                return String(format: "外部存储不是 APFS 格式，无法创建挂载卷：%@".localized, url.path)
            case .encryptedDestination:
                return "所选 APFS 卷已加密，新建数据卷不会继承它的密码。为避免降低数据保护，当前版本不支持向此位置挂载迁移；原数据未改动，可以继续保留现状。".localized
            case .unexpectedMountedVolume(let url):
                return String(format: "此目录挂载的卷与迁移记录不一致，已停止操作并保留数据：%@".localized, url.path)
            case .volumeCreationFailed(let output):
                return String(format: "创建外置卷失败：%@".localized, output)
            case .mountFailed(let url, let output):
                return String(format: "挂载到容器目录失败：%@\n%@".localized, url.path, output)
            case .mountVerificationFailed(let url):
                return String(format: "挂载后校验失败，该路径不是挂载点：%@".localized, url.path)
            case .mountPointConflict(let url, let details):
                return String(format: "挂载点出现并发变化，已保留两端数据，请检查后恢复：%@\n%@".localized, url.path, details)
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
                return String(
                    format: "挂载迁移未完成，原数据保留在「%@」，未覆盖当前路径。外置卷「%@」（%@）也已保留。请检查挂载点后再恢复。%@".localized,
                    backup.path, volumeName, volumeUUID, error.localizedDescription
                )
            case .restoreIncomplete(let staging, let error):
                return String(
                    format: "还原没有完成：外置卷上的数据和迁移记录保持不变，已复制到本机的副本保留在「%@」。%@".localized,
                    staging.path,
                    error.localizedDescription
                )
            case .restoreRecordRecovery(let staging, let error):
                return String(
                    format: "还原未完成，已复制的本地数据保留在「%@」，外置卷也已保留。请检查迁移记录和挂载状态后重试。%@".localized,
                    staging.path, error.localizedDescription
                )
            case .ownershipRollbackFailed(let url, let operation, let rollback):
                return String(format: "还原失败，且无法恢复卷的原挂载选项；数据已保留，请检查挂载状态：%@\n%@\n%@".localized,
                              url.path, operation.localizedDescription, rollback.localizedDescription)
            }
        }
    }

    struct MigrationResult: Sendable {
        let record: ContainerMountRecord
        let cleanupWarning: CleanupWarning?
    }

    /// 主操作已完成，副本或记录清理尚未完成；调用方须按部分成功呈现。
    struct CleanupWarning: Sendable {
        let cleanup: ContainerCleanupRecord
        let details: String
        var needsRecordUpdateOnly = false

        var message: String {
            if needsRecordUpdateOnly {
                return String(format: "数据操作和副本清理已完成，但清理记录尚未更新。请稍后重试。%@".localized, details)
            }
            switch cleanup.kind {
            case .migrationBackup:
                return String(
                    format: "挂载迁移已完成，但本地安全备份仍保留在「%@」。可稍后重试清理；当前挂载数据不受影响。%@".localized,
                    cleanup.localPath, details
                )
            case .restoredVolume:
                return String(
                    format: "数据已还原到「%@」，但外置卷「%@」（%@）的清理尚未完成。该卷不会再自动挂载，请稍后重试清理。%@".localized,
                    cleanup.localPath, cleanup.mountRecord.volumeName, cleanup.mountRecord.volumeUUID, details
                )
            }
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
    private static let lockedMountPointMode: mode_t = 0o000
    private static let openMountPointMode: mode_t = 0o700
    /// 挂载动作的尝试轮数：命令报告成功但挂载点没出现时（被系统自动挂载抢先）重来。
    static let maximumMountAttempts = 3
    /// 两次挂载尝试之间的间隔，给自动挂载留出落地时间。
    private static let mountRetrySettleNanoseconds: UInt64 = 500_000_000
    /// 卷根目录上由系统创建、不属于应用数据的条目，还原时不带回本地。
    private static let volumeSystemArtifacts: Set<String> = [
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
    private let disk: DiskUtility
    private let store: ContainerMountStore
    private let isMountPoint: @Sendable (URL) -> Bool
    private let mountedVolumePath: @Sendable (URL) -> String?
    private let mountedVolumeUUID: @Sendable (URL) -> String?
    /// 读卷根迁移标记里的 Volume UUID。挂载前用它确认 `/Volumes/<卷名>` 上挂的就是我们要的卷，
    /// 测试注入假实现，避免真去读磁盘。
    private let volumeUUIDMarker: @Sendable (URL) -> String?
    /// 记录增删后同步登录代理的安装状态；测试注入空实现，避免动真实 LaunchAgents。
    private let synchronizeAgent: @Sendable (ContainerMountStore) -> Void
    /// 路径所在卷的可用空间；返回 nil 表示查不到，此时不拦截。测试注入固定值。
    private let availableCapacity: @Sendable (URL) -> Int64?
    /// 挂载点的挂载标志，用来发现早期版本挂上、仍会显示在 Finder 里的卷。测试注入固定值。
    private let mountFlags: @Sendable (URL) -> UInt32?
    private let stagingMountRootURL: URL
    private let safety: DataOperationSafety
    private let makeMountPointLease: @Sendable (URL) throws -> any MountPointLeasing

    init(
        disk: DiskUtility = DiskUtility(),
        store: ContainerMountStore = .shared,
        stagingMountRootURL: URL? = nil,
        isMountPoint: @escaping @Sendable (URL) -> Bool = { DiskUtility.isMountPoint($0) },
        mountedVolumePath: @escaping @Sendable (URL) -> String? = { DiskUtility.mountedVolumePath(containing: $0) },
        mountedVolumeUUID: @escaping @Sendable (URL) -> String? = { DiskUtility.mountedVolumeUUID(at: $0) },
        volumeUUIDMarker: @escaping @Sendable (URL) -> String? = { ContainerVolumeMigrator.readVolumeMarkerUUID(at: $0) },
        synchronizeAgent: @escaping @Sendable (ContainerMountStore) -> Void = { ContainerMountAgentInstaller.installIfNeeded(store: $0) },
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { DiskUtility.availableCapacity(at: $0) },
        mountFlags: @escaping @Sendable (URL) -> UInt32? = { DiskUtility.mountFlags(at: $0) },
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        safetyRunner: any ShellCommandRunning = ProcessCommandRunner(),
        makeMountPointLease: @escaping @Sendable (URL) throws -> any MountPointLeasing = { try MountPointLease(at: $0) },
        removeMigrationBackup: @escaping @Sendable (URL) throws -> Void = { try FileCopier.removeCopy(at: $0) }
    ) {
        self.safety = DataOperationSafety(homeDirectory: homeDirectory, store: store, runner: safetyRunner)
        self.makeMountPointLease = makeMountPointLease
        self.disk = disk
        self.store = store
        self.isMountPoint = isMountPoint
        self.mountedVolumePath = mountedVolumePath
        self.mountedVolumeUUID = mountedVolumeUUID
        self.volumeUUIDMarker = volumeUUIDMarker
        self.synchronizeAgent = synchronizeAgent
        self.availableCapacity = availableCapacity
        self.mountFlags = mountFlags
        self.stagingMountRootURL = stagingMountRootURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AppPorts/mounts")
    }

    // MARK: - 迁移

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
        progressHandler: FileCopier.ProgressHandler?
    ) async throws -> MigrationResult {
        let source = item.path.standardizedFileURL
        try await safety.requireNewMigration(at: source, bundleIdentifier: bundleIdentifier)
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
        guard !externalInfo.isEncrypted else { throw MigrationError.encryptedDestination }
        if item.sizeBytes > 0, let available = availableCapacity(externalRootURL) {
            let required = Self.requiredFreeBytes(forDataBytes: item.sizeBytes)
            guard available >= required else { throw MigrationError.insufficientSpace(required: required, available: available) }
        }
        let backup = makeMigrationBackupURL(for: source)
        var transfer = DataTransferRecord(mode: .mount, direction: .migrate, sourceID: item.id,
            appName: appName, bundleIdentifier: bundleIdentifier, dataDirType: item.type.rawValue,
            originalPath: source.path, activePath: source.path, destinationPath: source.path,
            backupPath: backup.path, sourceIdentity: try DataPathIdentity.capture(source))
        try store.beginTransfer(transfer)
        let operationID = transfer.operationID.uuidString
        let volumeName = DiskUtility.makeVolumeName(bundleIdentifier: bundleIdentifier, appName: appName,
                                                    directoryName: source.lastPathComponent)
        do {
            let device = try await disk.createAPFSVolume(inContainer: container, name: volumeName)
            let info = try await disk.volumeInfo(for: device)
            guard let uuid = info.volumeUUID else { throw MigrationError.volumeCreationFailed(device) }
            transfer.createdVolumeUUID = uuid
            let staging = stagingMountRootURL.appendingPathComponent(operationID)
            transfer.stagingPath = staging.path
            try store.updateTransfer(transfer)
            try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await mountVolume(uuid, at: staging, operationID: operationID)
            try requireOwners(at: staging)
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
            let baseline = try await TreeCopySession().copy(from: source, to: staging,
                excludingRootEntries: Self.volumeSystemArtifacts, finalDestination: source, progressHandler: progressHandler)
            try TreeCopySession.applyRootMetadata(at: staging, from: baseline)
            try TreeCopySession.verifyCopy(at: staging, against: baseline)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.destinationIdentity = try DataPathIdentity.capture(staging, volumeUUID: uuid)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            await progressHandler?(FileCopier.Progress(copiedBytes: baseline.logicalBytes,
                totalBytes: baseline.logicalBytes, currentFile: "正在切换本地入口...".localized))
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: bundleIdentifier)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try TreeCopySession.verifyCopy(at: staging, against: baseline)
            try await requireExpectedVolume(uuid, at: staging)
            try await disk.unmount(mountPoint: staging)
            removeEmptyDirectoryQuietly(at: staging)
            transfer.phase = .switching
            try store.updateTransfer(transfer)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try DataTreeRelocator.move(source, to: backup)
            transfer.backupIdentity = try DataPathIdentity.capture(backup)
            try store.updateTransfer(transfer)
            try TreeCopySession.verifyUnchanged(at: backup, against: baseline)
            try await mountVolume(uuid, at: source, operationID: operationID)
            try requireOwners(at: source)
            // A held descriptor can still write to the retained original after rename.
            try TreeCopySession.verifyUnchanged(at: backup, against: baseline)
            let record = ContainerMountRecord(appName: appName, bundleIdentifier: bundleIdentifier,
                dataDirType: item.type.rawValue, mountPointPath: source.path, volumeUUID: uuid,
                volumeName: volumeName, externalRootPath: externalRootURL.standardizedFileURL.path)
            try store.commitMigration(record: record, transfer: transfer)
            synchronizeAgent(store)
            invalidateSizeCache(for: source)
            return MigrationResult(record: record, cleanupWarning: nil)
        } catch {
            // Never erase a partial or switched copy on an error. Durable intent
            // keeps all known identities available for explicit recovery.
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
        let mountPoint = record.mountPointURL
        try safety.requirePolicy(at: mountPoint)
        guard try store.recordsStrict().contains(record) else { throw DataOperationSafety.Failure.conflict(mountPoint.path) }
        if isMountPoint(mountPoint) {
            try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
            if try store.remountIntervention(forVolumeUUID: record.volumeUUID) != nil {
                throw DataOperationSafety.Failure.conflict(mountPoint.path)
            }
            return
        }
        let related = try store.transfers().filter {
            $0.mode == .mount && $0.direction == .migrate && $0.createdVolumeUUID == record.volumeUUID
                && $0.originalPath == record.mountPointPath && [.awaitingUserVerification, .cleanupRequested].contains($0.phase)
        }
        try safety.requireNoOverlap(at: mountPoint, ownedMount: record,
                                    ownedTransferIDs: Set(related.map(\.operationID)))
        try safety.requireNoManagedFileSystemAncestor(at: mountPoint)
        let operationID = AppLogger.shared.makeOperationID(prefix: "container-mount")
        let hint = try await knownMountPoint(for: record, operationID: operationID)
        try await mountVolume(record.volumeUUID, at: mountPoint, operationID: operationID, knownMountPoint: hint)
        try store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: nil)
        invalidateSizeCache(for: mountPoint)
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
    private func knownMountPoint(for record: ContainerMountRecord, operationID: String) async throws -> KnownMountPoint {
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
            try await disk.unmount(mountPoint: mountPoint, force: force)
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
        do { records = try store.recordsStrict() }
        catch {
            AppLogger.shared.logError("无法读取挂载记录，自动挂载已停止", error: error)
            return []
        }
        for record in records {
            do {
                if let reason = try store.remountIntervention(forVolumeUUID: record.volumeUUID) {
                    outcomes.append(RemountOutcome(record: record, state: .requiresIntervention(reason)))
                    continue
                }
                let alreadyMounted = isMountPoint(record.mountPointURL)
                // 在线检查放在 mount(record:) 里，和「当前挂载点」共用同一次 diskutil 查询。
                try await mount(record: record)
                outcomes.append(RemountOutcome(record: record, state: alreadyMounted ? .alreadyMounted : .mounted))
            } catch let error as MigrationError {
                if case .volumeUnavailable = error {
                    outcomes.append(RemountOutcome(record: record, state: .unavailable))
                } else {
                    try? store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: error.localizedDescription)
                    outcomes.append(RemountOutcome(record: record, state: .requiresIntervention(error.localizedDescription)))
                }
            } catch {
                try? store.setRemountIntervention(volumeUUID: record.volumeUUID, reason: error.localizedDescription)
                outcomes.append(RemountOutcome(record: record, state: .requiresIntervention(error.localizedDescription)))
            }
        }
        return outcomes
    }

    // MARK: - 还原

    /// Copy back to local storage and retain the source volume for explicit cleanup.
    @discardableResult
    func restore(
        record: ContainerMountRecord,
        estimatedTotalBytes: Int64,
        progressHandler: FileCopier.ProgressHandler?
    ) async throws -> CleanupWarning? {
        let mountPoint = record.mountPointURL
        // Exact history ownership is required. A stale UI value cannot authorize recovery.
        guard try store.recordsStrict().contains(record) else { throw MigrationError.alreadyManaged(mountPoint) }
        let transfers = try store.transfers()
        let prior = transfers.first {
            $0.mode == .mount && $0.direction == .migrate && $0.originalPath == record.mountPointPath
                && $0.createdVolumeUUID == record.volumeUUID && [.awaitingUserVerification, .cleanupRequested].contains($0.phase)
        }
        let resumable = transfers.filter {
            $0.isUnstartedMountRestore && $0.originalPath == record.mountPointPath
                && $0.sourceIdentity.volumeUUID?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame
                && $0.priorOperationID == prior?.operationID
        }
        guard resumable.count <= 1 else { throw DataOperationSafety.Failure.conflict(mountPoint.path) }
        if let pending = resumable.first { try validateUnstartedRestorePaths(pending, record: record) }
        var ownedIDs = Set(prior.map { [$0.operationID] } ?? [])
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
        var projectedOwner: TreeCopySnapshot.Ownership?
        if originallyOnline {
            try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
            try await safety.requireNoKnownWriters(at: mountPoint, bundleIdentifier: record.bundleIdentifier)
            guard let flags = mountFlags(mountPoint) else { throw DataOperationSafety.Failure.inspection(mountPoint.path) }
            originalFlags = flags
            if flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 {
                var info = stat()
                guard lstat(mountPoint.path, &info) == 0, info.st_uid == geteuid(), info.st_gid == getegid() else {
                    throw TreeCopyError.unsupportedMetadata(mountPoint.path)
                }
                projectedOwner = .init(uid: info.st_uid, gid: info.st_gid)
            }
        }
        let id = resumable.first?.operationID ?? UUID()
        let staging = mountPoint.deletingLastPathComponent().appendingPathComponent(".appports-restore-staging-\(id.uuidString)")
        let recovery = stagingMountRootURL.appendingPathComponent("recovery-\(id.uuidString)")
        var transfer = DataTransferRecord(operationID: id, mode: .mount, direction: .restore,
            sourceID: prior?.sourceID, appName: record.appName, bundleIdentifier: record.bundleIdentifier,
            dataDirType: record.dataDirType, originalPath: mountPoint.path, activePath: mountPoint.path,
            destinationPath: mountPoint.path, backupPath: recovery.path, stagingPath: staging.path,
            sourceIdentity: DataPathIdentity(volumeUUID: record.volumeUUID), priorOperationID: prior?.operationID)
        if let pending = resumable.first {
            transfer = try store.resumeUnstartedMountRestore(pending, record: record)
        } else {
            try store.beginTransfer(transfer)
        }
        if let projectedOwner {
            transfer.legacyRootOwnership = transfer.legacyRootOwnership ?? projectedOwner
            transfer.legacyMountFlags = transfer.legacyMountFlags ?? originalFlags
            try store.updateTransfer(transfer)
        }
        let operationID = id.uuidString
        var ownershipUpdateFlags: UInt32?
        do {
            let source: URL
            if isMountPoint(mountPoint) {
                try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
                if let flags = originalFlags, flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 {
                    // Do not overwrite mount options changed since the initial preflight.
                    try await safety.requireNoKnownWriters(at: mountPoint, bundleIdentifier: record.bundleIdentifier)
                    try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
                    guard mountFlags(mountPoint) == flags else { throw DataOperationSafety.Failure.conflict(mountPoint.path) }
                    ownershipUpdateFlags = flags
                    try await disk.setOwnershipForRestore(mountPoint: mountPoint, originalFlags: flags, enabled: true)
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
                try await mountVolume(record.volumeUUID, at: recovery, operationID: operationID, knownMountPoint: hint)
                source = recovery
            }
            try requireOwners(at: source)
            // Offline legacy volumes have no prior verified manifest. A root-owned
            // APFS volume root was an implementation artifact of the old creator.
            // Only that root receives the current user's former effective ownership.
            if !originallyOnline, prior == nil, transfer.legacyRootOwnership == nil {
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
            let baseline = try await TreeCopySession().copy(from: source, to: staging,
                excludingRootEntries: Self.volumeSystemArtifacts, finalDestination: mountPoint,
                logicalSourceRoot: mountPoint, legacyRootOwnership: transfer.legacyRootOwnership, progressHandler: progressHandler)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.destinationIdentity = try DataPathIdentity.capture(staging)
            transfer.backupIdentity = transfer.sourceIdentity
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            await progressHandler?(FileCopier.Progress(copiedBytes: baseline.logicalBytes,
                totalBytes: baseline.logicalBytes, currentFile: "正在切换本地入口...".localized))
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: record.bundleIdentifier)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try TreeCopySession.verifyCopy(at: staging, against: baseline)
            try safety.requireLocalRestoreParent(at: mountPoint, isMountPoint: isMountPoint)
            try store.beginRestore(transfer: transfer, removingMount: record)
            transfer.phase = .switching
            synchronizeAgent(store)
            try await requireExpectedVolume(record.volumeUUID, at: source)
            try await disk.unmount(mountPoint: source)
            try safety.requireLocalRestoreParent(at: mountPoint, isMountPoint: isMountPoint)
            if source != mountPoint { removeEmptyDirectoryQuietly(at: source) }
            if fileManager.fileExists(atPath: mountPoint.path) {
                try removeEmptyMountPoint(at: mountPoint)
            } else if isSymbolicLink(at: mountPoint) {
                throw DataOperationSafety.Failure.conflict(mountPoint.path)
            }
            try DataTreeRelocator.move(staging, to: mountPoint)
            try TreeCopySession.verifyCopy(at: mountPoint, against: baseline)
            try store.finalizeTransfer(operationID: id, baseline: transfer.baseline!)
            invalidateSizeCache(for: mountPoint)
            // The source APFS volume remains unmounted until explicit verified cleanup.
            return nil
        } catch {
            var reportedError: Error = error
            transfer.phase = .needsRecovery
            // Revert only an update attempted by this invocation, using its fresh
            // flags. Persisted historical flags must not override a later user edit.
            if let flags = ownershipUpdateFlags, isMountPoint(mountPoint) {
                do {
                    // Use the same UUID fallback as forward preflight. A missing
                    // fast UUID must not silently skip restoring the mount options.
                    try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
                    try await disk.setOwnershipForRestore(mountPoint: mountPoint, originalFlags: flags, enabled: false)
                    try await requireExpectedVolume(record.volumeUUID, at: mountPoint)
                    let mask = UInt32(MNT_IGNORE_OWNERSHIP | MNT_DONTBROWSE | MNT_RDONLY | MNT_NODEV | MNT_NOSUID | MNT_NOEXEC)
                    guard let restored = mountFlags(mountPoint), restored & mask == (flags | UInt32(MNT_DONTBROWSE)) & mask else {
                        throw DataOperationSafety.Failure.inspection(mountPoint.path)
                    }
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

    /// Explicit retained-copy cleanup; never called by startup or remount loops.
    func cleanupRetainedTransfer(operationID: UUID) async throws {
        guard var transfer = try store.transfer(operationID: operationID), transfer.mode == .mount,
              [.awaitingUserVerification, .cleanupRequested].contains(transfer.phase),
              let encoded = transfer.baseline, let backupPath = transfer.backupPath else {
            throw DataOperationSafety.Failure.inspection(operationID.uuidString)
        }
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        let active = URL(fileURLWithPath: transfer.activePath)
        let backup = URL(fileURLWithPath: backupPath)
        // Active data may legitimately change. Prove its identity/availability,
        // rather than requiring equality with the old copy's content.
        if transfer.direction == .migrate, let uuid = transfer.createdVolumeUUID, isMountPoint(active) {
            try await requireExpectedVolume(uuid, at: active)
            guard let expected = transfer.destinationIdentity,
                  try DataPathIdentity.capture(active, volumeUUID: uuid).matchesFilesystemObject(expected) else {
                throw DataOperationSafety.Failure.conflict(active.path)
            }
        } else {
            let expected: DataPathIdentity?
            if transfer.direction == .restore { expected = transfer.destinationIdentity }
            else {
                expected = try store.transfers().first {
                    $0.direction == .restore && $0.priorOperationID == operationID
                        && [.awaitingUserVerification, .cleanupRequested].contains($0.phase)
                }?.destinationIdentity
            }
            guard let expected, !isMountPoint(active), !isSymbolicLink(at: active),
                  try DataPathIdentity.capture(active).matchesFilesystemObject(expected) else {
                throw DataOperationSafety.Failure.conflict(active.path)
            }
        }
        try safety.requireNoOverlap(at: backup, ownedTransferIDs: [operationID], ownedRetainedPath: backup.path)
        // An offline retained volume is a retryable preflight failure. Do not
        // turn a completed restore into needsRecovery before touching anything.
        var retainedVolumeIsPrivatelyMounted = false
        if transfer.direction == .restore {
            guard let uuid = transfer.sourceIdentity.volumeUUID else {
                throw DataOperationSafety.Failure.inspection(backup.path)
            }
            let info = try await disk.volumeInfo(for: uuid)
            guard info.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame else {
                throw DataOperationSafety.Failure.conflict(backup.path)
            }
            if let current = info.mountPoint, !current.isEmpty {
                guard DiskUtility.pathsMatch(current, backup.path) else {
                    throw DataOperationSafety.Failure.conflict(current)
                }
                try await requireExpectedVolume(uuid, at: backup)
                retainedVolumeIsPrivatelyMounted = true
            }
        }
        try store.requestCleanup(operationID: operationID)
        transfer.phase = .cleanupRequested
        var physicalDeletionBegan = false
        do {
            if transfer.direction == .migrate {
                guard let expected = transfer.backupIdentity, !isMountPoint(backup), !isSymbolicLink(at: backup),
                      try DataPathIdentity.capture(backup).matchesFilesystemObject(expected) else {
                    throw DataOperationSafety.Failure.conflict(backup.path)
                }
                try await safety.requireNoKnownWriters(at: backup, bundleIdentifier: transfer.bundleIdentifier)
                if let uuid = transfer.sourceIdentity.volumeUUID {
                    try TreeCopySession.verifyUnchanged(at: backup, against: baseline, expectedVolumeUUID: uuid)
                } else {
                    try TreeCopySession.verifyUnchanged(at: backup, against: baseline)
                }
                physicalDeletionBegan = true
                try TreeCopySession.removeVerifiedCopy(at: backup, against: baseline)
            } else {
                guard let uuid = transfer.sourceIdentity.volumeUUID else { throw DataOperationSafety.Failure.inspection(backup.path) }
                if !retainedVolumeIsPrivatelyMounted {
                    try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Query again inside mountVolume; a formerly offline volume
                    // may have appeared elsewhere since the preflight check.
                    try await mountVolume(uuid, at: backup, operationID: operationID.uuidString, allowRelocation: false)
                }
                try requireOwners(at: backup)
                guard try DataPathIdentity.capture(backup, volumeUUID: uuid).matchesFilesystemObject(transfer.sourceIdentity) else {
                    throw DataOperationSafety.Failure.conflict(backup.path)
                }
                try await safety.requireNoKnownWriters(at: backup, bundleIdentifier: transfer.bundleIdentifier)
                try TreeCopySession.verifyUnchanged(at: backup, against: baseline, expectedVolumeUUID: uuid)
                try await requireExpectedVolume(uuid, at: backup)
                try await disk.unmount(mountPoint: backup)
                removeEmptyDirectoryQuietly(at: backup)
                physicalDeletionBegan = true
                try await disk.deleteAPFSVolume(uuid)
            }
            try store.finishTransfer(operationID: operationID, deletionConfirmed: true)
        } catch {
            // Inspection or private mounting can be retried after revalidating
            // the complete baseline. Partial deletion cannot be auto-resumed.
            transfer.phase = physicalDeletionBegan ? .needsRecovery : .cleanupRequested
            transfer.recoverableReason = error.localizedDescription
            do { try store.updateTransfer(transfer) }
            catch { AppLogger.shared.logError("无法更新副本清理恢复记录，原事务仍保留", error: error) }
            throw error
        }
    }

    /// 用户明确重试时才清理；不经过自动挂载入口，也不重复复制已经还原的数据。
    func retryCleanup(_ warning: CleanupWarning) async -> CleanupWarning? {
        await performCleanup(warning.cleanup, recordUpdateOnly: warning.needsRecordUpdateOnly)
    }

    /// 用户明确确认后仅移除清理记录，保留所有副本；用于无法分辨卷已删除还是已断开的情况。
    /// 未完成的本地切换仍需保留恢复信息，不能通过此入口遗忘。
    func discardCleanupRecord(_ cleanup: ContainerCleanupRecord) throws {
        guard try store.pendingCleanups().contains(where: { $0.id == cleanup.id }) else { return }
        if cleanup.kind == .restoredVolume {
            let localURL = URL(fileURLWithPath: cleanup.localPath)
            guard existingRealDirectory(at: localURL), !isMountPoint(localURL),
                  cleanup.restoreStagingPath.map({ !fileManager.fileExists(atPath: $0) }) ?? true else {
                throw MigrationError.sourceNotDirectory(localURL)
            }
        }
        try store.finishCleanup(cleanup.id)
        AppLogger.shared.logContext(
            "用户仅移除清理记录，保留副本",
            details: [("cleanup_id", cleanup.id.uuidString), ("local_path", cleanup.localPath),
                      ("volume_uuid", cleanup.mountRecord.volumeUUID)],
            level: "WARN"
        )
    }

    private func performCleanup(_ cleanup: ContainerCleanupRecord, recordUpdateOnly: Bool = false) async -> CleanupWarning? {
        do {
            guard try store.pendingCleanups().contains(where: { $0.id == cleanup.id }) else { return nil }
            // A legacy record contains no verified baseline. UI state cannot prove
            // physical deletion either; only explicit record-discard is supported.
            throw DataOperationSafety.Failure.inspection(cleanup.localPath)
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
    private func mountVolume(
        _ volumeUUID: String,
        at mountPoint: URL,
        operationID: String,
        knownMountPoint: KnownMountPoint = .unknown,
        allowRelocation: Bool = true
    ) async throws {
        var hint = knownMountPoint
        for attempt in 1...Self.maximumMountAttempts {
            if allowRelocation {
                try await detachForeignMountPoint(
                    volumeUUID: volumeUUID,
                    target: mountPoint,
                    operationID: operationID,
                    knownMountPoint: hint
                )
            } else {
                // Explicit retained-volume cleanup must never detach an active
                // volume that the user mounted somewhere else in the meantime.
                let info = try await disk.volumeInfo(for: volumeUUID)
                guard info.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame,
                      info.mountPoint?.isEmpty ?? true else {
                    throw DataOperationSafety.Failure.conflict(mountPoint.path)
                }
            }
            let lease: any MountPointLeasing
            do {
                lease = try makeMountPointLease(mountPoint)
                try lease.verifyBeforeMount()
            } catch MountPointLease.Failure.notEmpty {
                throw MigrationError.mountPointNotEmpty(mountPoint)
            }
            try await performMount(volumeUUID, at: mountPoint, operationID: operationID)
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
                try requireOwners(at: mountPoint)
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
    private func performMount(_ volumeUUID: String, at mountPoint: URL, operationID: String) async throws {
        do { try await disk.mount(volume: volumeUUID, at: mountPoint, requireOwnership: true) }
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

    private func validateUnstartedRestorePaths(_ transfer: DataTransferRecord, record: ContainerMountRecord) throws {
        let root = record.mountPointURL
        let staging = root.deletingLastPathComponent().appendingPathComponent(".appports-restore-staging-\(transfer.operationID.uuidString)")
        let recovery = stagingMountRootURL.appendingPathComponent("recovery-\(transfer.operationID.uuidString)")
        guard transfer.isUnstartedMountRestore, transfer.appName == record.appName,
              transfer.bundleIdentifier == record.bundleIdentifier, transfer.dataDirType == record.dataDirType,
              transfer.stagingPath == staging.path, transfer.backupPath == recovery.path else {
            throw DataOperationSafety.Failure.conflict(root.path)
        }
        for path in [staging, recovery] {
            var info = stat()
            guard lstat(path.path, &info) != 0, errno == ENOENT else {
                throw DataOperationSafety.Failure.conflict(path.path)
            }
        }
    }

    private func requireOwners(at url: URL) throws {
        guard let flags = mountFlags(url) else { throw DataOperationSafety.Failure.inspection(url.path) }
        guard flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else {
            AppLogger.shared.logContext("文件所有权检查失败", details: [("path", url.path), ("mount_flags", String(flags)), ("reason", "noowners")], level: "ERROR")
            throw TreeCopyError.ownershipDisabled(url.path)
        }
    }

    private func requireExpectedVolume(_ uuid: String, at mountPoint: URL) async throws {
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
            try await disk.unmount(mountPoint: currentURL)
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

    private func removeEmptyDirectoryQuietly(at url: URL) {
        guard !isMountPoint(url), !isSymbolicLink(at: url),
              let lease = try? makeMountPointLease(url), (try? lease.verifyBeforeMount()) != nil else { return }
        _ = rmdir(url.path)
    }

    /// Never follow a replacement link or delete a name-based exemption.
    private func removeEmptyMountPoint(at url: URL) throws {
        guard !isMountPoint(url), !isSymbolicLink(at: url) else { throw MigrationError.unexpectedMountedVolume(url) }
        let lease: any MountPointLeasing
        do { lease = try makeMountPointLease(url); try lease.verifyBeforeMount() }
        catch MountPointLease.Failure.notEmpty { throw MigrationError.mountPointNotEmpty(url) }
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
        try encoder.encode(marker).write(to: volumeRoot.appendingPathComponent(Self.volumeMarkerFileName), options: .atomic)
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

    /// 1.9.0 之前的版本挂载时没带 `nobrowse`，卷会一直显示在 Finder 边栏和桌面上。
    /// 发现这种挂载就原地补上，不用等下次插盘或开机。失败只记日志：卷照常可用，下次重挂时会带上。
    private func hideFromFinderIfNeeded(_ mountPoint: URL) async {
        guard let flags = mountFlags(mountPoint), flags & UInt32(MNT_DONTBROWSE) == 0 else { return }
        do {
            try await disk.hideFromFinder(mountPoint: mountPoint, currentFlags: flags)
            AppLogger.shared.logContext("已为早期挂载的容器卷补上 nobrowse", details: [("mount_point", mountPoint.path)])
        } catch {
            AppLogger.shared.logContext(
                "为容器卷补 nobrowse 失败，卷仍可用，下次重挂时生效",
                details: [("mount_point", mountPoint.path), ("error", error.localizedDescription)],
                level: "WARN"
            )
        }
    }

    /// 挂载/迁移后补标记。任何失败都只记日志 —— 防索引是优化，
    /// 不该让挂载本身失败（例如卷以只读方式挂上时）。
    private func writeNeverIndexMarkerIfNeeded(at volumeRoot: URL, operationID: String) {
        do {
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

    private func existingRealDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !isSymbolicLink(at: url)
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func makeMigrationBackupURL(for sourcePath: URL) -> URL {
        let parentURL = sourcePath.deletingLastPathComponent()
        let backupName = ".appports-migration-backup-\(sourcePath.lastPathComponent)-\(UUID().uuidString)"
        return parentURL.appendingPathComponent(backupName)
    }

}
