import Darwin
import Foundation
import XCTest
@testable import AppPorts

final class DirectorySizeTraversalTests: XCTestCase {
    private let manager = FileManager.default

    func testNativeTraversalMatchesLogicalSizesWithoutFollowingLinks() throws {
        let root = try workspace()
        defer { try? manager.removeItem(at: root) }
        let nested = root.appendingPathComponent("中文目录/.hidden")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = nested.appendingPathComponent("payload")
        try Data(repeating: 0x37, count: 8193).write(to: payload)
        XCTAssertEqual(link(payload.path, root.appendingPathComponent("hardlink").path), 0)
        try manager.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        try manager.createSymbolicLink(at: root.appendingPathComponent("missing"),
            withDestinationURL: root.appendingPathComponent("does-not-exist"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("notification").path, 0o600), 0)
        let sparse = root.appendingPathComponent("sparse")
        XCTAssertTrue(manager.createFile(atPath: sparse.path, contents: nil))
        let file = try FileHandle(forWritingTo: sparse)
        let sparseBytes: UInt64 = 8 * 1024 * 1024 + 17
        try file.truncate(atOffset: sparseBytes)
        try file.close()
        let native = DirectorySizeTraversal.measure(at: root)
        XCTAssertTrue(native.isComplete)
        let expectedBytes: Int64 = 2 * 8193 + Int64(sparseBytes)
        XCTAssertEqual(native.bytes, expectedBytes)
        XCTAssertEqual(native.bytes, try referenceSize(root))
    }

    func testUnreadableChildIsIncompleteAndDoesNotCachePartialSize() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission fixture requires an unprivileged test process") }
        let root = try workspace()
        let protected = root.appendingPathComponent("protected")
        try manager.createDirectory(at: protected, withIntermediateDirectories: false)
        defer {
            _ = chmod(protected.path, 0o700)
            try? manager.removeItem(at: root)
        }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("visible"))
        try Data([4, 5]).write(to: protected.appendingPathComponent("private"))
        XCTAssertEqual(chmod(protected.path, 0), 0)
        let partial = measureDirectorySize(at: root, useCache: false)
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.bytes, 3)
        XCTAssertTrue(partial.readIssues.contains { $0.isPermissionDenied })
        XCTAssertEqual(chmod(protected.path, 0o700), 0)
        let complete = measureDirectorySize(at: root)
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(complete.bytes, 5)
        invalidateSizeCache(for: root)
    }

    func testEmptyMissingAndCancelledScansRemainDistinct() async throws {
        let root = try workspace()
        defer { try? manager.removeItem(at: root) }
        XCTAssertTrue(DirectorySizeTraversal.measure(at: root).isComplete)
        XCTAssertFalse(DirectorySizeTraversal.measure(at: root.appendingPathComponent("missing")).isComplete)
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return DirectorySizeTraversal.measure(at: root)
        }.value
        XCTAssertFalse(cancelled.isComplete)
        XCTAssertEqual(cancelled.bytes, 0)
    }

    func testNativeSizeBenchmark() throws {
        guard let output = ProcessInfo.processInfo.environment["APPPORTS_DIRECTORY_SIZE_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Set APPPORTS_DIRECTORY_SIZE_BENCHMARK_OUTPUT for temporary-fixture timing")
        }
        let root = try workspace()
        defer { try? manager.removeItem(at: root) }
        for directory in 0..<100 {
            let child = root.appendingPathComponent("folder-\(directory)")
            try manager.createDirectory(at: child, withIntermediateDirectories: false)
            for index in 0..<100 {
                try Data(repeating: 0x51, count: 4096).write(to: child.appendingPathComponent("file-\(index)"))
            }
        }
        let expected = try referenceSize(root)
        XCTAssertEqual(DirectorySizeTraversal.measure(at: root).bytes, expected)
        var rows: [[String: Any]] = []
        for mode in ["foundation", "native", "native", "foundation"] {
            for round in 0..<4 {
                let start = ProcessInfo.processInfo.systemUptime
                let bytes: Int64
                if mode == "foundation" { bytes = try referenceSize(root) }
                else {
                    let result = DirectorySizeTraversal.measure(at: root)
                    XCTAssertTrue(result.isComplete)
                    bytes = result.bytes
                }
                rows.append(["mode": mode, "round": round, "seconds": ProcessInfo.processInfo.systemUptime - start,
                    "bytes": bytes, "files": 10_000])
                XCTAssertEqual(bytes, expected)
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }

    private func workspace() throws -> URL {
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Previous production enumeration, retained only for same-fixture timing.
    private func referenceSize(_ root: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        let enumeration = try XCTUnwrap(manager.enumerator(at: root, includingPropertiesForKeys: keys))
        var bytes: Int64 = 0
        for case let url as URL in enumeration {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink != true, values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }
}
