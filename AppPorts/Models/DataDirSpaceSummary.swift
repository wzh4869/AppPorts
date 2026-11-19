import Foundation

/// 只统计可从本地迁出的目录；父子目录和已挂载到外置盘的数据不能重复计入。
struct DataDirSpaceSummary {
    let reclaimableBytes: Int64
    let isCalculating: Bool
    let isIncomplete: Bool

    init(items: [DataDirItem], allItems: [DataDirItem], hasReadIssues: Bool = false, hasIdentityIssue: Bool = false) {
        let nonLocalItems = allItems.filter { $0.status != DataDirStatus.local }
        let candidates = items.filter { item in
            item.status == DataDirStatus.local && item.isMigratable
                && !nonLocalItems.contains { Self.isDescendant(item, of: $0) }
        }
        let roots = Self.outermost(candidates)
        // DirectoryEnumerator 不跨挂载卷，也不跟随软链，父项的测量已经排除了外置子目录。
        reclaimableBytes = roots.reduce(0) { $0 + $1.sizeBytes }
        isCalculating = roots.contains { $0.size == nil }
        isIncomplete = hasReadIssues || hasIdentityIssue || roots.contains { $0.sizeIsIncomplete }
    }

    private static func isDescendant(_ item: DataDirItem, of ancestor: DataDirItem) -> Bool {
        item.id.hasPrefix(ancestor.id == "/" ? "/" : ancestor.id + "/") && item.id != ancestor.id
    }

    private static func outermost(_ items: [DataDirItem]) -> [DataDirItem] {
        var seen = Set<String>()
        let uniqueItems = items.filter { seen.insert($0.id).inserted }
        return uniqueItems.filter { item in
            !uniqueItems.contains { isDescendant(item, of: $0) }
        }
    }
}

/// 展示已读取到的目录大小，读取失败时保留可用的部分统计。
struct DataDirDisplaySizeSummary {
    let bytes: Int64
    let isIncomplete: Bool
    let isCalculating: Bool
    let localBytes: Int64
    let migratedBytes: Int64
    let hasMigratedItems: Bool

    static func isMigratedItem(_ item: DataDirItem) -> Bool {
        if DataDirStatus.mountStatuses.contains(item.status)
            || item.status == DataDirStatus.linked
            || item.status == DataDirStatus.needsNormalization
            || item.status == DataDirStatus.pendingRelink
            || item.hasManagedLinkRecord {
            return true
        }
        if !item.weChatSplitMembers.isEmpty {
            return item.weChatSplitMembers.contains(where: isMigratedItem)
        }
        return false
    }

    init(items: [DataDirItem], hasReadIssues: Bool = false) {
        // 父目录统计不跟随软链、不跨挂载卷，外置目标需单独计入。
        let candidates = items.filter { !$0.isUserDirectoryLink }
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.id).inserted }
        let roots = unique.filter { item in
            !unique.contains { parent in
                guard parent.id != item.id,
                      item.id.hasPrefix(parent.id == "/" ? "/" : parent.id + "/") else { return false }
                return item.linkedDestination == nil && !Self.isMigratedItem(item)
                    && parent.linkedDestination == nil && !DataDirStatus.mountStatuses.contains(parent.status)
                    && parent.weChatSplitMembers.isEmpty
            }
        }
        var local: Int64 = 0
        var migrated: Int64 = 0
        var hasMigrated = false
        for root in roots {
            let hasLocalAncestor = unique.contains { parent in
                parent.id != root.id
                    && root.id.hasPrefix(parent.id == "/" ? "/" : parent.id + "/")
                    && parent.linkedDestination == nil
                    && !DataDirStatus.mountStatuses.contains(parent.status)
                    && parent.weChatSplitMembers.isEmpty
            }
            if root.status == DataDirStatus.pendingCompletion,
               !root.weChatSplitMembers.isEmpty,
               hasLocalAncestor,
               root.weChatSplitMembers.allSatisfy({ $0.size != nil }) {
                let migratedMembers = root.weChatSplitMembers.filter(Self.isMigratedItem)
                if !migratedMembers.isEmpty {
                    hasMigrated = true
                    migrated += migratedMembers.reduce(0) { $0 + max(0, $1.sizeBytes) }
                }
                continue
            }
            let rootBytes = max(0, root.sizeBytes)
            if Self.isMigratedItem(root) {
                hasMigrated = true
                migrated += rootBytes
            } else {
                local += rootBytes
            }
        }
        localBytes = local
        migratedBytes = migrated
        bytes = local + migrated
        hasMigratedItems = hasMigrated
        isIncomplete = hasReadIssues || roots.contains { $0.sizeIsIncomplete }
        isCalculating = roots.contains { $0.size == nil }
    }

    var sizeText: String {
        var text = LocalizedByteCountFormatter.string(fromByteCount: bytes)
        if isIncomplete { text += "（统计不完整）".localized }
        else if isCalculating { text += "（统计中）".localized }
        return text
    }
}

