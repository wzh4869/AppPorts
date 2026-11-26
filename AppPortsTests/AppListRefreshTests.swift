import Foundation
import Testing
@testable import AppPorts

@MainActor
struct AppListRefreshTests {
    @Test func unavailableModificationDateDoesNotValidateCache() {
        let app = AppItem(name: "Missing.app", path: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Missing.app"), status: AppStatus.local)
        let view = ContentView()
        let cache = [app.id: ContentView.CachedAppSize(size: "1 KB", bytes: 1024, mtime: nil)]
        let result = view.fillCachedSizes(into: [app], cache: cache)
        #expect(result.misses.count == 1)
        #expect(result.filled.first?.size == nil)
    }

    @Test func emptyListOmitsHeaderSizeSummary() {
        let summary = AppListDisplaySizeSummary(apps: [])
        #expect(summary.itemCount == 0)
        #expect(summary.bytes == 0)
        #expect(!summary.isCalculating)
        #expect(summary.headerText == nil)
    }

    @Test func allPendingAppsShowCalculatingText() {
        let apps = [
            AppItem(name: "A.app", path: URL(fileURLWithPath: "/Volumes/Ext/A.app"), status: AppStatus.linked),
            AppItem(name: "B.app", path: URL(fileURLWithPath: "/Volumes/Ext/B.app"), status: AppStatus.unlinked)
        ]
        let summary = AppListDisplaySizeSummary(apps: apps)
        #expect(summary.itemCount == 2)
        #expect(summary.bytes == 0)
        #expect(summary.isCalculating)
        #expect(summary.headerText == "计算中...".localized)
    }

    @Test func partialMeasurementShowsAccumulatedBytesWithCalculatingSuffix() {
        let measured = AppItem(
            name: "A.app",
            path: URL(fileURLWithPath: "/Volumes/Ext/A.app"),
            status: AppStatus.linked,
            size: "10 MB",
            sizeBytes: 10_000_000
        )
        let pending = AppItem(
            name: "B.app",
            path: URL(fileURLWithPath: "/Volumes/Ext/B.app"),
            status: AppStatus.unlinked
        )
        let summary = AppListDisplaySizeSummary(apps: [measured, pending])
        #expect(summary.itemCount == 2)
        #expect(summary.bytes == 10_000_000)
        #expect(summary.isCalculating)
        #expect(summary.headerText == LocalizedByteCountFormatter.string(fromByteCount: 10_000_000) + "（统计中）".localized)
    }

    @Test func completedAppsSumUniqueIDsOnly() {
        let first = AppItem(
            name: "A.app",
            path: URL(fileURLWithPath: "/Volumes/Ext/A.app"),
            status: AppStatus.linked,
            size: "10 MB",
            sizeBytes: 10_000_000
        )
        let duplicate = AppItem(
            name: "A.app",
            path: URL(fileURLWithPath: "/Volumes/Ext/A.app"),
            status: AppStatus.linked,
            size: "10 MB",
            sizeBytes: 10_000_000
        )
        let second = AppItem(
            name: "B.app",
            path: URL(fileURLWithPath: "/Volumes/Ext/B.app"),
            status: AppStatus.unlinked,
            size: "25 MB",
            sizeBytes: 25_000_000
        )
        let summary = AppListDisplaySizeSummary(apps: [first, duplicate, second])
        #expect(summary.itemCount == 2)
        #expect(summary.bytes == 35_000_000)
        #expect(!summary.isCalculating)
        #expect(summary.headerText == LocalizedByteCountFormatter.string(fromByteCount: 35_000_000))
    }
}

@MainActor
struct AppSizeRefreshTests {
    @Test(arguments: [true, false])
    func manualRefreshRemeasuresNestedChanges(isLocal: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppSizeRefresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Fixture.app")
        let payload = appURL.appendingPathComponent("Contents/Resources/payload.dat")
        try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: payload)
        let app = AppItem(name: "Fixture.app", path: appURL, status: AppStatus.local)
        let view = ContentView()
        let scanner = AppScanner()
        let oldBytes = await scanner.calculateDisplayedSize(for: app, isLocalEntry: isLocal)
        let oldMtime = try #require(view.bundleModificationDate(for: app))
        let cache = [app.id: ContentView.CachedAppSize(size: "previous", bytes: oldBytes, mtime: oldMtime)]

