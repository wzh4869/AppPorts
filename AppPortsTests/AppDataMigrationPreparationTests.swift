import XCTest
@testable import AppPorts

final class AppDataMigrationPreparationTests: XCTestCase {
    private func item(_ path: String = "/fixture/data") -> DataDirItem {
        var item = DataDirItem(name: "Data", path: URL(fileURLWithPath: path), type: .applicationSupport,
                               priority: .critical, description: "", isMigratable: true)
        item.status = DataDirStatus.local
        item.applySize(.init(bytes: 1))
        return item
    }

    func testPreparationReturnsFreshMetadataAndMeasuresTheSelectedDirectory() throws {
        let original = item()
        var fresh = item()
        fresh.associatedBundleIdentifier = "com.example.fresh"
        var measuredPaths: [URL] = []
        let result = try AppDataMigrationPreparation.refreshedItem(original,
            result: .init(items: [item("/fixture/other"), fresh], readIssues: [])) {
                measuredPaths.append($0.path)
                return .init(bytes: 8192)
            }
        XCTAssertEqual(result.associatedBundleIdentifier, "com.example.fresh")
        XCTAssertEqual(result.sizeBytes, 8192)
        XCTAssertEqual(measuredPaths, [original.path])
        XCTAssertEqual(original.sizeBytes, 1)
    }

    func testMissingOrNewlyProtectedOrMigratedSourcesStopBeforeMeasurement() {
        let original = item()
        var protected = item()
        protected.isMigratable = false
        var moved = item()
        moved.status = DataDirStatus.linked
        for items in [[], [item("/fixture/other")], [protected], [moved]] {
            XCTAssertThrowsError(try AppDataMigrationPreparation.refreshedItem(original,
                result: .init(items: items, readIssues: [])) { _ in
                    XCTFail("An invalid source must not reach measurement or migration")
                    return .init()
                })
        }
    }

    func testChangedSplitMembersCannotExpandTheReservedPaths() {
        let original = item()
        var changed = item()
        changed.weChatSplitMembers = [item("/fixture/data/msg")]
        XCTAssertThrowsError(try AppDataMigrationPreparation.refreshedItem(original,
            result: .init(items: [changed], readIssues: [])) { _ in
                XCTFail("Changed members must not reach measurement")
                return .init()
            })
    }

    func testIncompleteMeasurementCannotAuthorizeMigration() {
        let original = item()
        let issue = DataDirReadIssue(url: original.path,
            error: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue)))
        XCTAssertThrowsError(try AppDataMigrationPreparation.refreshedItem(original,
            result: .init(items: [original], readIssues: [])) { _ in
                .init(bytes: 8192, readIssues: [issue])
            })
    }
}