/// 左侧应用列表每行的展示大小汇总（已迁移 + 本地）；仅用于界面展示与排序，不参与迁移准入判断。
struct AppDataRowSizeSummary: Equatable, Sendable {
    let localBytes: Int64
    let migratedBytes: Int64
    let hasMigratedItems: Bool
    let isIncomplete: Bool
    let isCalculating: Bool

    var totalBytes: Int64 { localBytes + migratedBytes }

    init(
        localBytes: Int64,
        migratedBytes: Int64,
        hasMigratedItems: Bool,
        isIncomplete: Bool,
        isCalculating: Bool
    ) {
        self.localBytes = max(0, localBytes)
        self.migratedBytes = max(0, migratedBytes)
        self.hasMigratedItems = hasMigratedItems
        self.isIncomplete = isIncomplete
        self.isCalculating = isCalculating
    }

    init(displaySummary: DataDirDisplaySizeSummary) {
        self.localBytes = displaySummary.localBytes
        self.migratedBytes = displaySummary.migratedBytes
        self.hasMigratedItems = displaySummary.hasMigratedItems
        self.isIncomplete = displaySummary.isIncomplete
        self.isCalculating = displaySummary.isCalculating
    }
}

/// 应用数据左侧应用列表排序方式。
enum AppDataAppListSortMode: String, CaseIterable {
    case size = "按大小"
    case defaultOrder = "默认"
    case alphabetical = "按首字母"

    var localizedTitle: String {
        switch self {
        case .size:
            return "按大小".localized
        case .defaultOrder:
            return "默认".localized
        case .alphabetical:
            return "按首字母".localized
        }
    }
}

/// 应用数据左侧应用列表排序器：始终将已迁移应用置顶，并在组内按所选排序规则排列。
enum AppDataAppListSorter {
    static func isPinnedMigrated(
        _ app: AppItem,
        migratedAppDataIDs: Set<String>,
        summaries: [String: AppDataRowSizeSummary]
    ) -> Bool {
        migratedAppDataIDs.contains(app.id) || (summaries[app.id]?.hasMigratedItems == true)
    }

    static func ordered(
        _ apps: [AppItem],
        mode: AppDataAppListSortMode,
        migratedAppDataIDs: Set<String>,
        summaries: [String: AppDataRowSizeSummary]
    ) -> [AppItem] {
        var pinned: [AppItem] = []
        var unpinned: [AppItem] = []
        pinned.reserveCapacity(apps.count)
        unpinned.reserveCapacity(apps.count)
        for app in apps {
            if isPinnedMigrated(app, migratedAppDataIDs: migratedAppDataIDs, summaries: summaries) {
                pinned.append(app)
            } else {
                unpinned.append(app)
            }
        }
        return sortGroup(pinned, mode: mode, summaries: summaries)
            + sortGroup(unpinned, mode: mode, summaries: summaries)
    }

    private static func sortGroup(
        _ apps: [AppItem],
        mode: AppDataAppListSortMode,
        summaries: [String: AppDataRowSizeSummary]
    ) -> [AppItem] {
        switch mode {
        case .defaultOrder:
            return apps
        case .alphabetical:
            return apps.sorted { lhs, rhs in
                let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
            }
        case .size:
            return apps.sorted { lhs, rhs in
                let lhsSummary = summaries[lhs.id]
                let rhsSummary = summaries[rhs.id]
                let lhsRank = bucketRank(for: lhsSummary)
                let rhsRank = bucketRank(for: rhsSummary)
                if lhsRank != rhsRank {
                    return lhsRank > rhsRank
                }
                if lhsRank == 2,
                   let lhsBytes = lhsSummary?.totalBytes,
                   let rhsBytes = rhsSummary?.totalBytes,
                   lhsBytes != rhsBytes {
                    return lhsBytes > rhsBytes
                }
                let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
            }
        }
    }

    private static func bucketRank(for summary: AppDataRowSizeSummary?) -> Int {
        if let summary, summary.totalBytes > 0 { return 2 }
        if summary == nil || summary?.isCalculating == true { return 1 }
        return 0
    }
}