        try Data(repeating: 2, count: 8192).write(to: payload)
        #expect(view.bundleModificationDate(for: app) == oldMtime)
        let automatic = view.fillCachedSizes(into: [app], cache: cache, isLocal: isLocal)
        #expect(automatic.misses.isEmpty)
        let manual = view.fillCachedSizes(into: [app], cache: cache, isLocal: isLocal, forceRefresh: true)
        #expect(manual.filled.first?.sizeBytes == oldBytes) // No flicker while remeasuring.
        let miss = try #require(manual.misses.first)
        let newBytes = await scanner.calculateDisplayedSize(for: miss.app, isLocalEntry: isLocal)
        #expect(newBytes - oldBytes == 7168)
    }

    @Test func changedBundleDateInvalidatesAutomaticCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppSizeRefresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppItem(name: "Fixture.app", path: root, status: AppStatus.local)
        let cache = [app.id: ContentView.CachedAppSize(size: "previous", bytes: 1024, mtime: .distantPast)]
        let result = ContentView().fillCachedSizes(into: [app], cache: cache)
        #expect(result.misses.count == 1)
        #expect(result.filled.first?.size == nil)
    }

    @Test(arguments: [true, false])
    func linkedLocalSizeCannotBeReusedAsContentSize(cachedPortal: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppSizeRefresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppItem(name: "Fixture.app", path: root, status: AppStatus.linked)
        let view = ContentView()
        let cache = [app.id: ContentView.CachedAppSize(size: "previous", bytes: 123,
            mtime: view.bundleModificationDate(for: app), isLocalPortal: cachedPortal)]
        let differentMode = view.fillCachedSizes(into: [app], cache: cache, isLocal: !cachedPortal)
        #expect(differentMode.misses.count == 1)
        #expect(differentMode.filled.first?.size == nil)
        let sameMode = view.fillCachedSizes(into: [app], cache: cache, isLocal: cachedPortal)
        #expect(sameMode.misses.isEmpty)
        #expect(sameMode.filled.first?.sizeBytes == 123)
    }
}

struct AppListScanStateTests {
    private let external = URL(fileURLWithPath: "/Volumes/Test/Apps")

    @Test func supersededFinishedAndHiddenPanesIgnoreLatePreviewBatches() throws {
        var state = AppListScanState()
        let firstResult = state.begin(externalDirectory: external, customPaths: [])
        let first = try #require(firstResult)
        let row = AppItem(name: "Sample.app", path: external.appendingPathComponent("Sample.app"), status: AppStatus.local)
        state.publishPreview([row], for: first)
        #expect(state.preview == [row])
        let secondResult = state.begin(externalDirectory: nil, customPaths: [])
        let second = try #require(secondResult)
        state.publishPreview([row], for: first)
        #expect(state.preview.isEmpty)
        state.finish(second)
        state.publishPreview([row], for: second)
        #expect(state.preview.isEmpty)
        let thirdResult = state.begin(externalDirectory: external, customPaths: [])
        let third = try #require(thirdResult)
        state.invalidate()
        state.publishPreview([row], for: third)
        #expect(state.preview.isEmpty)
    }

    @Test func repeatedManualRefreshDoesNotStartCompetingScan() throws {
        var state = AppListScanState()
        let firstResult = state.begin(externalDirectory: external, customPaths: [], isManual: true)
        let first = try #require(firstResult)
        #expect(state.isScanning)
        let duplicate = state.begin(externalDirectory: external, customPaths: [], isManual: true)
        #expect(duplicate == nil)
        #expect(state.request == first)
        state.finish(first)
        #expect(!state.isScanning)
        let next = state.begin(externalDirectory: external, customPaths: [], isManual: true)
        #expect(next != nil)
    }

