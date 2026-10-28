import Darwin
import Foundation

protocol WeChatAccountMountDriving: Sendable {
    func migrateAndComplete(item: DataDirItem, externalRootURL: URL, appName: String,
                            bundleIdentifier: String?, progressHandler: FileCopier.ProgressHandler?) async throws -> ContainerVolumeMigrator.MigrationResult
    func restoreAndComplete(record: ContainerMountRecord, estimatedTotalBytes: Int64,
                            progressHandler: FileCopier.ProgressHandler?) async throws -> ContainerVolumeMigrator.CleanupWarning?
    func mount(record: ContainerMountRecord) async throws
    func cancelPreparation(operationID: UUID, preserveUnclaimedMaterials: Bool) async throws
    func resumeVerifiedTransfer(operationID: UUID, progressHandler: FileCopier.ProgressHandler?) async throws -> String?
}

extension ContainerVolumeMigrator: WeChatAccountMountDriving {}

/// One user action covers both media directories. Each member keeps the existing
/// durable APFS journal, so interruption never loses the completed member or its restore path.
struct WeChatAccountMigrationService: Sendable {
    enum Mode: String, CaseIterable, Sendable { case whole, split }
    enum State: Equatable { case local, whole, split, conflict }
    struct Sizing: Sendable {
        let total: DirectorySizeResult
        let media: DirectorySizeResult
        var retainedBytes: Int64 { max(0, total.bytes - media.bytes) }
        var isComplete: Bool { total.isComplete && media.isComplete }
    }
    enum Failure: LocalizedError {
        case invalidAccount, disabled, restoreFirst, missingMembers, incompleteSize
        var errorDescription: String? {
            switch self {
            case .invalidAccount: return "无法确认微信账号目录，未改动数据。".localized
            case .disabled: return "请先开启“微信账号拆分迁移”。".localized
            case .restoreFirst: return "请先完整还原这个账号已迁移的数据，再切换迁移方式。".localized
            case .missingMembers: return "账号下的 msg 和 business 必须都是可读取的真实目录，才能拆分迁移。".localized
            case .incompleteSize: return "目录大小未能完整读取，请检查访问权限后重试。".localized
            }
        }
    }

