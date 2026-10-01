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
}