    @Test func supersedingScanInheritsRemeasurementAndRejectsOldCompletion() throws {
        var state = AppListScanState()
        let firstResult = state.begin(externalDirectory: external, customPaths: [], isManual: true)
        let first = try #require(firstResult)
        let nextResult = state.begin(externalDirectory: external, customPaths: ["/custom"])
        let next = try #require(nextResult)
        #expect(next.forceSizeRefresh)
        state.finish(first)
        #expect(state.isScanning)
        #expect(state.request == next)
        state.finish(next)
        #expect(!state.isScanning)
        let laterResult = state.begin(externalDirectory: external, customPaths: ["/custom"])
        let later = try #require(laterResult)
        #expect(!later.forceSizeRefresh)
    }

    @Test func disappearanceInvalidatesOldRequestAndPreservesPendingRefresh() throws {
        var state = AppListScanState()
        let oldResult = state.begin(externalDirectory: external, customPaths: [], isManual: true)
        let old = try #require(oldResult)
        state.invalidate()
        #expect(!state.isScanning)
        #expect(state.request == nil)
        let currentResult = state.begin(externalDirectory: nil, customPaths: [])
        let current = try #require(currentResult)
        state.finish(old)
        #expect(state.isScanning)
        #expect(current.forceSizeRefresh)
        state.finish(current)
        #expect(!state.isScanning)
    }

    @Test func panesFinishIndependentlyEvenWhenOneHasNoDirectory() throws {
        var local = AppListScanState()
        var externalState = AppListScanState()
        let localRequestResult = local.begin(externalDirectory: nil, customPaths: [])
        let localRequest = try #require(localRequestResult)
        let externalRequestResult = externalState.begin(externalDirectory: nil, customPaths: [])
        let externalRequest = try #require(externalRequestResult)
        externalState.finish(externalRequest)
        #expect(!externalState.isScanning)
        #expect(local.isScanning)
        local.finish(localRequest)
        #expect(!local.isScanning)
        #expect(local.request == localRequest) // Completion must not look like missing initialization.
    }

    @Test func cancelInFlightStopsProgressWithoutResettingInitialization() throws {
        var state = AppListScanState()
        state.cancelInFlight()
        #expect(state.request == nil)
        #expect(!state.isScanning)

        let activeResult = state.begin(externalDirectory: external, customPaths: [], isManual: true)
        let active = try #require(activeResult)
        let row = AppItem(name: "Sample.app", path: external.appendingPathComponent("Sample.app"), status: AppStatus.external)
        state.publishPreview([row], for: active)
        #expect(state.isScanning)
        #expect(state.preview == [row])

        state.cancelInFlight()
        #expect(!state.isScanning)
        #expect(state.preview.isEmpty)
        #expect(state.request != nil)
        #expect(state.request != active)

        // Late preview or completion from the cancelled request must be ignored.
        state.publishPreview([row], for: active)
        #expect(state.preview.isEmpty)
        state.finish(active)
        #expect(!state.isScanning)
        #expect(state.request != nil)
    }
}

@MainActor
struct AppListRestoreTests {
    @Test func reopenUsesOnlyDisplayFieldsAndTheMatchingDirectoryAndVolume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AppListCacheStore.Source([root])
        #expect(source.isIdentified)
        let store = AppListCacheStore(directory: root)
        let path = root.appendingPathComponent("Container")
        let bundle = path.appendingPathComponent("Utility.app")
        let app = AppItem(name: "Container", path: path, bundleURL: bundle, status: AppStatus.linked,
                          isRunning: true, signatureReplaced: true, updateRoute: .independent)
        let sizes = [app.id: AppSizeCacheStore.Entry(size: "24 KB", bytes: 24000, mtime: nil, isLocalPortal: true)]
        #expect(store.load(.local, source: source, sizes: sizes).isEmpty)
        store.save([app], pane: .local, source: source, context: .init(guardian: .ready))
        store.save([app], pane: .external, source: source, context: .init(guardian: .ready))
        // The serial read also waits for both preceding writes.
        #expect(store.load(.external, source: source, sizes: sizes).first?.size == nil)

        let reopened = AppListCacheStore(directory: root)
        let restored = try #require(reopened.load(.local, source: source, sizes: sizes).first)
        #expect(restored.displayName == "Utility.app" && restored.id == app.id)
        #expect(restored.sizeBytes == 24000 && restored.size == "24 KB")
        #expect(!restored.isRunning && !restored.signatureReplaced && restored.updateRoute == .unknown)
        #expect(restored.cachedBadgeLayout == AppBadgeLayout(app: app, context: .init(guardian: .ready)))
        let changedPaths = AppListCacheStore.Source([root, root.deletingLastPathComponent()])
        #expect(reopened.load(.local, source: changedPaths, sizes: sizes).isEmpty)