    let policy: PartialWeChatMigrationPolicy
    let store: ContainerMountStore
    let migrator: any WeChatAccountMountDriving
    let enabled: Bool

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()), store: ContainerMountStore = .shared,
         migrator: (any WeChatAccountMountDriving)? = nil,
         enabled: Bool = false,
         containerIdentifier: String = PartialWeChatMigrationPolicy.bundleIdentifier,
         encryption: APFSVolumeEncryption.Credentials? = nil) {
        policy = PartialWeChatMigrationPolicy(homeDirectory: homeDirectory, containerIdentifier: containerIdentifier)
        self.store = store
        self.migrator = migrator ?? ContainerVolumeMigrator(store: store, homeDirectory: homeDirectory,
                                                          partialWeChatMigrationEnabled: enabled, weChatContainerIdentifier: policy.containerIdentifier,
                                                          encryption: encryption)
        self.enabled = enabled
    }

    func state(of account: URL) throws -> State {
        guard policy.isAccount(account) else { throw Failure.invalidAccount }
        let inspection = try store.recordsForInspection()
        if let error = inspection.validationError { throw error }
        let paths = inspection.mounts.map(\.mountPointPath) + inspection.managedLinks.map(\.originalPath)
            + inspection.transfers.filter { $0.rollbackCompletedAt == nil && $0.retainedCopyRemovedAt == nil }.map(\.originalPath)
            + inspection.cleanups.map(\.localPath)
        let root = account.standardizedFileURL.path
        let members = Set(policy.members(of: account).map(\.path))
        let whole = paths.contains(root)
        let split = paths.contains { members.contains($0) }
        if whole && split { return .conflict }
        if whole { return .whole }
        if split { return .split }
        return .local
    }

    func measure(_ account: URL) throws -> Sizing {
        try requireAccount(account)
        let total = measureDirectorySize(at: account, useCache: false)
        var media = DirectorySizeResult()
        for member in policy.members(of: account) {
            let result = measureDirectorySize(at: member, useCache: false)
            media.bytes += result.bytes
            media.readIssues += result.readIssues
        }
        return Sizing(total: total, media: media)
    }

    /// The caller owns the application operation and cross-process locks for the whole group.
    func migrate(account: URL, mode: Mode, externalRoot: URL, appName: String,
                 progress: FileCopier.ProgressHandler? = nil) async throws -> [String] {
        if DataTransferSession.current == nil {
            return try await DataTransferSession.run {
                try await migrate(account: account, mode: mode, externalRoot: externalRoot, appName: appName, progress: progress)
            }
        }
        try requireAccount(account)
        let current = try state(of: account)
        guard current != .conflict,
              (mode == .split ? current != .whole : current == .local) else { throw Failure.restoreFirst }
        if mode == .split, !enabled { throw Failure.disabled }
        let members = mode == .split ? policy.members(of: account) : [account]
        // Validate both members before moving either one. Existing mount records
        // belong to an interrupted split and are resumed rather than migrated again.
        let records = try store.recordsStrict()
        let transfers = try store.transfers()
        let previousMounts = records + transfers.compactMap(\.recoveryMountRecord)
        if mode == .split, previousMounts.contains(where: {
            members.map(\.path).contains($0.mountPointPath)
                && URL(fileURLWithPath: $0.externalRootPath).standardizedFileURL.path != externalRoot.standardizedFileURL.path
        }) { throw Failure.restoreFirst }
        for source in members {
            let hasRecord = records.contains { $0.mountPointPath == source.path }
                || transfers.contains { $0.originalPath == source.path && $0.rollbackCompletedAt == nil }
            if hasRecord { continue }
            let info = try SignatureSnapshot.info(at: source)
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.missingMembers }
            let safety = DataOperationSafety(homeDirectory: policy.homeDirectory, store: store,
                                            partialWeChatMigrationEnabled: enabled, weChatContainerIdentifier: policy.containerIdentifier)
            try safety.requirePolicy(at: source)
            try safety.requireNoOverlap(at: source)
            try safety.requireNoManagedFileSystemAncestor(at: source)
            try safety.requireNoManagedDescendants(at: source)
            guard measureDirectorySize(at: source, useCache: false).isComplete else { throw Failure.incompleteSize }
        }
        var warnings: [String] = []
        for source in members {
            try Task.checkCancellation()
            if let record = try store.recordsStrict().first(where: { $0.mountPointPath == source.path }) {
                guard mode == .split else { throw Failure.restoreFirst }
                try await migrator.mount(record: record)
                continue
            }
            let item = DataDirItem(name: source.lastPathComponent, path: source, type: .containers,
                                   priority: .critical, description: "微信账号数据".localized)
            let result = try await migrator.migrateAndComplete(item: item, externalRootURL: externalRoot,
                appName: appName, bundleIdentifier: policy.containerIdentifier, progressHandler: progress)
            if let warning = result.cleanupWarning { warnings.append(warning.message) }
        }
        return warnings
    }

    func restoreSplit(account: URL, progress: FileCopier.ProgressHandler? = nil) async throws -> [String] {
        if DataTransferSession.current == nil {
            return try await DataTransferSession.run { try await restoreSplit(account: account, progress: progress) }
        }
        try requireAccount(account)
        let current = try state(of: account)
        let members = policy.members(of: account)
        let memberPaths = Set(members.map(\.path))
        let rolledBack = try store.transfers().filter {
            $0.mode == .mount && memberPaths.contains($0.originalPath) && $0.rollbackCompletedAt != nil
        }
        // A failed migration can have restored the local entry but still owe volume cleanup.
        guard current == .split || (current == .local && !rolledBack.isEmpty) else { throw Failure.restoreFirst }
        var warnings: [String] = []
        for transfer in rolledBack {
            try Task.checkCancellation()
            if let warning = try await migrator.resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: progress) {
                warnings.append(warning)
            }
        }
        for source in members {
            try Task.checkCancellation()
            // A preparation may not yet have published its mount record.
            if let transfer = try store.transfers().last(where: {
                $0.originalPath == source.path && !$0.isDataSwitchComplete && $0.rollbackCompletedAt == nil
            }) {
                if transfer.isPreparationRecoverable {
                    try await migrator.cancelPreparation(operationID: transfer.operationID, preserveUnclaimedMaterials: false)
                } else if let warning = try await migrator.resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: progress) {
                    warnings.append(warning)
                }
            }
            for transfer in try store.transfers() where transfer.originalPath == source.path
                && transfer.mode == .mount && transfer.direction == .restore && transfer.isDataSwitchComplete {
                if let warning = try await migrator.resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: progress) {
                    warnings.append(warning)
                }
            }
            if let record = try store.recordForRestore(at: source) {
                if let warning = try await migrator.restoreAndComplete(record: record, estimatedTotalBytes: 0, progressHandler: progress) {
                    warnings.append(warning.message)
                }
            }
        }
        return warnings
    }

    private func requireAccount(_ account: URL) throws {
        guard policy.isAccount(account),
              PartialWeChatMigrationPolicy(homeDirectory: policy.homeDirectory.resolvingSymlinksInPath(),
                                          containerIdentifier: policy.containerIdentifier)
                .isAccount(account.resolvingSymlinksInPath()),
              try SignatureSnapshot.info(at: account).st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidAccount }
    }

    /// Keep scanner recovery facts intact; the browser exposes one account action,
    /// never independent checkboxes/buttons for msg and business.
    static func groupedItems(_ items: [DataDirItem], homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
                             splitMode: Bool = false,
                             containerIdentifier: String = PartialWeChatMigrationPolicy.bundleIdentifier) -> [DataDirItem] {
        let policy = PartialWeChatMigrationPolicy(homeDirectory: homeDirectory, containerIdentifier: containerIdentifier)
        let members = Dictionary(grouping: items.filter {
            policy.account(forMember: $0.path) != nil &&
                (splitMode || $0.hasMountTransferRecord || DataDirStatus.mountStatuses.contains($0.status))
        }) {
            policy.account(forMember: $0.path)!.path
        }
        var result = items.filter {
            policy.account(forMember: $0.path) == nil || $0.hasManagedLinkRecord ||
                ($0.recoveryOperationID != nil && !$0.hasMountTransferRecord)
        }
        for (path, children) in members {
            let active = children.filter { (splitMode && $0.status == DataDirStatus.local && $0.isMigratable)
                || $0.canRestore || $0.recoveryOperationID != nil }
            guard !active.isEmpty else { continue }
            let account = URL(fileURLWithPath: path)
            let index = result.firstIndex { $0.path.standardizedFileURL.path == account.path }
            var item = index.map { result[$0] } ?? DataDirItem(name: account.lastPathComponent, path: account,
                type: .containers, priority: .critical, description: "微信账号数据".localized)
            let localPreview = splitMode && active.count == PartialWeChatMigrationPolicy.memberNames.count
                && active.allSatisfy { $0.status == DataDirStatus.local && !$0.hasMountTransferRecord && $0.recoveryOperationID == nil }
                && item.isMigratable
            if !localPreview && active.allSatisfy({ $0.status == DataDirStatus.local && !$0.hasMountTransferRecord && $0.recoveryOperationID == nil }) {
                continue
            }
            item.weChatSplitMembers = active
            item.autoMountPaused = active.contains { $0.autoMountPaused }
            item.description = "微信账号 · 拆分迁移（msg + business）".localized
            item.isMigratable = localPreview
            item.hasMountTransferRecord = !localPreview
            item.status = localPreview ? DataDirStatus.local
                : active.contains(where: { $0.status == DataDirStatus.local }) ? DataDirStatus.pendingCompletion
                : active.contains(where: { $0.status == DataDirStatus.volumeMissing }) ? DataDirStatus.volumeMissing
                : active.contains(where: { $0.status == DataDirStatus.waitingForUnlock }) ? DataDirStatus.waitingForUnlock
                : active.allSatisfy({ $0.status == DataDirStatus.mounted }) ? DataDirStatus.mounted : DataDirStatus.pendingMount
            if let index { result[index] = item } else { result.append(item) }
        }
        return result
    }
}
