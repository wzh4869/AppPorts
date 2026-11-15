import Darwin
import XCTest
@testable import AppPorts

final class StorageCapabilityProbeTests: XCTestCase {
    func testLockedApplicationDoesNotLookLikeADegradedFilesystem() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Locked.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let payload = contents.appendingPathComponent("payload")
        try Data("untouched".utf8).write(to: payload)
        let baseline = try XCTUnwrap(StorageCapabilityProbe.probe(destination: root))
        XCTAssertTrue(baseline.missing.isEmpty)
        XCTAssertEqual(lchflags(app.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = lchflags(app.path, 0) }

        for location in [app, contents, payload] {
            XCTAssertEqual(StorageCapabilityProbe.probe(destination: location), baseline)
        }
        XCTAssertEqual(try Data(contentsOf: payload), Data("untouched".utf8))
        XCTAssertNotEqual(try SignatureSnapshot.info(at: app).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: app.path), ["Contents"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Locked.app"])
    }

    func testAProbeThatCannotCreateFilesReturnsUnknown() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(lchflags(root.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = lchflags(root.path, 0) }
        XCTAssertNil(StorageCapabilityProbe.probe(destination: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testMissingDestinationUsesExistingDirectoryAndRemovesScratchFiles() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("New/Example.app")
        XCTAssertEqual(StorageCapabilityProbe.probe(destination: target), StorageCapabilityProbe.probe(destination: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsCapabilityTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
