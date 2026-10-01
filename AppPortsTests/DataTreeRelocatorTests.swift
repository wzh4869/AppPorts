import Darwin
import XCTest
@testable import AppPorts

final class DataTreeRelocatorTests: XCTestCase {
    func testReadonlyDirectoryCrossParentMovePreservesIdentityAndFullMode() throws {
        try withFixture { root in
            let source = root.appendingPathComponent("source")
            let parent = root.appendingPathComponent("other")
            let destination = parent.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: source.appendingPathComponent("file"))
            XCTAssertEqual(chmod(source.path, 0o3555), 0)
            let identity = try DataPathIdentity.capture(source)
            try DataTreeRelocator.move(source, to: destination)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertTrue(identity.matchesFilesystemObject(try DataPathIdentity.capture(destination)))
            XCTAssertEqual(try mode(destination), 0o3555)
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file")), "payload")
        }
    }

    func testExistingDestinationIsNeverReplacedAndReadonlySourceModeIsRestored() throws {
        try withFixture { root in
            let source = root.appendingPathComponent("source")
            let parent = root.appendingPathComponent("other")
            let destination = parent.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data("unrelated".utf8).write(to: destination)
            XCTAssertEqual(chmod(source.path, 0o555), 0)
            let original = try DataPathIdentity.capture(source)
            let other = try DataPathIdentity.capture(destination)
            XCTAssertThrowsError(try DataTreeRelocator.move(source, to: destination))
            XCTAssertEqual(try DataPathIdentity.capture(source), original)
            XCTAssertEqual(try DataPathIdentity.capture(destination), other)
            XCTAssertEqual(try mode(source), 0o555)
            XCTAssertEqual(try String(contentsOf: destination), "unrelated")
        }
    }

    func testSymlinkRootAndDanglingDestinationAreRejected() throws {
        try withFixture { root in
            let target = root.appendingPathComponent("target")
            let link = root.appendingPathComponent("link")
            let destination = root.appendingPathComponent("destination")
            try Data("retained".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try DataTreeRelocator.move(link, to: destination))
            XCTAssertEqual(try String(contentsOf: target), "retained")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("missing"))
            XCTAssertThrowsError(try DataTreeRelocator.move(target, to: destination))
            XCTAssertEqual(try String(contentsOf: target), "retained")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), root.appendingPathComponent("missing").path)
        }
    }

    func testRegularFileMovePreservesIdentityAndMode() throws {
        try withFixture { root in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try Data("data".utf8).write(to: source)
            XCTAssertEqual(chmod(source.path, 0o440), 0)
            let identity = try DataPathIdentity.capture(source)
            try DataTreeRelocator.move(source, to: destination)
            XCTAssertEqual(try DataPathIdentity.capture(destination), identity)
            XCTAssertEqual(try mode(destination), 0o440)
        }
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
        return info.st_mode & 0o7777
    }

    private func withFixture(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DataTreeRelocatorTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let entry as URL in entries {
                    var info = stat()
                    if lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { _ = chmod(entry.path, 0o700) }
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try operation(root)
    }
}
