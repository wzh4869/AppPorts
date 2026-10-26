import XCTest
@testable import AppPorts

final class AppDataScanCacheTests: XCTestCase {
    private func context(name: String = "Example", root: String = "/Volumes/External", revision: UInt64 = 0,
                         splitMode: Bool = false) -> AppDataScanCache.Context {
        .init(app: AppItem(name: name + ".app", path: URL(fileURLWithPath: "/Applications/" + name + ".app"),
                           status: AppStatus.local),
              externalRoot: URL(fileURLWithPath: root), splitMode: splitMode, recordsRevision: revision)
    }

    private func snapshot(_ context: AppDataScanCache.Context) -> AppDataScanCache.Snapshot {
        var item = DataDirItem(name: "Example", path: URL(fileURLWithPath: "/tmp/Example"),
                               type: .applicationSupport, priority: .critical, description: "", isMigratable: true)
        item.applySize(.init(bytes: 4096))
        return .init(context: context, items: [item], readIssues: [], identityIssue: nil,
                     isSandboxed: true, isWeChat: false, containerIdentifier: "com.example.app")
    }

    func testSwitchingApplicationsPreservesBothMeasuredSnapshots() throws {
        var cache = AppDataScanCache()
        let first = context()
        let second = context(name: "Other")
        cache.store(snapshot(first))
        cache.store(snapshot(second))
        let restored = try XCTUnwrap(cache.snapshot(for: first, permission: .granted))
        XCTAssertEqual(restored.items.first?.sizeBytes, 4096)
        XCTAssertTrue(restored.isSandboxed)
        XCTAssertNotNil(cache.snapshot(for: second, permission: .granted))
    }

    func testUnavailablePermissionCannotReturnCachedData() {
        var cache = AppDataScanCache()
        cache.store(snapshot(context()))
        XCTAssertNil(cache.snapshot(for: context(), permission: .denied))
        XCTAssertNil(cache.snapshot(for: context(), permission: .unknown))
    }

    func testChangedDestinationRecordsOrGroupingCannotReuseSnapshot() {
        var cache = AppDataScanCache()
        cache.store(snapshot(context()))
        XCTAssertNil(cache.snapshot(for: context(root: "/Volumes/Other"), permission: .granted))
        XCTAssertNil(cache.snapshot(for: context(revision: 1), permission: .granted))
        XCTAssertNil(cache.snapshot(for: context(splitMode: true), permission: .granted))
    }

    func testExplicitInvalidationAndReadFailuresRemoveCachedResults() {
        var cache = AppDataScanCache()
        let original = snapshot(context())
        cache.store(original)
        cache.removeAll()
        XCTAssertNil(cache.snapshot(for: context(), permission: .granted))
        cache.store(original)
        var incomplete = original
        incomplete.readIssues = [.init(url: URL(fileURLWithPath: "/tmp/Example"),
            error: NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue))]
        cache.store(incomplete)
        XCTAssertNil(cache.snapshot(for: context(), permission: .granted))
    }
}
