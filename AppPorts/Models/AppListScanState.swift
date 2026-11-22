import Foundation

/// 单个应用面板的扫描生命周期。请求保留到下次扫描，以便拒绝过期结果。
struct AppListScanState {
    struct Request: Equatable, Sendable {
        let id = UUID()
        let externalDirectory: URL?
        let customPaths: [String]
        let forceSizeRefresh: Bool
    }

    private(set) var request: Request?
    private(set) var isScanning = false
    private(set) var preview: [AppItem] = []
    private(set) var source: AppListCacheStore.Source?
    private var restoredRows: [AppItem] = []
    private(set) var pendingIDs: Set<String> = []
    private var needsSizeRefresh = false

    mutating func changeSource(to next: AppListCacheStore.Source, restore: () -> [AppItem]) {
        let firstOpen = source == nil
        invalidate()
        source = next
        restoredRows = firstOpen ? restore() : []
        resetPreview()
    }

    private mutating func resetPreview() {
        for index in restoredRows.indices where restoredRows[index].bundleIsLocked != nil {
            restoredRows[index].bundleIsLocked = nil
        }
        preview = restoredRows
        pendingIDs = Set(restoredRows.map(\.id))
    }

    mutating func begin(externalDirectory: URL?, customPaths: [String], isManual: Bool = false) -> Request? {
        guard !isManual || !isScanning else { return nil }
        // 监控触发的新扫描可以替代旧扫描，但不能吞掉用户尚未完成的体积刷新。
        needsSizeRefresh = needsSizeRefresh || isManual
        let next = Request(externalDirectory: externalDirectory, customPaths: customPaths,
                           forceSizeRefresh: needsSizeRefresh)
        resetPreview()
        request = next
        isScanning = true
        return next
    }

    mutating func publishPreview(_ apps: [AppItem], for current: Request) {
        guard request == current, isScanning else { return }
        guard !restoredRows.isEmpty else {
            preview = apps
            return
        }
        // 未发现的旧行持续可见，整栏发现结束后才能确认哪些已经移除。
        let discovered = Set(apps.map(\.id))
        let pending = restoredRows.filter { !discovered.contains($0.id) }
        pendingIDs = Set(pending.map(\.id))
        preview = apps + pending
    }

    mutating func publishCachedUpdates(_ verified: [String: AppItem], for current: Request) {
        guard request == current, isScanning, !pendingIDs.isEmpty, !verified.isEmpty else { return }
        for index in restoredRows.indices {
            let id = restoredRows[index].id
            if pendingIDs.contains(id), let row = verified[id] { restoredRows[index] = row }
        }
        for index in preview.indices {
            let id = preview[index].id
            if pendingIDs.contains(id), let row = verified[id] { preview[index] = row }
        }
    }

    mutating func clearPreview() {
        restoredRows.removeAll()
        preview.removeAll()
        pendingIDs.removeAll()
    }

    mutating func finish(_ completed: Request) {
        guard request == completed else { return }
        isScanning = false
        clearPreview()
        needsSizeRefresh = false
    }

    mutating func invalidate() {
        request = nil
        isScanning = false
        clearPreview()
    }
}
