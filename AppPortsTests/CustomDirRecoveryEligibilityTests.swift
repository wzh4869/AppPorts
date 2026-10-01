import Foundation
import XCTest
@testable import AppPorts

final class CustomDirRecoveryEligibilityTests: XCTestCase {
    func testMissingSourceRestoreRequiresExactDurableTargetIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CustomDirRecoveryEligibilityTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Home/Business")
        let externalBase = root.appendingPathComponent("External")
        let external = externalBase.appendingPathComponent("Business")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("verified".utf8).write(to: external.appendingPathComponent("payload"))
        let config = CustomDirConfig(localPath: local.path, externalBasePath: externalBase.path)
        let identity = try DataPathIdentity.capture(external)
        func index(original: URL = local, destination: URL = external) -> ManagedDataLinkRecord {
            ManagedDataLinkRecord(operationID: UUID(), originalPath: original.path, destinationPath: destination.path,
                destinationIdentity: identity, appName: "Business", dataDirType: DataDirType.custom.rawValue)
        }
        XCTAssertFalse(CustomDirRecoveryEligibility.canRestoreMissingSource(config: config, managedLinks: []))
        XCTAssertTrue(CustomDirRecoveryEligibility.canRestoreMissingSource(config: config, managedLinks: [index()]))
        XCTAssertFalse(CustomDirRecoveryEligibility.canRestoreMissingSource(config: config, managedLinks: [index(original: root.appendingPathComponent("Other"))]))
        XCTAssertFalse(CustomDirRecoveryEligibility.canRestoreMissingSource(config: config, managedLinks: [index(destination: root.appendingPathComponent("Other"))]))
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertFalse(CustomDirRecoveryEligibility.canRestoreMissingSource(config: config, managedLinks: [index()]))
        try FileManager.default.removeItem(at: local)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        XCTAssertFalse(CustomDirRecoveryEligibility.canRestoreMissingSource(config: config, managedLinks: [index()]))
        try FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: external, to: externalBase.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data("verified".utf8).write(to: external.appendingPathComponent("payload"))
        XCTAssertFalse(CustomDirRecoveryEligibility.canRestoreMissingSource(config: config, managedLinks: [index()]))
    }
}
