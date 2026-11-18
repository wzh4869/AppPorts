import Foundation
import XCTest
@testable import AppPorts

final class ReadinessCheckModelTests: XCTestCase {
    @MainActor
    func testRefreshPublishesProductionCheckerResultsAndPermissionReport() async throws {
        let checker = LaunchReadinessChecker(probe: .init(fullDiskAccessState: { .denied },
            appManagementState: { .granted }, externalDrivePath: { "/fixture/external" }, externalDriveState: { _ in .apfs }))
        var reported: [LaunchReadinessChecker.Item] = []
        let model = ReadinessCheckModel(checker: checker, didCheck: { reported = $0 })
        model.refresh()
        XCTAssertTrue(model.isChecking)
        let deadline = Date().addingTimeInterval(2)
        while model.isChecking, Date() < deadline { await Task.yield() }
        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(model.items.count, 3)
        XCTAssertEqual(model.items.first { $0.id == LaunchReadinessChecker.ItemID.fullDiskAccess }?.level, .failed)
        XCTAssertEqual(model.items.first { $0.id == LaunchReadinessChecker.ItemID.appManagement }?.level, .ok)
        XCTAssertEqual(model.items.first { $0.id == LaunchReadinessChecker.ItemID.externalDrive }?.level, .ok)
        XCTAssertEqual(reported, model.items)
    }

    @MainActor
    func testRefreshQueuedWhileCheckingRerunsFollowUpCheck() async throws {
        let calls = Counter()
        let checker = LaunchReadinessChecker(probe: .init(
            fullDiskAccessState: {
                let n = calls.increment()
                return n == 1 ? .denied : .granted
            },
            appManagementState: { .granted },
            externalDrivePath: { "/fixture/external" },
            externalDriveState: { _ in .apfs }
        ))
        let model = ReadinessCheckModel(checker: checker, didCheck: { _ in })
        model.refresh()
        XCTAssertTrue(model.isChecking)
        model.refresh()
        let deadline = Date().addingTimeInterval(2)
        while model.isChecking, Date() < deadline { await Task.yield() }
        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(model.items.first { $0.id == LaunchReadinessChecker.ItemID.fullDiskAccess }?.level, .ok)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}
