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
}
