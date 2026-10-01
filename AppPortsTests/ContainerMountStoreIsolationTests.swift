import Foundation
import XCTest
@testable import AppPorts

final class ContainerMountStoreIsolationTests: XCTestCase {
    func testDefaultAndSharedStoresUseTheSameProcessTemporaryDocument() throws {
        // Inspect locations without reading or mutating either document. Even a
        // regression in the default must not make this test touch real records.
        let sharedURL = try storageURL(of: .shared)
        let defaultURL = try storageURL(of: ContainerMountStore())
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let resolved = sharedURL.resolvingSymlinksInPath().path
        XCTAssertTrue(resolved.hasPrefix(temporaryRoot + "/"), "A test host must never use user Application Support records")
        XCTAssertTrue(sharedURL.deletingLastPathComponent().lastPathComponent.hasPrefix(
            "AppPortsTestRecords-\(ProcessInfo.processInfo.processIdentifier)-"))
        XCTAssertEqual(sharedURL.lastPathComponent, "container-mounts.plist")
        XCTAssertEqual(sharedURL, defaultURL, "Default instances in one test host share only its isolated document")
        XCTAssertNotNil(NSClassFromString("XCTestCase"), "Runtime fallback must detect this XCTest host")
    }

    func testExplicitFixtureStoreLocationRemainsIndependentOfTheDefault() throws {
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPortsStoreLocationOnly-\(UUID().uuidString)/records.plist")
        let actual = try storageURL(of: ContainerMountStore(fileURL: expected))
        XCTAssertEqual(actual, expected)
        XCTAssertNotEqual(actual, try storageURL(of: .shared))
    }

    private func storageURL(of store: ContainerMountStore) throws -> URL {
        try XCTUnwrap(Mirror(reflecting: store).descendant("fileURL") as? URL)
    }
}
