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
    enum Mode: String, CaseIterable, Sendable {
        case whole
        case split
        case filesAndVideos

        var splitGroup: PartialWeChatMigrationPolicy.SplitGroup? {
            switch self {
            case .whole: return nil
            case .split: return .media
            case .filesAndVideos: return .filesAndVideos
            }
        }

        var isSplit: Bool { splitGroup != nil }
    }

    enum State: Equatable { case local, whole, split, filesAndVideos, conflict }

    struct Sizing: Sendable {
        let total: DirectorySizeResult
        let media: DirectorySizeResult
        let filesAndVideos: DirectorySizeResult
        let filesAndVideosCount: Int
        var retainedBytes: Int64 { max(0, total.bytes - media.bytes) }
        var isComplete: Bool { total.isComplete && media.isComplete }
        var isFilesAndVideosComplete: Bool { total.isComplete && filesAndVideos.isComplete && filesAndVideosCount > 0 }
    }

    enum Failure: LocalizedError {
        case invalidAccount, disabled, restoreFirst, missingMembers, missingFilesAndVideos, incompleteSize
        var errorDescription: String? {
            switch self {
            case .invalidAccount: return "无法确认微信账号目录，未改动数据。".localized
            case .disabled: return "请先开启“微信账号拆分迁移”。".localized
            case .restoreFirst: return "请先完整还原这个账号已迁移的数据，再切换迁移方式。".localized
            case .missingMembers: return "账号下的 msg 和 business 必须都是可读取的真实目录，才能拆分迁移。".localized
            case .missingFilesAndVideos: return "未在账号下找到可迁移的 msg/file 或 msg/video 目录。".localized
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
        let mediaMembers = Set(policy.members(of: account, group: .media).map(\.path))
        let coldMembers = Set(policy.members(of: account, group: .filesAndVideos).map(\.path))
        let whole = paths.contains(root)
        let mediaSplit = paths.contains { mediaMembers.contains($0) }
        let coldSplit = paths.contains { coldMembers.contains($0) }
        let activeCount = [whole, mediaSplit, coldSplit].filter { $0 }.count
        if activeCount > 1 { return .conflict }
        if whole { return .whole }
        if mediaSplit { return .split }
        if coldSplit { return .filesAndVideos }
        return .local
    }

    func measure(_ account: URL) throws -> Sizing {
        try requireAccount(account)
        let accountDevice = try SignatureSnapshot.info(at: account).st_dev
        let mediaMembers = policy.members(of: account, group: .media)
        let existingCold = policy.existingDirectoryMembers(of: account, group: .filesAndVideos)

        var singlePassSubtrees: Set<URL> = []
        var standaloneMedia: [URL] = []
        var standaloneCold: [URL] = []
        var media = DirectorySizeResult()

        for member in mediaMembers {
            var info = stat()
            if lstat(member.path, &info) != 0 {
                media.readIssues.append(.init(url: member, error: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
            } else if (info.st_mode & S_IFMT) == S_IFDIR && info.st_dev == accountDevice {
                singlePassSubtrees.insert(member.standardizedFileURL)
            } else {
                standaloneMedia.append(member)
            }
        }

        for member in existingCold {
            var info = stat()
            if lstat(member.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_dev == accountDevice {
                singlePassSubtrees.insert(member.standardizedFileURL)
            } else {
                standaloneCold.append(member)
            }
        }

        let singlePass = DirectorySizeTraversal.measure(at: account, subtrees: singlePassSubtrees)
        let total = singlePass.root

        for member in mediaMembers {
            let key = member.standardizedFileURL
            if singlePassSubtrees.contains(key), let result = singlePass.subtrees[key] {
                media.bytes += result.bytes
                media.readIssues += result.readIssues
            }
        }
        for member in standaloneMedia {
            let result = measureDirectorySize(at: member, useCache: false)
            media.bytes += result.bytes
            media.readIssues += result.readIssues
        }

        var cold = DirectorySizeResult()
        for member in existingCold {
            let key = member.standardizedFileURL
            if singlePassSubtrees.contains(key), let result = singlePass.subtrees[key] {
                cold.bytes += result.bytes
                cold.readIssues += result.readIssues
            }
        }
        for member in standaloneCold {
            let result = measureDirectorySize(at: member, useCache: false)
            cold.bytes += result.bytes
            cold.readIssues += result.readIssues
        }
        return Sizing(total: total, media: media, filesAndVideos: cold, filesAndVideosCount: existingCold.count)
    }

    func plannedMembers(of account: URL, for mode: Mode) throws -> [URL] {
        guard let group = mode.splitGroup else { return [account] }
        switch group {
        case .media:
            return policy.members(of: account, group: .media)
        case .filesAndVideos:
            let records = (try? store.recordsStrict()) ?? []
            let transfers = (try? store.transfers()) ?? []
            let recordedPaths = Set(
                records.map(\.mountPointPath)
                    + transfers.filter { $0.rollbackCompletedAt == nil }.map(\.originalPath)
            )
            let candidates = policy.members(of: account, group: .filesAndVideos).filter { url in
                if recordedPaths.contains(url.path) { return true }
                var info = stat()
                return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            }
            return candidates
        }
    }

    /// The caller owns the application operation and cross-process locks for the whole group.
    func migrate(account: URL, mode: Mode, externalRoot: URL, appName: String,
                 preverifiedSources: Set<String> = [],
                 progress: FileCopier.ProgressHandler? = nil) async throws -> [String] {
        if DataTransferSession.current == nil {
            return try await DataTransferSession.run {
                try await migrate(account: account, mode: mode, externalRoot: externalRoot, appName: appName,
                                  preverifiedSources: preverifiedSources, progress: progress)
            }
        }
        try requireAccount(account)
        let current = try state(of: account)
        let allowedCurrentState: Bool = {
            switch mode {
            case .whole: return current == .local
            case .split: return current == .local || current == .split
            case .filesAndVideos: return current == .local || current == .filesAndVideos
            }
        }()
        guard current != .conflict, allowedCurrentState else { throw Failure.restoreFirst }
        if mode.isSplit, !enabled { throw Failure.disabled }
        let members = try plannedMembers(of: account, for: mode)
        if mode == .filesAndVideos, members.isEmpty {
            throw Failure.missingFilesAndVideos
        }
        // Validate all target members before moving any of them. Existing mount records
        // belong to an interrupted split and are resumed rather than migrated again.
        let records = try store.recordsStrict()
        let transfers = try store.transfers()
        // A committed switch is represented by the live mount records. The
        // recovery mount on a completed restore only identifies its old copy.
        let previousMounts = records + transfers.filter { !$0.isDataSwitchComplete }.compactMap(\.recoveryMountRecord)
        if mode.isSplit, previousMounts.contains(where: {
            members.map(\.path).contains($0.mountPointPath)
                && URL(fileURLWithPath: $0.externalRootPath).standardizedFileURL.path != externalRoot.standardizedFileURL.path
        }) { throw Failure.restoreFirst }
        for source in members {
            let hasRecord = records.contains { $0.mountPointPath == source.path }
                || transfers.contains { $0.originalPath == source.path && $0.rollbackCompletedAt == nil }
            if hasRecord { continue }
            let info = try SignatureSnapshot.info(at: source)
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw mode == .filesAndVideos ? Failure.missingFilesAndVideos : Failure.missingMembers
            }
            let safety = DataOperationSafety(homeDirectory: policy.homeDirectory, store: store,
                                            partialWeChatMigrationEnabled: enabled, weChatContainerIdentifier: policy.containerIdentifier)
            try safety.requirePolicy(at: source)
            try safety.requireNoOverlap(at: source)
            try safety.requireNoManagedFileSystemAncestor(at: source)
            try safety.requireNoManagedDescendants(at: source)
            if !preverifiedSources.contains(source.standardizedFileURL.path) {
                guard measureDirectorySize(at: source, useCache: false).isComplete else { throw Failure.incompleteSize }
            }
        }
        var warnings: [String] = []
        if members.count > 1, let dataProgress = DataTransferSession.progress, dataProgress.snapshot().unitCount <= 1 {
            dataProgress.configureUnits(members)
        }
        for source in members {
            try Task.checkCancellation()
            DataTransferSession.progress?.setDirectory(source)
            if let record = try store.recordsStrict().first(where: { $0.mountPointPath == source.path }) {
                guard mode.isSplit else { throw Failure.restoreFirst }
                try await migrator.mount(record: record)
                continue
            }
            let item = DataDirItem(name: PartialWeChatMigrationPolicy.displayMemberLabel(for: source), path: source,
                                   type: .containers, priority: .critical, description: "微信账号数据".localized)
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
        let mediaMembers = policy.members(of: account, group: .media)
        let coldMembers = policy.members(of: account, group: .filesAndVideos)
        let allTransfers = try store.transfers()
        let mediaRolledBack = allTransfers.filter {
            $0.mode == .mount && Set(mediaMembers.map(\.path)).contains($0.originalPath) && $0.rollbackCompletedAt != nil
        }
        let coldRolledBack = allTransfers.filter {
            $0.mode == .mount && Set(coldMembers.map(\.path)).contains($0.originalPath) && $0.rollbackCompletedAt != nil
        }
        let members: [URL]
        let rolledBack: [DataTransferRecord]
        switch current {
        case .split:
            members = mediaMembers
            rolledBack = mediaRolledBack
        case .filesAndVideos:
            members = coldMembers
            rolledBack = coldRolledBack
        case .local where !mediaRolledBack.isEmpty && coldRolledBack.isEmpty:
            members = mediaMembers
            rolledBack = mediaRolledBack
        case .local where !coldRolledBack.isEmpty && mediaRolledBack.isEmpty:
            members = coldMembers
            rolledBack = coldRolledBack
        default:
            throw Failure.restoreFirst
        }
        var warnings: [String] = []
        if let dataProgress = DataTransferSession.progress, dataProgress.snapshot().unitCount <= 1 {
            var activeUnits: [URL] = []
            var seenPaths: Set<String> = []
            for url in rolledBack.map({ URL(fileURLWithPath: $0.originalPath) }) + members {
                let path = url.standardizedFileURL.path
                if seenPaths.insert(path).inserted {
                    activeUnits.append(url)
                }
            }
            if activeUnits.count > 1 {
                dataProgress.configureUnits(activeUnits)
            }
        }
        for transfer in rolledBack {
            try Task.checkCancellation()
            DataTransferSession.progress?.setDirectory(URL(fileURLWithPath: transfer.originalPath))
            if let warning = try await migrator.resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: progress) {
                warnings.append(warning)
            }
        }
        for source in members {
            try Task.checkCancellation()
            DataTransferSession.progress?.setDirectory(source)
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
                let estimatedBytes = DiskUtility.isMountPoint(source) ? measureDirectorySize(at: source, useCache: false).bytes : 0
                if let warning = try await migrator.restoreAndComplete(record: record, estimatedTotalBytes: estimatedBytes, progressHandler: progress) {
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
    /// never independent checkboxes/buttons for split members.
    static func groupedItems(_ items: [DataDirItem], homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
                             splitMode: Bool = false,
                             preferredSplitGroup: PartialWeChatMigrationPolicy.SplitGroup? = nil,
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
            let account = URL(fileURLWithPath: path)
            let mediaChildren = children.filter { policy.splitGroup(forMember: $0.path) == .media }
            let coldChildren = children.filter { policy.splitGroup(forMember: $0.path) == .filesAndVideos }
            let hasRecordedMedia = mediaChildren.contains { $0.hasMountTransferRecord || DataDirStatus.mountStatuses.contains($0.status) || $0.recoveryOperationID != nil }
            let hasRecordedCold = coldChildren.contains { $0.hasMountTransferRecord || DataDirStatus.mountStatuses.contains($0.status) || $0.recoveryOperationID != nil }
            // Never mix overlapping `msg` and `msg/{file,video}` members on the same account row.
            if hasRecordedMedia && hasRecordedCold { continue }

            let targetGroup: PartialWeChatMigrationPolicy.SplitGroup = hasRecordedCold ? .filesAndVideos
                : hasRecordedMedia ? .media
                : (preferredSplitGroup ?? .media)
            let groupChildren = targetGroup == .filesAndVideos ? coldChildren : mediaChildren
            let active = groupChildren.filter { (splitMode && $0.status == DataDirStatus.local && $0.isMigratable)
                || $0.canRestore || $0.recoveryOperationID != nil }
            guard !active.isEmpty else { continue }

            let expectedCount: Int = {
                switch targetGroup {
                case .media:
                    return PartialWeChatMigrationPolicy.memberNames.count
                case .filesAndVideos:
                    let existingPaths = Set(policy.existingDirectoryMembers(of: account, group: .filesAndVideos).map(\.path))
                    let recordedPaths = Set(active.map { $0.path.standardizedFileURL.path })
                    return max(1, existingPaths.union(recordedPaths).count)
                }
            }()

            let index = result.firstIndex { $0.path.standardizedFileURL.path == account.path }
            var item = index.map { result[$0] } ?? DataDirItem(name: account.lastPathComponent, path: account,
                type: .containers, priority: .critical, description: "微信账号数据".localized)
            let localPreview = splitMode && active.count == expectedCount
                && active.allSatisfy { $0.status == DataDirStatus.local && !$0.hasMountTransferRecord && $0.recoveryOperationID == nil }
                && item.isMigratable
            let restored = active.contains { $0.hasCompletedRestore } && active.allSatisfy {
                $0.status == DataDirStatus.local && ($0.hasCompletedRestore || (!$0.hasMountTransferRecord && $0.recoveryOperationID == nil))
            }
            if !localPreview && active.allSatisfy({ $0.status == DataDirStatus.local && !$0.hasMountTransferRecord && $0.recoveryOperationID == nil }) {
                continue
            }
            item.weChatSplitMembers = active
            item.weChatExpectedMemberCount = expectedCount
            item.autoMountPaused = active.contains { $0.autoMountPaused }
            item.description = targetGroup == .filesAndVideos
                ? "微信账号 · 拆分迁移（msg/file + msg/video）".localized
                : "微信账号 · 拆分迁移（msg + business）".localized
            item.isMigratable = localPreview || (restored && splitMode && targetGroup == .media
                && active.count == expectedCount && active.allSatisfy(\.isMigratable) && item.isMigratable)
            item.hasMountTransferRecord = !localPreview
            item.status = localPreview ? DataDirStatus.local
                : restored ? DataDirStatus.restored
                : active.contains(where: { $0.status == DataDirStatus.local }) ? DataDirStatus.pendingCompletion
                : active.contains(where: { $0.status == DataDirStatus.volumeMissing }) ? DataDirStatus.volumeMissing
                : active.contains(where: { $0.status == DataDirStatus.waitingForUnlock }) ? DataDirStatus.waitingForUnlock
                : (active.count == expectedCount && active.allSatisfy({ $0.status == DataDirStatus.mounted })) ? DataDirStatus.mounted : DataDirStatus.pendingMount
            if let index { result[index] = item } else { result.append(item) }
        }
        return result
    }
}