        let file = root.appendingPathComponent("app-list-local.json")
        let data = try Data(contentsOf: file)
        // Version 1 files written before badge layout was added still restore names and sizes.
        var oldSnapshot = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var oldRows = try #require(oldSnapshot["rows"] as? [[String: Any]])
        oldRows[0].removeValue(forKey: "badgeLayout")
        oldSnapshot["rows"] = oldRows
        try JSONSerialization.data(withJSONObject: oldSnapshot).write(to: file)
        let legacy = try #require(AppListCacheStore(directory: root).load(.local, source: source, sizes: sizes).first)
        #expect(legacy.cachedBadgeLayout == nil && legacy.displayName == restored.displayName && legacy.sizeBytes == 24000)

        let uuid = try #require(source.directories.first?.volumeUUID)
        let otherVolume = String(decoding: data, as: UTF8.self).replacingOccurrences(of: uuid, with: UUID().uuidString)
        try Data(otherVolume.utf8).write(to: file)
        #expect(AppListCacheStore(directory: root).load(.local, source: source, sizes: sizes).isEmpty)
        try Data("incomplete".utf8).write(to: file)
        #expect(AppListCacheStore(directory: root).load(.local, source: source, sizes: sizes).isEmpty)
    }

    @Test func discoveryMergesNewRowsAndKeepsMissingRowsUntilThePaneIsConfirmed() throws {
        let root = FileManager.default.temporaryDirectory
        let source = AppListCacheStore.Source([root])
        func row(_ name: String) -> AppItem {
            AppItem(name: name, path: root.appendingPathComponent(name), status: AppStatus.local)
        }
        let a = row("A.app"), b = row("B.app"), c = row("C.app")
        var state = AppListScanState()
        state.changeSource(to: source) { [a, b] }
        let requestResult = state.begin(externalDirectory: nil, customPaths: [])
        let request = try #require(requestResult)
        #expect(state.preview == [a, b] && state.pendingIDs == [a.id, b.id])
        var liveB = b
        liveB.isRunning = true
        state.publishPreview([liveB, c], for: request)
        var verifiedA = a
        verifiedA.bundleIsLocked = true
        state.publishCachedUpdates([a.id: verifiedA, b.id: b], for: request)
        #expect(state.preview.contains(verifiedA) && state.preview.contains(liveB))
        state.publishPreview([liveB, c], for: request)
        #expect(state.preview.contains(verifiedA))
        #expect(Set(state.preview.map(\.id)) == [a.id, b.id, c.id])
        #expect(state.pendingIDs == [a.id] && state.preview.contains(liveB))
        state.finish(request)
        #expect(state.preview.isEmpty && state.pendingIDs.isEmpty)

        let staleResult = state.begin(externalDirectory: nil, customPaths: [])
        let stale = try #require(staleResult)
        state.changeSource(to: AppListCacheStore.Source([root.deletingLastPathComponent()])) { [a] }
        state.publishPreview([b], for: stale)
        #expect(state.preview.isEmpty && state.pendingIDs.isEmpty)
    }

    @Test func persistedSortModesPreserveDirectionAndColumnDefaults() throws {
        let view = ContentView()
        let a = AppItem(name: "A.app", path: URL(fileURLWithPath: "/A.app"), status: AppStatus.local, sizeBytes: 2)
        let z = AppItem(name: "Z.app", path: URL(fileURLWithPath: "/Z.app"), status: AppStatus.local, sizeBytes: 5)
        var sort = ContentView.AppListSort.nameAscending
        sort.select(.size)
        #expect(sort == .sizeDescending)
        let restored = try #require(ContentView.AppListSort(rawValue: sort.rawValue))
        #expect(view.sortApps([a, z], sorting: restored) == [z, a])
        sort.select(.size)
        #expect(sort == .sizeAscending)
        sort.select(.name)
        #expect(sort == .nameAscending)
        sort.select(.name)
        #expect(sort == .nameDescending)
    }
}
