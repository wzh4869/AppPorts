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

    func testSinglePassSubtreeMeasurementMatchesIndividualTraversals() throws {
        let root = try workspace()
        let unreadable = root.appendingPathComponent("msg/unreadable")
        defer {
            _ = chmod(unreadable.path, 0o700)
            try? manager.removeItem(at: root)
        }
        let db = root.appendingPathComponent("db_storage")
        let msg = root.appendingPathComponent("msg")
        let attach = msg.appendingPathComponent("attach")
        let file = msg.appendingPathComponent("file")
        let video = msg.appendingPathComponent("video")
        let business = root.appendingPathComponent("business")
        for dir in [db, attach, file, video, business, unreadable] {
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x11, count: 100).write(to: db.appendingPathComponent("db.sqlite"))
        try Data(repeating: 0x22, count: 200).write(to: attach.appendingPathComponent("thumb.bin"))
        try Data(repeating: 0x33, count: 300).write(to: file.appendingPathComponent("doc.pdf"))
        try Data(repeating: 0x44, count: 400).write(to: video.appendingPathComponent("clip.mp4"))
        try Data(repeating: 0x55, count: 500).write(to: business.appendingPathComponent("res.dat"))
        if geteuid() != 0 {
            XCTAssertEqual(chmod(unreadable.path, 0), 0)
        }

        let single = DirectorySizeTraversal.measure(at: root, subtrees: [msg, business, file, video])
        let baselineRoot = DirectorySizeTraversal.measure(at: root)
        XCTAssertEqual(single.root.bytes, baselineRoot.bytes)
        XCTAssertEqual(single.root.isComplete, baselineRoot.isComplete)
        XCTAssertEqual(single.root.readIssues.count, baselineRoot.readIssues.count)

        for subtree in [msg, business, file, video] {
            let expected = DirectorySizeTraversal.measure(at: subtree)
            let actual = try XCTUnwrap(single.subtrees[subtree])
            XCTAssertEqual(actual.bytes, expected.bytes)
            XCTAssertEqual(actual.isComplete, expected.isComplete)
            XCTAssertEqual(actual.readIssues.count, expected.readIssues.count)
        }
    }

    func testDetailGroupsOnlyPendingLocalTreesAndReusesTheMemoryCache() throws {
        let root = try workspace()
        defer { try? manager.removeItem(at: root) }
        let dirs = ["Foo", "Foo/Data", "Foo/Data/Library", "Foo-Bar"].map { root.appendingPathComponent($0) }
        for (index, dir) in dirs.enumerated() {
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 1, count: index + 1).write(to: dir.appendingPathComponent("file"))
        }
        let items = dirs.map(detailItem)
        let forced = AppDataDetailSizing(items: items, policy: .empty, paused: [], forceRefresh: true)
        XCTAssertEqual(Set(forced.groups(for: [2, 3, 1, 0])), Set([[0, 1, 2], [3]]))
        XCTAssertEqual(forced.groups(for: [2]), [[2]])
        let rows = forced.measure([0, 1, 2])
        XCTAssertEqual(rows.map { $0.1.bytes }, [6, 5, 3])
        XCTAssertTrue(rows.allSatisfy { $0.1.isComplete && $0.3?.bytes == $0.1.bytes })

        let cached = AppDataDetailSizing(items: items, policy: .empty, paused: [], forceRefresh: false)
        try Data(count: 12).write(to: dirs[2].appendingPathComponent("new"))
        XCTAssertEqual(Set(cached.groups(for: [0, 1, 2])), Set([[0], [1], [2]]))
        XCTAssertEqual(cached.measure([2]).first?.1.bytes, 3)
        XCTAssertEqual(forced.measure([0, 1, 2]).map { $0.1.bytes }, [18, 17, 15])
    }

    func testDetailMeasuresUnvisitedChildrenAtTheirOwnRoots() throws {
        let root = try workspace()
        defer { try? manager.removeItem(at: root) }
        let container = root.appendingPathComponent("container")
        let real = root.appendingPathComponent("actual/Data")
        try manager.createDirectory(at: container, withIntermediateDirectories: true)
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        try Data(count: 17).write(to: real.appendingPathComponent("payload"))
        let link = container.appendingPathComponent("shortcut")
        try manager.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
        let child = link.appendingPathComponent("Data")
        let missing = container.appendingPathComponent("missing")
        let items = [container, child, missing].map(detailItem)
        let sizing = AppDataDetailSizing(items: items, policy: .empty, paused: [], forceRefresh: true)
        let rows = sizing.measure([0, 1, 2])
        XCTAssertEqual(rows.map { $0.1.bytes }, [0, 17, 0])
        XCTAssertTrue(rows[1].1.isComplete)
        XCTAssertFalse(rows[2].1.isComplete)
        XCTAssertNil(rows[2].3)
    }

    func testDetailReportsReadErrorsOnlyForAffectedRows() throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires an unprivileged process") }
        let root = try workspace()
        let denied = root.appendingPathComponent("child/private")
        let sibling = root.appendingPathComponent("readable")
        defer {
            _ = chmod(denied.path, 0o700)
            try? manager.removeItem(at: root)
        }
        try manager.createDirectory(at: denied, withIntermediateDirectories: true)
        try manager.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data(count: 7).write(to: sibling.appendingPathComponent("file"))
        XCTAssertEqual(chmod(denied.path, 0), 0)
        let items = [root, denied.deletingLastPathComponent(), denied, sibling].map(detailItem)
        let sizing = AppDataDetailSizing(items: items, policy: .empty, paused: [], forceRefresh: true)
        for (index, value, _, entry) in sizing.measure([0, 1, 2, 3]) {
            let expected = measureDirectorySize(at: items[index].path, useCache: false)
            XCTAssertEqual(value.bytes, expected.bytes)
            XCTAssertEqual(value.readIssues.map(\.url), expected.readIssues.map(\.url))
            XCTAssertEqual(entry != nil, index == 3)
        }
    }

    func testDetailSchedulesMountLinkSplitAndPausedRowsIndependently() throws {
        let root = try workspace()
        defer { try? manager.removeItem(at: root) }
        let dirs = ["parent", "parent/mount", "parent/link", "parent/split", "parent/paused"].map {
            root.appendingPathComponent($0)
        }
        for dir in dirs { try manager.createDirectory(at: dir, withIntermediateDirectories: true) }
        var items = dirs.map(detailItem)
        items[1].status = DataDirStatus.mounted
        items[2].linkedDestination = dirs[1]
        items[3].weChatSplitMembers = [items[1], items[2]]
        let ordinary = AppDataDetailSizing(items: items, policy: .empty, paused: [], forceRefresh: true)
        XCTAssertEqual(Set(ordinary.groups(for: [0, 1, 2, 3, 4])), Set([[0, 4], [1], [2], [3]]))
        let paused = AppDataDetailSizing(items: items, policy: .empty, paused: [dirs[4]], forceRefresh: true)
        XCTAssertEqual(Set(paused.groups(for: [0, 4])), Set([[0], [4]]))
    }

    private func detailItem(_ url: URL) -> DataDirItem {
        DataDirItem(name: url.lastPathComponent, path: url, type: .containers, priority: .recommended, description: "")
    }

    func testSkippedDirectoryStillAppliesWithoutRequestedSubtreeTotals() throws {
        let root = try workspace()
        defer { try? manager.removeItem(at: root) }
        let nested = root.appendingPathComponent("skip")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 10).write(to: nested.appendingPathComponent("file"))
        try Data(count: 3).write(to: root.appendingPathComponent("keep"))
        let plain = DirectorySizeTraversal.measure(at: root)
        let scoped = DirectorySizeTraversal.measure(at: root, skippingDirectories: [nested])
        XCTAssertTrue(plain.isComplete && scoped.isComplete)
        XCTAssertEqual(plain.bytes, 13)
        XCTAssertEqual(scoped.bytes, 3)
    }

    func testMountedVolumeSizeMeasurementSkipsVolumeSystemArtifacts() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission fixture requires an unprivileged test process") }
        let root = try workspace()
        let tempItems = root.appendingPathComponent(".TemporaryItems")
        let trashes = root.appendingPathComponent(".Trashes")
        let spotlight = root.appendingPathComponent(".Spotlight-V100")
        defer {
            _ = chmod(tempItems.path, 0o700)
            _ = chmod(trashes.path, 0o700)
            invalidateSizeCache(for: root)
            try? manager.removeItem(at: root)
        }
        try manager.createDirectory(at: tempItems, withIntermediateDirectories: true)
        try manager.createDirectory(at: trashes, withIntermediateDirectories: true)
        try manager.createDirectory(at: spotlight, withIntermediateDirectories: true)
        try Data(count: 1024).write(to: spotlight.appendingPathComponent("index"))
        try Data(count: 42).write(to: root.appendingPathComponent("payload"))
        XCTAssertEqual(chmod(tempItems.path, 0o311), 0)
        XCTAssertEqual(chmod(trashes.path, 0o311), 0)

        let mounted = measureDirectorySize(at: root, useCache: false, isMountPoint: { _ in true })
        XCTAssertTrue(mounted.isComplete)
        XCTAssertEqual(mounted.bytes, 42)
        XCTAssertTrue(mounted.readIssues.isEmpty)

        let local = measureDirectorySize(at: root, useCache: false, isMountPoint: { _ in false })
        XCTAssertFalse(local.isComplete)
        XCTAssertTrue(local.readIssues.contains { $0.isPermissionDenied })
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
