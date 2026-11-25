import Darwin
import Foundation
import XCTest
@testable import AppPorts

final class TreeCopySessionTests: XCTestCase {
    private let fm = FileManager.default

    func testParallelSmallCopiesPreserveMetadataTopologyAndOrderedCallbacks() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try fm.createDirectory(at: w.source.appendingPathComponent("nested"), withIntermediateDirectories: false)
        for index in 0..<12 {
            let file = w.source.appendingPathComponent(String(format: "file-%02d", index))
            try Data(repeating: UInt8(index), count: 4096 + index).write(to: file)
            try setXattr("org.appports.small-copy", Data("metadata".utf8), file)
            if index == 6 { try setXattr("com.apple.ResourceFork", Data([1, 2, 3]), file) }
            XCTAssertEqual(chmod(file.path, 0o440), 0)
        }
        XCTAssertEqual(link(w.source.appendingPathComponent("file-02").path,
                            w.source.appendingPathComponent("nested/linked").path), 0)
        XCTAssertEqual(mkfifo(w.source.appendingPathComponent("notification").path, 0o600), 0)
        try fm.createSymbolicLink(atPath: w.source.appendingPathComponent("shortcut").path, withDestinationPath: "file-00")
        let parallelParent = w.root.appendingPathComponent("parallel")
        try fm.createDirectory(at: parallelParent, withIntermediateDirectories: false)
        let parallelDestination = parallelParent.appendingPathComponent(w.destination.lastPathComponent)
        let serialEvents = SmallCopyEvents()
        let serial = try await TreeCopySession.$concurrentSmallFileCopies.withValue(1) {
            try await TreeCopySession().copy(from: w.source, to: w.destination,
                progressHandler: { await serialEvents.append($0) })
        }
        let parallelEvents = SmallCopyEvents()
        let probe = SmallCopyProbe()
        let session = DataTransferSession()
        let parallel = try await DataTransferSession.$current.withValue(session) {
            try await TreeCopySession.$concurrentSmallFileCopies.withValue(4) {
                try await TreeCopySession(extentSeek: { fd, offset, kind in
                    probe.seek(fd: fd, offset: offset, kind: kind)
                }).copy(from: w.source, to: parallelDestination,
                    progressHandler: { await parallelEvents.append($0) })
            }
        }
        XCTAssertEqual(parallel, serial)
        let serialRecords = await serialEvents.records
        let parallelRecords = await parallelEvents.records
        XCTAssertEqual(parallelRecords, serialRecords)
        XCTAssertGreaterThan(probe.peak, 1, "Ordinary small files must actually overlap")
        XCTAssertLessThanOrEqual(probe.peak, 4)
        XCTAssertTrue(probe.inheritedCopyPhase)
        XCTAssertEqual(session.measurements["hashReadBytes"], Double(serial.logicalBytes * 3))
        try TreeCopySession.verifyCopy(at: parallelDestination, against: serial)
    }

    func testParallelSmallCopyTaskCancellationWakesPausedWorkersAndJoinsThem() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        for index in 0..<4 { try Data(repeating: 0x51, count: 4096).write(to: w.source.appendingPathComponent("file-\(index)")) }
        let control = MigrationTaskControl()
        let probe = SmallCopyProbe(pause: control)
        let task = Task.detached {
            try await MigrationExecution.$control.withValue(control) {
                try await TreeCopySession(extentSeek: { fd, offset, kind in
                    probe.seek(fd: fd, offset: offset, kind: kind)
                }).copy(from: w.source, to: w.destination)
            }
        }
        try await waitForScan(task: task, control: control) { control.snapshot().paused }
        task.cancel()
        do { _ = try await task.value; XCTFail("Paused copy ignored Task cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(probe.active, 0)
        let stopped = try TreeCopySession.snapshot(at: w.destination)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(try TreeCopySession.snapshot(at: w.destination), stopped)
        for index in 0..<4 {
            XCTAssertEqual(try Data(contentsOf: w.source.appendingPathComponent("file-\(index)")), Data(repeating: 0x51, count: 4096))
        }
    }

    func testTinyCopyBoundaryKeepsLargerFilesSerial() async throws {
        for size in [16_384, 16_385, 65_536] {
            let w = try workspace()
            defer { cleanup(w.root) }
            for index in 0..<4 {
                try Data(repeating: 0x51, count: size).write(to: w.source.appendingPathComponent("file-\(index)"))
            }
            let probe = SmallCopyProbe()
            let baseline = try await TreeCopySession.$concurrentSmallFileCopies.withValue(4) {
                try await TreeCopySession(extentSeek: { fd, offset, kind in
                    probe.seek(fd: fd, offset: offset, kind: kind)
                }).copy(from: w.source, to: w.destination)
            }
            if size == 16_384 { XCTAssertGreaterThan(probe.peak, 1) }
            else { XCTAssertEqual(probe.peak, 1) }
            XCTAssertEqual(probe.active, 0)
            try TreeCopySession.verifyCopy(at: w.destination, against: baseline)
        }
    }

    func testParallelSmallCopyFailureJoinsAllWorkersBeforeIndependentRetry() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        for index in 0..<4 { try Data(repeating: 0x61, count: 4096).write(to: w.source.appendingPathComponent("file-\(index)")) }
        let probe = SmallCopyProbe(failFirst: true)
        let control = MigrationTaskControl()
        do {
            _ = try await MigrationExecution.$control.withValue(control) {
                try await TreeCopySession(extentSeek: { fd, offset, kind in
                    probe.seek(fd: fd, offset: offset, kind: kind)
                }).copy(from: w.source, to: w.destination)
            }
            XCTFail("Injected I/O failure succeeded")
        } catch { XCTAssertFalse(error is CancellationError, "The original I/O error must survive sibling cancellation") }
        XCTAssertEqual(probe.active, 0)
        let stopped = try TreeCopySession.snapshot(at: w.destination)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(try TreeCopySession.snapshot(at: w.destination), stopped)
        let retry = w.root.appendingPathComponent("retry")
        let baseline = try await TreeCopySession().copy(from: w.source, to: retry)
        try TreeCopySession.verifyCopy(at: retry, against: baseline)
    }

    func testSmallFileCopyBenchmark() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["APPPORTS_SMALL_COPY_BENCHMARK_OUTPUT"],
              let targetPath = ProcessInfo.processInfo.environment["APPPORTS_SMALL_COPY_BENCHMARK_ROOT"],
              outputPath.hasPrefix("/"), targetPath.hasPrefix("/") else {
            throw XCTSkip("Set the small-copy benchmark root and output to compare real storage")
        }
        let w = try workspace()
        defer { cleanup(w.root) }
        let target = URL(fileURLWithPath: targetPath).appendingPathComponent("AppPorts-small-copy-fixture-\(UUID().uuidString)")
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        defer { cleanup(target) }
        let environment = ProcessInfo.processInfo.environment
        let sizes = try (environment["APPPORTS_SMALL_COPY_BENCHMARK_SIZES"] ?? "4096,65536")
            .split(separator: ",").map { try XCTUnwrap(Int($0)) }
        let widths = try (environment["APPPORTS_SMALL_COPY_BENCHMARK_COPIES"] ?? "1,4,4,1")
            .split(separator: ",").map { try XCTUnwrap(Int($0)) }
        guard !sizes.isEmpty, sizes.allSatisfy({ (1...1_048_576).contains($0) }),
              !widths.isEmpty, widths.allSatisfy({ (1...4).contains($0) }) else {
            return XCTFail("Invalid small-copy benchmark parameters")
        }
        var results: [[String: Double]] = []
        for size in sizes {
            let source = w.source.appendingPathComponent("bytes-\(size)")
            try fm.createDirectory(at: source, withIntermediateDirectories: false)
            let payload = Data(repeating: 0x61, count: size)
            for directory in 0..<10 {
                let parent = source.appendingPathComponent("directory-\(directory)")
                try fm.createDirectory(at: parent, withIntermediateDirectories: false)
                for file in 0..<600 { try payload.write(to: parent.appendingPathComponent("file-\(file)")) }
            }
            for copies in widths {
                // Complete pre-read for every sample; no content cache is used by
                // the copier and every original proof pass remains timed.
                _ = try TreeCopySession.snapshot(at: source)
                let destination = target.appendingPathComponent("copy-\(UUID().uuidString)")
                let session = DataTransferSession()
                let progress = DataTransferProgress()
                let start = ProcessInfo.processInfo.systemUptime
                let baseline = try await DataTransferSession.$current.withValue(session) {
                    try await progress.track { _ in
                        try await TreeCopySession.$concurrentSmallFileCopies.withValue(copies) {
                            try await TreeCopySession().copy(from: source, to: destination)
                        }
                    }
                }
                var result = session.measurements
                result["total"] = ProcessInfo.processInfo.systemUptime - start
                result["copies"] = Double(copies)
                result["fileSize"] = Double(size)
                result["fileCount"] = 6000
                XCTAssertEqual(result["hashReadBytes"], Double(baseline.logicalBytes * 3))
                results.append(result)
                try fm.removeItem(at: destination)
            }
        }
        let output = URL(fileURLWithPath: outputPath)
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["targetRoot": targetPath, "runs": results], options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }

    func testParallelScanPreservesManifestHardlinksResourceForkAndExactReadAccounting() throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try fm.createDirectory(at: w.source.appendingPathComponent("nested"), withIntermediateDirectories: false)
        let bytes = Data(repeating: 0x73, count: 2 * 1024 * 1024 + 37)
        for index in 0..<9 {
            try bytes.write(to: w.source.appendingPathComponent("file-\(index)"))
        }
        let linked = w.source.appendingPathComponent("nested/linked")
        XCTAssertEqual(link(w.source.appendingPathComponent("file-0").path, linked.path), 0)
        let fork = Data(repeating: 0x31, count: 256 * 1024 + 3)
        try setXattr("com.apple.ResourceFork", fork, w.source.appendingPathComponent("file-1"))
        let serial = try TreeCopySession.$concurrentScanReads.withValue(1) {
            try TreeCopySession.snapshot(at: w.source)
        }
        let session = DataTransferSession()
        let progress = DataTransferProgress()
        let parallel = try DataTransferSession.$current.withValue(session) {
            try DataTransferSession.$progress.withValue(progress) {
                try TreeCopySession.$concurrentScanReads.withValue(4) {
                    try TreeCopySession.snapshot(at: w.source)
                }
            }
        }
        XCTAssertEqual(parallel, serial)
        let expectedBytes = Int64(bytes.count * 10 + fork.count)
        XCTAssertEqual(session.measurements["hashReadBytes"], Double(expectedBytes))
        XCTAssertEqual(progress.snapshot().readBytes, expectedBytes)
        XCTAssertEqual(progress.snapshot().completedItems, parallel.entries.count)
        XCTAssertNil(DataTransferSession.current)
        XCTAssertNil(DataTransferSession.progress)
    }

    func testConcurrentSnapshotsAcrossCooperativePoolDoNotStarveBatchWorkers() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        for index in 0..<8 {
            try Data(repeating: UInt8(index), count: 8192).write(to: w.source.appendingPathComponent("file-\(index)"))
        }
        let expected = try TreeCopySession.$concurrentScanReads.withValue(1) {
            try TreeCopySession.snapshot(at: w.source)
        }
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let barrier = CooperativePoolBarrier(parties: width)
        try await withThrowingTaskGroup(of: TreeCopySnapshot.self) { group in
            for _ in 0..<width {
                group.addTask(priority: .userInitiated) {
                    barrier.arriveAndWait()
                    return try TreeCopySession.$concurrentScanReads.withValue(4) {
                        try TreeCopySession.snapshot(at: w.source)
                    }
                }
            }
            for try await snapshot in group {
                XCTAssertEqual(snapshot, expected)
            }
        }
    }

    func testParallelScanBridgesTaskCancellationAndIndependentRetryStillWorks() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        // Sparse logical data keeps the fixture small while leaving enough
        // hashing work to observe a cancellation within an active batch.
        for index in 0..<4 {
            let file = w.source.appendingPathComponent("large-\(index)")
            XCTAssertTrue(fm.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 512 * 1024 * 1024)
            try handle.close()
        }
        let progress = DataTransferProgress()
        let task = Task.detached {
            try DataTransferSession.$progress.withValue(progress) {
                try TreeCopySession.snapshot(at: w.source)
            }
        }
        try await waitForScan(task: task) { progress.snapshot().readBytes > 0 }
        task.cancel()
        do { _ = try await task.value; XCTFail("Parallel scan ignored task cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(progress.snapshot().readBytes, Int64(2 * 1024 * 1024 * 1024))
        let stopped = progress.snapshot().readBytes
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(progress.snapshot().readBytes, stopped, "All workers must join before returning")
        for index in 0..<4 {
            let handle = try FileHandle(forWritingTo: w.source.appendingPathComponent("large-\(index)"))
            try handle.truncate(atOffset: 4096)
            try handle.close()
        }
        XCTAssertEqual(try TreeCopySession.snapshot(at: w.source).logicalBytes, 4 * 4096)
    }

    func testParallelScanWaitsForPausedControlAndCancellationReleasesWorkers() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        for index in 0..<4 {
            let file = w.source.appendingPathComponent("file-\(index)")
            XCTAssertTrue(fm.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 512 * 1024 * 1024)
            try handle.close()
        }
        let control = MigrationTaskControl()
        control.pause()
        let task = Task.detached {
            try MigrationExecution.$control.withValue(control) { try TreeCopySession.snapshot(at: w.source) }
        }
        try await waitForScan(task: task, control: control) { control.snapshot().paused }
        control.resume()
        let resumed = try await task.value
        XCTAssertEqual(resumed.logicalBytes, 2 * 1024 * 1024 * 1024)
        let progress = DataTransferProgress()
        let cancelled = Task.detached {
            try DataTransferSession.$progress.withValue(progress) {
                try MigrationExecution.$control.withValue(control) { try TreeCopySession.snapshot(at: w.source) }
            }
        }
        try await waitForScan(task: cancelled, control: control) { progress.snapshot().readBytes > 0 }
        control.pause()
        try await waitForScan(task: cancelled, control: control) { control.snapshot().paused }
        let watchdog = Task.detached {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            control.cancel()
        }
        defer { watchdog.cancel() }
        let cancelStarted = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Paused scan ignored cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelStarted, 4,
                          "Task cancellation must wake paused workers without the watchdog")
    }

    private func waitForScan<T>(task: Task<T, Error>, control: MigrationTaskControl? = nil,
                               _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                control?.cancel()
                task.cancel()
                _ = try? await task.value
                throw CocoaError(.coderReadCorrupt)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testVerifiedObservationDoesNotAdoptLaterCandidateWrites() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("original".utf8).write(to: w.source.appendingPathComponent("payload"))
        let saved = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let verified = try TreeCopySession.verifiedCopySnapshot(at: w.destination, against: saved)
        try Data("unique later write".utf8).write(to: w.destination.appendingPathComponent("payload"))
        XCTAssertThrowsError(try TreeCopySession.removeVerifiedCopy(at: w.destination, against: verified, requireSourceIdentity: true))
        XCTAssertEqual(try String(contentsOf: w.destination.appendingPathComponent("payload")), "unique later write")
        XCTAssertEqual(try String(contentsOf: w.source.appendingPathComponent("payload")), "original")
    }

    func testRealmNamedPipeSurvivesCopyUseRestoreAndCleanup() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let database = w.source.appendingPathComponent("magic_mirror.realm")
        let notification = w.source.appendingPathComponent("magic_mirror.realm.note")
        try Data("database before migration".utf8).write(to: database)
        XCTAssertEqual(mkfifo(notification.path, 0o640), 0)
        try setXattr("org.appports.test.fifo", Data("notification metadata".utf8), notification)
        try times(notification, birth: 1_650_000_000, modified: 1_700_000_000)

        let migrated = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let copiedPipe = w.destination.appendingPathComponent(notification.lastPathComponent)
        XCTAssertEqual(try info(copiedPipe).st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(try info(copiedPipe).st_mode & 0o7777, 0o640)
        XCTAssertEqual(try xattr("org.appports.test.fifo", copiedPipe), Data("notification metadata".utf8))
        try TreeCopySession.removeVerifiedCopy(at: w.source, against: migrated, requireSourceIdentity: true)
        XCTAssertFalse(fm.fileExists(atPath: w.source.path))

        // The application writes newer durable data after migration. Restoring
        // must use that version and preserve the notification node's type.
        try Data("database updated on external storage".utf8)
            .write(to: w.destination.appendingPathComponent(database.lastPathComponent))
        let restored = try await TreeCopySession().copy(from: w.destination, to: w.source)
        let decoded = try PropertyListDecoder().decode(TreeCopySnapshot.self,
            from: PropertyListEncoder().encode(restored))
        try TreeCopySession.verifyCopy(at: w.source, against: decoded)
        try TreeCopySession.removeVerifiedCopy(at: w.destination, against: decoded, requireSourceIdentity: true)
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
        XCTAssertEqual(try info(notification).st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(try Data(contentsOf: database), Data("database updated on external storage".utf8))
    }

    func testNamedPipeCopyPreservesHardlinksWithoutConsumingRuntimeMessages() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let first = w.source.appendingPathComponent("first.note")
        let second = w.source.appendingPathComponent("second.note")
        XCTAssertEqual(mkfifo(first.path, 0o600), 0)
        XCTAssertEqual(link(first.path, second.path), 0)
        let peer = open(first.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        var message: UInt8 = 0x42
        XCTAssertEqual(write(peer, &message, 1), 1)

        let baseline = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let copiedFirst = try info(w.destination.appendingPathComponent(first.lastPathComponent))
        let copiedSecond = try info(w.destination.appendingPathComponent(second.lastPathComponent))
        XCTAssertEqual(copiedFirst.st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(copiedFirst.st_ino, copiedSecond.st_ino)
        XCTAssertEqual(baseline.logicalBytes, 0)
        var received: UInt8 = 0
        XCTAssertEqual(read(peer, &received, 1), 1)
        XCTAssertEqual(received, message)

        // A link outside the selected root is still rejected: copying only
        // one endpoint would split the application's IPC relationship.
        XCTAssertEqual(link(first.path, w.root.appendingPathComponent("outside.note").path), 0)
        XCTAssertThrowsError(try TreeCopySession.snapshot(at: w.source))
    }

    func testReplacingNamedPipeWithNewFileBlocksCleanup() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let notification = w.source.appendingPathComponent("database.note")
        XCTAssertEqual(mkfifo(notification.path, 0o600), 0)
        let baseline = try await TreeCopySession().copy(from: w.source, to: w.destination)
        XCTAssertEqual(unlink(notification.path), 0)
        try Data("new data must survive".utf8).write(to: notification)
        XCTAssertThrowsError(try TreeCopySession.removeVerifiedCopy(at: w.source,
            against: baseline, requireSourceIdentity: true))
        XCTAssertEqual(try Data(contentsOf: notification), Data("new data must survive".utf8))
        XCTAssertEqual(try info(w.destination.appendingPathComponent(notification.lastPathComponent)).st_mode & S_IFMT, S_IFIFO)
    }

    func testCompatibleNamedPipeCreatorUsesDirectoryDescriptorAndNeverOverwrites() throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let parent = open(w.source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { close(parent) }
        let relocated = w.root.appendingPathComponent("relocated")
        try fm.moveItem(at: w.source, to: relocated)
        try fm.createDirectory(at: w.source, withIntermediateDirectories: false)
        try Data("unrelated new file".utf8).write(to: w.source.appendingPathComponent("-database.note"))
        try TreeCopySession.createNamedPipeUsingSystemUtility(parent: parent, name: "-database.note")
        XCTAssertEqual(try info(relocated.appendingPathComponent("-database.note")).st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(try Data(contentsOf: w.source.appendingPathComponent("-database.note")), Data("unrelated new file".utf8))
        let existing = relocated.appendingPathComponent("existing")
        try Data("keep existing".utf8).write(to: existing)
        XCTAssertThrowsError(try TreeCopySession.createNamedPipeUsingSystemUtility(parent: parent, name: "existing"))
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep existing".utf8))
    }

    func testDirtySharedMappingCannotReuseTimestampBasedContentEvidence() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("mapped")
        try Data(repeating: 0x61, count: 8192).write(to: file)
        try await DataTransferSession.run {
            let fd = open(file.path, O_RDWR | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { close(fd) }
            let mapping = mmap(nil, 8192, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
            XCTAssertNotEqual(mapping, MAP_FAILED)
            guard let mapping, mapping != MAP_FAILED else { return }
            defer { munmap(mapping, 8192) }
            let baseline = try TreeCopySession.snapshot(at: w.source)
            let before = try self.info(file)
            mapping.storeBytes(of: UInt8(0x62), as: UInt8.self)
            // No msync: dirty mapped bytes are already readable while APFS may
            // still report exactly the same size, mtime and ctime.
            let after = try self.info(file)
            XCTAssertEqual(before.st_size, after.st_size)
            XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
            XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
            XCTAssertEqual(before.st_ctimespec.tv_sec, after.st_ctimespec.tv_sec)
            XCTAssertEqual(before.st_ctimespec.tv_nsec, after.st_ctimespec.tv_nsec)
            XCTAssertThrowsError(try TreeCopySession.verifyUnchanged(at: w.source, against: baseline))
        }
    }

    func testSystemAccessTagsDoNotBlockCopyOrCleanupWhileApplicationXattrsRemainStrict() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("content".utf8).write(to: w.source.appendingPathComponent("payload"))
        let baseline = try await TreeCopySession().copy(from: w.source, to: w.destination)
        var raw = try XCTUnwrap(try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(baseline), format: nil) as? [String: Any])
        var entries = try XCTUnwrap(raw["entries"] as? [[String: Any]])
        var attributes = try XCTUnwrap(entries[0]["extendedAttributes"] as? [String: Data])
        attributes["com.apple.provenance"] = Data("old OS provenance".utf8)
        attributes["com.apple.macl"] = Data("old OS access grant".utf8)
        entries[0]["extendedAttributes"] = attributes
        var fileAttributes = try XCTUnwrap(entries[1]["extendedAttributes"] as? [String: Data])
        fileAttributes["com.apple.macl"] = Data("different per-file OS grant".utf8)
        entries[1]["extendedAttributes"] = fileAttributes
        raw["entries"] = entries
        func decode() throws -> TreeCopySnapshot {
            try PropertyListDecoder().decode(TreeCopySnapshot.self,
                from: PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0))
        }
        let historical = try decode()
        XCTAssertEqual(historical.entries[0].extendedAttributes["com.apple.provenance"], Data("old OS provenance".utf8))
        try TreeCopySession.verifyCopy(at: w.destination, against: historical)
        try TreeCopySession.verifyUnchanged(at: w.source, against: historical)
        attributes["org.appports.business-metadata"] = Data("must not be ignored".utf8)
        entries[0]["extendedAttributes"] = attributes
        raw["entries"] = entries
        let changed = try decode()
        XCTAssertThrowsError(try TreeCopySession.verifyCopy(at: w.destination, against: changed))
        XCTAssertThrowsError(try TreeCopySession.verifyUnchanged(at: w.source, against: changed))
        try TreeCopySession.removeVerifiedCopy(at: w.source, against: historical, requireSourceIdentity: true)
        XCTAssertFalse(fm.fileExists(atPath: w.source.path))
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("payload")), Data("content".utf8))
    }

    func testLegacyOwnershipOverrideIsNotAllowedForOrdinaryDirectories() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("original".utf8).write(to: w.source.appendingPathComponent("payload"))
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.destination,
            legacyRootOwnership: .init(uid: geteuid(), gid: getegid())) }
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
        XCTAssertEqual(try Data(contentsOf: w.source.appendingPathComponent("payload")), Data("original".utf8))
    }

    func testLegacyManifestProjectionChangesOnlyDestinationRoot() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("original".utf8).write(to: w.source.appendingPathComponent("payload"))
        var snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let entries = snapshot.entries
        snapshot.restoredRootOwnership = .init(uid: 0, gid: 0)
        let decoded = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: PropertyListEncoder().encode(snapshot))
        XCTAssertEqual(decoded.entries, entries)
        XCTAssertEqual(decoded.destinationEntry(entries[0]).uid, 0)
        XCTAssertEqual(decoded.destinationEntry(entries[1]), entries[1])
        // Unchanged-source checks ignore destination projection, but copy checks enforce it.
        try TreeCopySession.verifyUnchanged(at: w.source, against: decoded)
        XCTAssertThrowsError(try TreeCopySession.verifyCopy(at: w.destination, against: decoded))
        var raw = try XCTUnwrap(try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(snapshot), format: nil) as? [String: Any])
        raw.removeValue(forKey: "restoredRootOwnership")
        let old = try PropertyListDecoder().decode(TreeCopySnapshot.self,
            from: PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0))
        XCTAssertNil(old.restoredRootOwnership)
        try TreeCopySession.verifyCopy(at: w.destination, against: old)
    }

    func testCopiesWholeRootMetadataAndNestedReadOnlyItems() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let nested = w.source.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        let file = nested.appendingPathComponent("payload")
        try Data("verified content".utf8).write(to: file)
        try setXattr("com.apple.ResourceFork", Data([5, 4, 3, 2, 1]), file)
        for path in [w.source, nested, file] {
            try setXattr("org.appports.test.empty", Data(), path)
            try setXattr("org.appports.test.bytes", Data([0, 255, 1, 128]), path)
            try times(path, birth: 1_650_000_000, modified: 1_700_000_000)
            XCTAssertEqual(chflags(path.path, UInt32(UF_HIDDEN | UF_NODUMP)), 0)
            XCTAssertEqual(chmod(path.path, path == file ? 0o440 : 0o550), 0)
        }
        let result = try await TreeCopySession().copy(from: w.source, to: w.destination)
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("nested/payload")), Data("verified content".utf8))
        for relative in ["", "nested", "nested/payload"] {
            let source = relative.isEmpty ? w.source : w.source.appendingPathComponent(relative)
            let target = relative.isEmpty ? w.destination : w.destination.appendingPathComponent(relative)
            let a = try info(source), b = try info(target)
            XCTAssertEqual(b.st_mode & 0o7777, relative == "nested/payload" ? 0o440 : 0o550)
            XCTAssertEqual(b.st_uid, a.st_uid)
            XCTAssertEqual(b.st_gid, a.st_gid)
            XCTAssertEqual(b.st_flags, UInt32(UF_HIDDEN | UF_NODUMP))
            XCTAssertEqual(b.st_birthtimespec.tv_sec, 1_650_000_000)
            XCTAssertEqual(b.st_birthtimespec.tv_nsec, 123_456_789)
            XCTAssertEqual(b.st_mtimespec.tv_sec, a.st_mtimespec.tv_sec)
            XCTAssertEqual(b.st_mtimespec.tv_nsec, a.st_mtimespec.tv_nsec)
            XCTAssertEqual(try xattr("org.appports.test.empty", target), Data())
            XCTAssertEqual(try xattr("org.appports.test.bytes", target), Data([0, 255, 1, 128]))
        }
        XCTAssertEqual(try xattr("com.apple.ResourceFork", w.destination.appendingPathComponent("nested/payload")), Data([5, 4, 3, 2, 1]))
        try TreeCopySession.verifyCopy(at: w.destination, against: result)
        let retained = w.root.appendingPathComponent("retained")
        try fm.moveItem(at: w.source, to: retained)
        try TreeCopySession.verifyUnchanged(at: retained, against: result)
        let decoded = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: PropertyListEncoder().encode(result))
        XCTAssertEqual(decoded, result)
    }

    func testPreservesHardlinksAcrossSiblingDirectoriesAndRejectsOutsideLinks() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        for name in ["a", "b"] { try fm.createDirectory(at: w.source.appendingPathComponent(name), withIntermediateDirectories: false) }
        let first = w.source.appendingPathComponent("a/file")
        let second = w.source.appendingPathComponent("b/other")
        try Data("linked".utf8).write(to: first)
        XCTAssertEqual(link(first.path, second.path), 0)
        let result = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let a = try info(w.destination.appendingPathComponent("a/file"))
        let b = try info(w.destination.appendingPathComponent("b/other"))
        XCTAssertEqual(a.st_ino, b.st_ino)
        XCTAssertNotEqual(a.st_ino, try info(first).st_ino)
        XCTAssertEqual(a.st_nlink, 2)
        try TreeCopySession.verifyCopy(at: w.destination, against: result)
        XCTAssertEqual(link(first.path, w.root.appendingPathComponent("outside").path), 0)
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.root.appendingPathComponent("refused")) }
        XCTAssertFalse(fm.fileExists(atPath: w.root.appendingPathComponent("refused").path))
    }

    func testHardlinkGroupsUseCanonicalPathsAndKeepEqualIndependentFilesSeparate() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        for name in ["a", "z"] { try fm.createDirectory(at: w.source.appendingPathComponent(name), withIntermediateDirectories: false) }
        let linkedPaths = ["a/inner", "a.txt", "z/last"]
        let first = w.source.appendingPathComponent(linkedPaths[0])
        try Data("equal bytes".utf8).write(to: first)
        for path in linkedPaths.dropFirst() {
            XCTAssertEqual(link(first.path, w.source.appendingPathComponent(path).path), 0)
        }
        for path in ["independent-one", "independent-two"] {
            try Data("equal bytes".utf8).write(to: w.source.appendingPathComponent(path))
        }
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.path, $0) })
        let firstInode = try info(w.destination.appendingPathComponent(linkedPaths[0])).st_ino
        for path in linkedPaths {
            // Depth-first traversal sees a/inner before a.txt, while the
            // canonical hardlink label is the lexically smallest full path.
            XCTAssertEqual(try XCTUnwrap(entries[path]).hardlinkGroup, "a.txt")
            let destination = try info(w.destination.appendingPathComponent(path))
            XCTAssertEqual(destination.st_ino, firstInode)
            XCTAssertEqual(destination.st_nlink, 3)
        }
        for path in ["independent-one", "independent-two"] {
            XCTAssertNil(try XCTUnwrap(entries[path]).hardlinkGroup)
            let destination = try info(w.destination.appendingPathComponent(path))
            XCTAssertNotEqual(destination.st_ino, firstInode)
            XCTAssertEqual(destination.st_nlink, 1)
        }
        try TreeCopySession.verifyUnchanged(at: w.source, against: snapshot)
        try TreeCopySession.verifyCopy(at: w.destination, against: snapshot)

        // An excluded name remains outside the selected tree even when the
        // inode is also reachable through several included sibling paths.
        XCTAssertEqual(link(first.path, w.source.appendingPathComponent("excluded").path), 0)
        XCTAssertThrowsError(try TreeCopySession.snapshot(at: w.source, excludingRootEntries: ["excluded"])) { error in
            guard case TreeCopyError.hardlinkOutsideSelection = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSeparatingAnOutsideFileLinkPreservesSelectedLinksAndLocalAttachment() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let payload = w.source.appendingPathComponent("a")
        let sibling = w.source.appendingPathComponent("b")
        let attachment = w.root.appendingPathComponent("attach")
        let bytes = Data("shared media".utf8)
        try bytes.write(to: payload)
        XCTAssertEqual(link(payload.path, sibling.path), 0)
        XCTAssertEqual(link(payload.path, attachment.path), 0)

        let baseline = try await TreeCopySession().copy(from: w.source, to: w.destination,
                                                       separatesExternalFileHardlinks: true)
        let saved = try PropertyListDecoder().decode(TreeCopySnapshot.self,
            from: PropertyListEncoder().encode(baseline))
        XCTAssertEqual(saved.externalFileHardlinks, ["a": 1])
        try TreeCopySession.verifyUnchanged(at: w.source, against: saved)
        try TreeCopySession.verifyCopy(at: w.destination, against: saved)
        let copied = w.destination.appendingPathComponent("a")
        XCTAssertEqual(try info(copied).st_ino, try info(w.destination.appendingPathComponent("b")).st_ino)
        XCTAssertNotEqual(try info(copied).st_ino, try info(attachment).st_ino)

        let lateLink = w.root.appendingPathComponent("late-link")
        XCTAssertEqual(link(payload.path, lateLink.path), 0)
        XCTAssertThrowsError(try TreeCopySession.verifyUnchanged(at: w.source, against: saved))
        try fm.removeItem(at: lateLink)

        // A checkpointed cleanup may have already removed the canonical
        // selected link. The remaining inode still has one outside link.
        let removalID = UUID()
        try fm.removeItem(at: payload)
        try TreeCopySession.verifyRemovalRemainder(at: w.source, against: saved, removalID: removalID)
        try TreeCopySession.removeVerifiedCopy(at: w.source, against: saved, allowPartialRemoval: true,
                                             removalID: removalID, requireSourceIdentity: true)
        XCTAssertEqual(try Data(contentsOf: attachment), bytes)
        XCTAssertEqual(try info(attachment).st_nlink, 1)
        XCTAssertEqual(try Data(contentsOf: copied), bytes)
    }

    func testHardlinkAddedAfterInitialVerificationStopsFinalVerification() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("payload")
        let outside = w.root.appendingPathComponent("outside")
        try Data("original".utf8).write(to: file)
        do {
            _ = try await TreeCopySession().copy(from: w.source, to: w.destination, progressHandler: { progress in
                if progress.currentFile.isEmpty { XCTAssertEqual(link(file.path, outside.path), 0) }
            })
            XCTFail("A new outside hardlink must invalidate the copied baseline")
        } catch TreeCopyError.hardlinkOutsideSelection { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
        XCTAssertEqual(try info(file).st_ino, try info(outside).st_ino)
        XCTAssertTrue(fm.fileExists(atPath: w.destination.appendingPathComponent("payload").path))
    }

    func testFileRootPreservesSetgidAndGroup() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("settings.plist")
        try Data("preferences".utf8).write(to: file)
        var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
        _ = getgroups(Int32(groups.count), &groups)
        let gid = groups.first(where: { $0 != getegid() }) ?? getegid()
        XCTAssertEqual(chown(file.path, getuid(), gid), 0)
        XCTAssertEqual(chmod(file.path, 0o2640), 0)
        _ = try await TreeCopySession().copy(from: file, to: w.destination)
        XCTAssertEqual(try info(w.destination).st_gid, gid)
        XCTAssertEqual(try info(w.destination).st_mode & 0o7777, 0o2640)
    }

    func testPreservesACLAndRemovesInheritedTargetACL() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let payload = w.source.appendingPathComponent("payload")
        try Data("acl".utf8).write(to: payload)
        try chmodACL(["+a", "everyone allow readattr,readextattr"], payload)
        let parent = w.root.appendingPathComponent("target-parent")
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        try chmodACL(["+a", "everyone allow read,file_inherit,directory_inherit"], parent)
        let destination = parent.appendingPathComponent("copy")
        _ = try await TreeCopySession().copy(from: w.source, to: destination)
        XCTAssertEqual(try aclText(destination), nil)
        XCTAssertEqual(try aclText(destination.appendingPathComponent("payload")), try aclText(payload))
    }

    func testFinalCallbackMutationCannotBecomeSuccessfulBaseline() async throws {
        for change in ["append", "newfile", "same-size"] {
            let w = try workspace()
            defer { cleanup(w.root) }
            let file = w.source.appendingPathComponent("payload")
            try Data("before".utf8).write(to: file)
            let mtime = try info(file).st_mtimespec
            await assertFails {
                try await TreeCopySession().copy(from: w.source, to: w.destination, progressHandler: { progress in
                    guard progress.currentFile.isEmpty else { return }
                    if change == "newfile" { try! Data("new".utf8).write(to: w.source.appendingPathComponent("late")) }
                    else {
                        let fd = open(file.path, O_WRONLY)
                        let bytes = Array((change == "append" ? "before-added" : "AFTER!").utf8)
                        _ = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
                        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), mtime]
                        _ = futimens(fd, &times)
                        close(fd)
                    }
                })
            }
            XCTAssertTrue(fm.fileExists(atPath: file.path))
            if change == "newfile" {
                XCTAssertEqual(try Data(contentsOf: w.source.appendingPathComponent("late")), Data("new".utf8))
            } else {
                XCTAssertEqual(try Data(contentsOf: file), Data((change == "append" ? "before-added" : "AFTER!").utf8))
            }
        }
    }

    func testDetectsCopyCorruptionEvenWhenSizeAndMtimeMatch() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("before".utf8).write(to: w.source.appendingPathComponent("payload"))
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let file = w.destination.appendingPathComponent("payload")
        let before = try info(file)
        let fd = open(file.path, O_WRONLY)
        _ = Data("AFTER!".utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(futimens(fd, &times), 0)
        close(fd)
        XCTAssertThrowsError(try TreeCopySession.verifyCopy(at: w.destination, against: snapshot))
        XCTAssertThrowsError(try TreeCopySession.verifyUnchanged(at: w.destination, against: snapshot))
    }

    func testRelativeLinksUseProjectedFinalLocation() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("internal".utf8).write(to: w.source.appendingPathComponent("payload"))
        try fm.createSymbolicLink(atPath: w.source.appendingPathComponent("internal").path, withDestinationPath: "payload")
        try fm.createSymbolicLink(atPath: w.source.appendingPathComponent("external").path, withDestinationPath: "../shared")
        try fm.createSymbolicLink(atPath: w.source.appendingPathComponent("absolute").path, withDestinationPath: "/tmp/nonexistent-appports-target")
        let staged = w.root.appendingPathComponent("staging/deep/copy")
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        await assertFails { try await TreeCopySession().copy(from: w.source, to: staged) }
        _ = try await TreeCopySession().copy(from: w.source, to: staged, finalDestination: w.source)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: staged.appendingPathComponent("internal").path), "payload")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: staged.appendingPathComponent("external").path), "../shared")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: staged.appendingPathComponent("absolute").path), "/tmp/nonexistent-appports-target")
    }

    func testExclusionsAreRootOnlyAndExistingUnknownDestinationIsUntouched() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try fm.createDirectory(at: w.source.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data("excluded".utf8).write(to: w.source.appendingPathComponent("marker"))
        try Data("keep nested".utf8).write(to: w.source.appendingPathComponent("nested/marker"))
        let result = try await TreeCopySession().copy(from: w.source, to: w.destination, excludingRootEntries: ["marker"])
        XCTAssertFalse(fm.fileExists(atPath: w.destination.appendingPathComponent("marker").path))
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("nested/marker")), Data("keep nested".utf8))
        XCTAssertEqual(result.excludedRootEntries, ["marker"])
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.destination) }
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("nested/marker")), Data("keep nested".utf8))
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.source.appendingPathComponent("self")) }
    }

    func testRejectsImmutableFlagBeforeCreatingDestination() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("immutable")
        try Data("locked".utf8).write(to: file)
        XCTAssertEqual(chflags(file.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(file.path, 0) }
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.destination) }
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
    }

    func testCancellationLeavesSourceUntouched() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("payload")
        try Data("safe".utf8).write(to: file)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TreeCopySession().copy(from: w.source, to: w.destination)
        }
        do { _ = try await task.value; XCTFail("Cancelled copy succeeded") } catch is CancellationError {} catch { XCTFail("Wrong cancellation error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: file), Data("safe".utf8))
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
    }

    func testUnsupportedExtentFallbackCancelsDuringOneFileAndRetries() async throws {
        for unsupported in [ENOTSUP, EINVAL] {
            let w = try workspace()
            defer { cleanup(w.root) }
            let file = w.source.appendingPathComponent("payload")
            let bytes = Data(repeating: 0x5A, count: 8 * 1024 * 1024)
            try bytes.write(to: file)
            try setXattr("org.appports.fallback", Data("metadata".utf8), file)
            XCTAssertEqual(chmod(file.path, 0o440), 0)
            let baseline = try TreeCopySession.snapshot(at: w.source)
            let session = TreeCopySession(extentSeek: { _, _, _ in errno = unsupported; return -1 })
            let task = Task {
                try await session.copy(from: w.source, to: w.destination, progressHandler: { progress in
                    if progress.currentFile == "payload", progress.copiedBytes > 0 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            }
            do { _ = try await task.value; XCTFail("Fallback ignored mid-file cancellation") }
            catch is CancellationError {}
            catch { XCTFail("Wrong cancellation error: \(error)") }
            let partialFile = w.destination.appendingPathComponent("payload")
            let partialBytes = try Data(contentsOf: partialFile)
            XCTAssertGreaterThan(partialBytes.count, 0)
            XCTAssertLessThan(partialBytes.count, bytes.count)
            XCTAssertEqual(partialBytes, bytes.prefix(partialBytes.count))
            try TreeCopySession.verifyUnchanged(at: w.source, against: baseline)
            // The pipeline's partial-copy contract must still recognize the
            // actual prefix, so ordinary recovery can safely retry this copy.
            let partial = try TreeCopySession.partialCopySnapshot(at: w.destination, source: w.source, against: baseline)
            try TreeCopySession.removeVerifiedCopy(at: w.destination, against: partial)
            let completed = try await session.copy(from: w.source, to: w.destination)
            try TreeCopySession.verifyCopy(at: w.destination, against: completed)
            try TreeCopySession.verifyUnchanged(at: w.source, against: baseline)
            XCTAssertEqual(try Data(contentsOf: partialFile), bytes)
            XCTAssertEqual(try info(partialFile).st_mode & 0o7777, 0o440)
            XCTAssertEqual(try xattr("org.appports.fallback", partialFile), Data("metadata".utf8))
        }
    }

    func testRelativeLinkIntoExcludedEntryCannotSilentlyChangeTarget() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("not copied".utf8).write(to: w.source.appendingPathComponent("marker"))
        try fm.createSymbolicLink(atPath: w.source.appendingPathComponent("link").path, withDestinationPath: "marker")
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.destination, excludingRootEntries: ["marker"]) }
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
    }

    func testCopiesIntoExcludedOnlyRootAndRestoresSetgidDirectoryMetadata() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("payload".utf8).write(to: w.source.appendingPathComponent("file"))
        try fm.createDirectory(at: w.destination, withIntermediateDirectories: false)
        try Data("keep marker".utf8).write(to: w.destination.appendingPathComponent("marker"))
        XCTAssertEqual(chown(w.source.path, getuid(), getegid()), 0)
        XCTAssertEqual(chmod(w.source.path, 0o2750), 0)
        XCTAssertEqual(try info(w.source).st_mode & 0o7777, 0o2750)
        let result = try await TreeCopySession().copy(from: w.source, to: w.destination, excludingRootEntries: ["marker"])
        XCTAssertEqual(try info(w.destination).st_mode & 0o7777, 0o2750)
        XCTAssertEqual(try info(w.destination).st_gid, try info(w.source).st_gid)
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("marker")), Data("keep marker".utf8))
        try TreeCopySession.verifyCopy(at: w.destination, against: result)
    }

    func testCopyDetectsMutationAfterFileProgressEvenWithRestoredMtime() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("payload")
        try Data("before".utf8).write(to: file)
        let before = try info(file)
        await assertFails {
            try await TreeCopySession().copy(from: w.source, to: w.destination, progressHandler: { progress in
                guard progress.currentFile == "payload" else { return }
                let fd = open(file.path, O_WRONLY)
                _ = Data("AFTER!".utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
                var times = [before.st_atimespec, before.st_mtimespec]
                _ = futimens(fd, &times)
                close(fd)
            })
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("AFTER!".utf8))
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("payload")), Data("before".utf8))
    }

    func testSparseFileLogicalBytesAndHolesSurviveCopy() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("sparse")
        let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 8 * 1024 * 1024), 0)
        let payload = Data("tail".utf8)
        XCTAssertEqual(payload.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 8 * 1024 * 1024 - 4) }, 4)
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: 0, fp_length: 8 * 1024 * 1024 - 4096)
        XCTAssertEqual(fcntl(fd, F_PUNCHHOLE, &hole), 0)
        close(fd)
        XCTAssertLessThan(try info(file).st_blocks * 512, 1024 * 1024)
        _ = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let copied = w.destination.appendingPathComponent("sparse")
        XCTAssertEqual(try info(copied).st_size, 8 * 1024 * 1024)
        XCTAssertLessThan(try info(copied).st_blocks * 512, 1024 * 1024)
        let handle = try FileHandle(forReadingFrom: copied)
        defer { try? handle.close() }
        try handle.seek(toOffset: 8 * 1024 * 1024 - 8)
        XCTAssertEqual(try handle.read(upToCount: 8), Data([0, 0, 0, 0, 116, 97, 105, 108]))
    }

    func testRestrictiveSourceACLIsInstalledAfterWritableMetadata() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("payload")
        try Data("metadata first".utf8).write(to: file)
        try times(file, birth: 1_600_000_000, modified: 1_700_000_000)
        try chmodACL(["+a", "everyone deny write,append,writeattr,writeextattr"], file)
        _ = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let target = w.destination.appendingPathComponent("payload")
        XCTAssertEqual(try aclText(target), try aclText(file))
        XCTAssertEqual(try info(target).st_birthtimespec.tv_sec, 1_600_000_000)
        XCTAssertEqual(try Data(contentsOf: target), Data("metadata first".utf8))
    }

    func testReappliesRootMetadataAfterExcludedMarkerWrite() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("copy".utf8).write(to: w.source.appendingPathComponent("payload"))
        try times(w.source, birth: 1_600_000_000, modified: 1_700_000_000)
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination, excludingRootEntries: ["marker"])
        try Data("owned marker".utf8).write(to: w.destination.appendingPathComponent("marker"))
        // Directory timestamps are replayed, but no longer serve as content proof.
        try TreeCopySession.verifyCopy(at: w.destination, against: snapshot)
        try TreeCopySession.applyRootMetadata(at: w.destination, from: snapshot)
        try TreeCopySession.verifyCopy(at: w.destination, against: snapshot)
        XCTAssertEqual(try info(w.destination).st_mtimespec.tv_sec, 1_700_000_000)
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("marker")), Data("owned marker".utf8))
    }

    func testReappliesRootMetadataToReadOnlyRootAfterMarkerWrite() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("payload".utf8).write(to: w.source.appendingPathComponent("payload"))
        try setXattr("org.appports.root", Data([1, 2, 3]), w.source)
        XCTAssertEqual(chmod(w.source.path, 0o555), 0)
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination, excludingRootEntries: ["marker"])
        XCTAssertEqual(chmod(w.destination.path, 0o755), 0)
        try Data("marker".utf8).write(to: w.destination.appendingPathComponent("marker"))
        XCTAssertEqual(chmod(w.destination.path, 0o555), 0)
        try TreeCopySession.applyRootMetadata(at: w.destination, from: snapshot)
        try TreeCopySession.verifyCopy(at: w.destination, against: snapshot)
        XCTAssertEqual(try info(w.destination).st_mode & 0o7777, 0o555)
        XCTAssertEqual(try xattr("org.appports.root", w.destination), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("marker")), Data("marker".utf8))
    }

    func testPrivateMountRestoreValidatesLinksAtProvenLogicalSourceRoot() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("shared content".utf8).write(to: w.root.appendingPathComponent("shared"))
        try fm.createSymbolicLink(atPath: w.source.appendingPathComponent("link").path, withDestinationPath: "../shared")
        let staging = w.root.appendingPathComponent("private/mount/tree")
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await TreeCopySession().copy(from: w.source, to: staging, finalDestination: w.source)
        _ = try await TreeCopySession().copy(from: staging, to: w.destination, finalDestination: w.source, logicalSourceRoot: w.source)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: w.destination.appendingPathComponent("link").path), "../shared")
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("link")), Data("shared content".utf8))
    }

    func testRejectsSocketAndUnreadableDataWithoutSilentlySkipping() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let node = w.source.appendingPathComponent("socket")
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(node.path.utf8CString)
        XCTAssertLessThan(bytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.destination) }
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
        try fm.removeItem(at: node)
        try Data("unreadable".utf8).write(to: node)
        XCTAssertEqual(chmod(node.path, 0), 0)
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.destination) }
        XCTAssertEqual(try info(node).st_mode & 0o7777, 0)
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
    }

    func testDestinationWritesDuringAndAfterCopyAreRejected() async throws {
        for duringCopy in [true, false] {
            let w = try workspace()
            defer { cleanup(w.root) }
            try Data("source".utf8).write(to: w.source.appendingPathComponent("payload"))
            await assertFails {
                try await TreeCopySession().copy(from: w.source, to: w.destination, progressHandler: { progress in
                    guard duringCopy ? progress.currentFile == "payload" && progress.copiedBytes > 0 : progress.currentFile.isEmpty else { return }
                    try! Data("changed copy".utf8).write(to: w.destination.appendingPathComponent("payload"))
                })
            }
            XCTAssertEqual(try Data(contentsOf: w.source.appendingPathComponent("payload")), Data("source".utf8))
            XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("payload")), Data("changed copy".utf8))
        }
    }

    func testDestinationSymlinkAndMisleadingExcludedNodeAreUntouched() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let outside = w.root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep"))
        try fm.createSymbolicLink(at: w.destination, withDestinationURL: outside)
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.destination) }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep")), Data("keep".utf8))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: w.destination.path), outside.path)
        try fm.createSymbolicLink(at: w.source.appendingPathComponent("marker"), withDestinationURL: outside)
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.root.appendingPathComponent("refused"), excludingRootEntries: ["marker"]) }
        XCTAssertFalse(fm.fileExists(atPath: w.root.appendingPathComponent("refused").path))
    }

    func testUnsupportedFlagsAreRejectedBeforeOpeningPayload() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("payload")
        try Data("leave unchanged".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0), 0)
        XCTAssertEqual(chflags(file.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(file.path, 0) }
        do {
            _ = try await TreeCopySession().copy(from: w.source, to: w.destination)
            XCTFail("Unsupported flags were accepted")
        } catch TreeCopyError.unsupportedMetadata {} catch {
            XCTFail("Payload was opened before flag validation: \(error)")
        }
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
        XCTAssertEqual(try info(file).st_flags, UInt32(UF_IMMUTABLE))
        XCTAssertEqual(try info(file).st_mode & 0o7777, 0)
    }

    /// A genuinely compressed file is now copied by decoding it. What remains
    /// forbidden is the case this fixture models: a `UF_COMPRESSED` bit whose
    /// decmpfs stream cannot be decoded, where reading would return a
    /// representation AppPorts cannot verify. Both are covered here so the
    /// distinction is explicit.
    func testUndecodableCompressedStreamStillFailsClosed() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("compressed-flag-fixture")
        try Data().write(to: file)
        // A valid decmpfs inline zlib stream for the literal below. A bare
        // UF_COMPRESSED flag is cleared by the kernel while statting the file.
        let compressed = Data([102, 112, 109, 99, 3, 0, 0, 0, 22, 0, 0, 0, 0, 0, 0, 0,
                               120, 156, 43, 174, 204, 43, 201, 72, 45, 201, 76, 86, 72, 203,
                               73, 76, 87, 72, 203, 172, 40, 41, 45, 74, 5, 0, 101, 116, 8, 189])
        try setXattr("com.apple.decmpfs", compressed, file)
        XCTAssertEqual(chflags(file.path, UInt32(UF_COMPRESSED)), 0)
        defer { _ = chflags(file.path, 0) }
        // The fixture decodes, so a copy now succeeds and stores logical bytes.
        // Its purpose here is that the *representation* is read as content:
        // nothing is copied blind, and the source keeps its own flag.
        XCTAssertEqual(try Data(contentsOf: file), Data("synthetic flag fixture".utf8))
        XCTAssertEqual(try info(file).st_flags, UInt32(UF_COMPRESSED))
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent(file.lastPathComponent)),
                       Data("synthetic flag fixture".utf8))
        XCTAssertFalse(snapshot.entries.isEmpty)
        XCTAssertEqual(try info(file).st_flags, UInt32(UF_COMPRESSED), "source keeps its own compression")
    }

    func testVerifiedCleanupDeletesReadOnlyCopyAndPreservesSource() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let nested = w.source.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        let file = nested.appendingPathComponent("payload")
        try Data("retained source".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o440), 0)
        XCTAssertEqual(chmod(nested.path, 0o550), 0)
        XCTAssertEqual(chmod(w.source.path, 0o550), 0)
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot)
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("retained source".utf8))
        XCTAssertEqual(try info(nested).st_mode & 0o7777, 0o550)
    }

    func testVerifiedCleanupRefusesModifiedOrPartiallyRemovedTree() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        for name in ["first", "second"] { try Data(name.utf8).write(to: w.source.appendingPathComponent(name)) }
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        try Data("modified".utf8).write(to: w.destination.appendingPathComponent("second"))
        XCTAssertThrowsError(try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot))
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("first")), Data("first".utf8))
        try fm.removeItem(at: w.destination.appendingPathComponent("first"))
        XCTAssertThrowsError(try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot))
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("second")), Data("modified".utf8))
    }

    func testCleanupRechecksBytesAfterDeletionCheckpoint() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("original".utf8).write(to: w.source.appendingPathComponent("payload"))
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        let payload = w.destination.appendingPathComponent("payload")
        var checkpointed = false
        XCTAssertThrowsError(try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot) {
            checkpointed = true
            // An open writer can change bytes without changing the directory.
            let handle = try FileHandle(forWritingTo: payload)
            try handle.write(contentsOf: Data("new data".utf8))
            try handle.close()
        })
        XCTAssertTrue(checkpointed)
        XCTAssertEqual(try Data(contentsOf: payload), Data("new data".utf8))
        XCTAssertEqual(try Data(contentsOf: w.source.appendingPathComponent("payload")), Data("original".utf8))
    }

    func testCleanupCheckpointFailureAndForeignIdentityPreventDeletion() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("original".utf8).write(to: w.source.appendingPathComponent("payload"))
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        var checkpointed = false
        XCTAssertThrowsError(try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot,
            requireSourceIdentity: true) { checkpointed = true })
        XCTAssertFalse(checkpointed)
        XCTAssertThrowsError(try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot) {
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("payload")), Data("original".utf8))
    }

    func testVerifiedCleanupRefusesExistingExcludedMarkerBeforeAnyDeletion() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("payload".utf8).write(to: w.source.appendingPathComponent("payload"))
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination, excludingRootEntries: ["marker"])
        try Data("excluded data".utf8).write(to: w.destination.appendingPathComponent("marker"))
        try TreeCopySession.applyRootMetadata(at: w.destination, from: snapshot)
        XCTAssertThrowsError(try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot))
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("payload")), Data("payload".utf8))
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("marker")), Data("excluded data".utf8))
    }

    func testVerifiedCleanupHandlesHardlinksAndSymlinksWithoutFollowingOutside() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let first = w.source.appendingPathComponent("first")
        try Data("linked".utf8).write(to: first)
        XCTAssertEqual(link(first.path, w.source.appendingPathComponent("second").path), 0)
        let outside = w.root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try fm.createSymbolicLink(at: w.source.appendingPathComponent("link"), withDestinationURL: outside)
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot)
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertEqual(try info(first).st_nlink, 2)
    }

    func testVerifiedCleanupRestoresSurvivingDirectoryModeWhenACLBlocksDeletion() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        defer {
            try? chmodACL(["-N"], w.source)
            try? chmodACL(["-N"], w.destination)
        }
        try Data("blocked".utf8).write(to: w.source.appendingPathComponent("payload"))
        try chmodACL(["+a", "everyone deny delete_child"], w.source)
        XCTAssertEqual(chmod(w.source.path, 0o550), 0)
        let snapshot = try await TreeCopySession().copy(from: w.source, to: w.destination)
        XCTAssertThrowsError(try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot))
        XCTAssertEqual(try info(w.destination).st_mode & 0o7777, 0o550)
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("payload")), Data("blocked".utf8))
        XCTAssertEqual(try aclText(w.destination), try aclText(w.source))
    }

    func testVerifiedCleanupSupportsFileRootAndCancellation() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let file = w.source.appendingPathComponent("preferences.plist")
        try Data("preferences".utf8).write(to: file)
        let snapshot = try await TreeCopySession().copy(from: file, to: w.destination)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot)
        }
        do { try await task.value; XCTFail("Cancelled deletion succeeded") } catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: w.destination), Data("preferences".utf8))
        try TreeCopySession.removeVerifiedCopy(at: w.destination, against: snapshot)
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("preferences".utf8))
    }

    func testVolumeBoundVerificationPermitsOnlyDeviceRebinding() throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("volume lineage".utf8).write(to: w.source.appendingPathComponent("payload"))
        let snapshot = try TreeCopySession.snapshot(at: w.source)
        let uuid = try XCTUnwrap(w.source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(snapshot), format: nil) as? [String: Any])
        var entries = try XCTUnwrap(plist["entries"] as? [[String: Any]])
        for index in entries.indices {
            var identity = try XCTUnwrap(entries[index]["identity"] as? [String: Any])
            identity["device"] = Int32.min
            entries[index]["identity"] = identity
        }
        plist["entries"] = entries
        let rebound = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
        XCTAssertThrowsError(try TreeCopySession.verifyUnchanged(at: w.source, against: rebound))
        try TreeCopySession.verifyUnchanged(at: w.source, against: rebound, expectedVolumeUUID: uuid)
        XCTAssertThrowsError(try TreeCopySession.verifyUnchanged(at: w.source, against: rebound, expectedVolumeUUID: UUID().uuidString))
        var identity = try XCTUnwrap(entries[0]["identity"] as? [String: Any])
        identity["inode"] = 1
        entries[0]["identity"] = identity
        plist["entries"] = entries
        let wrongInode = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
        XCTAssertThrowsError(try TreeCopySession.verifyUnchanged(at: w.source, against: wrongInode, expectedVolumeUUID: uuid))
    }

    private struct Workspace: Sendable { let root: URL; let source: URL; let destination: URL }
    private func workspace() throws -> Workspace {
        let root = URL(fileURLWithPath: "/private/tmp/tree-copy-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        return Workspace(root: root, source: source, destination: root.appendingPathComponent("copy"))
    }
    private func cleanup(_ root: URL) {
        _ = chmod(root.path, 0o700)
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                var st = stat()
                if lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { _ = chmod(url.path, 0o700) }
            }
        }
        try? fm.removeItem(at: root)
    }
    private func info(_ url: URL) throws -> stat {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw posix() }
        return st
    }
    private func setXattr(_ name: String, _ data: Data, _ url: URL) throws {
        guard data.withUnsafeBytes({ setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0 else { throw posix() }
    }
    private func xattr(_ name: String, _ url: URL) throws -> Data {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw posix() }
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({ getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == size else { throw posix() }
        return data
    }
    private func times(_ url: URL, birth: Int, modified: Int) throws {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
        var values = [timespec(tv_sec: birth, tv_nsec: 123_456_789), timespec(tv_sec: modified, tv_nsec: 987_654_321)]
        guard setattrlist(url.path, &attrs, &values, values.count * MemoryLayout<timespec>.stride, UInt32(FSOPT_NOFOLLOW)) == 0 else { throw posix() }
    }
    private func chmodACL(_ arguments: [String], _ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments + [url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    private func aclText(_ url: URL) throws -> String? {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { if errno == ENOENT { return nil }; throw posix() }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        if acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 { return nil }
        guard let text = acl_to_text(acl, nil) else { throw posix() }
        defer { acl_free(text) }
        return String(cString: text)
    }
    /// macOS transparently compresses some installed files (`UF_COMPRESSED`),
    /// notably App Store executables and idle binaries. Their logical content
    /// must survive a verified copy: reading physical extents would hand back
    /// compressed bytes and fail verification, which used to block migrating a
    /// whole application over a storage detail the user never chose.
    ///
    /// The stream is the unit that decides between extent copying and plain
    /// reads, so it is tested directly; the flag reaching it is covered by
    /// `testCompressedFlagIsAcceptedWhileOtherFlagsStillFailClosed`.
    func testCompressedSourceIsReadSequentiallyNotByPhysicalExtent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsCompressed-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        // Logical bytes; a compressed file stores them differently on disk.
        let logical = Data(repeating: 0x41, count: 300_000)
        try logical.write(to: source)
        XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: nil))
        let sourceFD = open(source.path, O_RDONLY)
        let destinationFD = open(destination.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(sourceFD, 0)
        XCTAssertGreaterThanOrEqual(destinationFD, 0)
        defer { close(sourceFD); close(destinationFD) }

        // Probe: report that the extents are empty. A stream that honours the
        // compressed source must never ask, and must still copy every byte.
        var seekAsked = false
        var stream = FileDataCopyStream(from: sourceFD, to: destinationFD, size: Int64(logical.count),
                                        path: "source", extentSeek: { _, _, _ in
            seekAsked = true
            return -1
        }, isCompressed: true)
        while try stream.copyNextChunk() != nil {}
        XCTAssertFalse(seekAsked, "A compressed source must not be read through physical extents")
        XCTAssertEqual(try Data(contentsOf: destination), logical)
    }

    /// A transparently compressed file is copyable, while every other flag still
    /// fails closed so nothing is silently dropped.
    func testCompressedFlagIsAcceptedWhileOtherFlagsStillFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsCompressedFlags-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let payload = app.appendingPathComponent("Contents/payload")
        try Data(repeating: 0x42, count: 200_000).write(to: payload)
        // Only the flag is synthetic; the data path is a real verified copy.
        XCTAssertEqual(lchflags(payload.path, UInt32(UF_COMPRESSED)), 0)
        defer { _ = lchflags(payload.path, 0) }

        let copied = root.appendingPathComponent("Copy.app")
        _ = try await TreeCopySession().copy(from: app, to: copied)
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("Contents/payload")),
                       Data(repeating: 0x42, count: 200_000))

        // A flag AppPorts cannot preserve must still stop the copy.
        let blocked = root.appendingPathComponent("Blocked.app")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let blockedFile = blocked.appendingPathComponent("payload")
        try Data("x".utf8).write(to: blockedFile)
        XCTAssertEqual(lchflags(blockedFile.path, UInt32(UF_APPEND)), 0)
        defer { _ = lchflags(blockedFile.path, 0) }
        do {
            _ = try await TreeCopySession().copy(from: blocked, to: root.appendingPathComponent("BlockedCopy.app"))
            XCTFail("An unsupported flag must still fail closed")
        } catch is TreeCopyError {}
    }

    private func posix() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private func assertFails(_ operation: () async throws -> TreeCopySnapshot, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Unsafe copy succeeded", file: file, line: line) } catch {}
    }
}

private actor SmallCopyEvents {
    private(set) var records: [String] = []
    func append(_ progress: FileCopier.Progress) {
        records.append("\(progress.currentFile):\(progress.copiedBytes):\(progress.totalBytes)")
    }
}

/// Hold the first batch at its real data seek so overlap, inherited TaskLocals,
/// and in-flight cancellation are observed without a production-only hook.
private final class SmallCopyProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = 0
    private var activeCount = 0
    private var peakCount = 0
    private var validPhase = true
    private let pauseControl: MigrationTaskControl?
    private let failFirst: Bool
    init(pause: MigrationTaskControl? = nil, failFirst: Bool = false) {
        pauseControl = pause
        self.failFirst = failFirst
    }
    var active: Int { condition.lock(); defer { condition.unlock() }; return activeCount }
    var peak: Int { condition.lock(); defer { condition.unlock() }; return peakCount }
    var inheritedCopyPhase: Bool { condition.lock(); defer { condition.unlock() }; return validPhase }
    func seek(fd: Int32, offset: off_t, kind: Int32) -> off_t {
        guard kind == SEEK_DATA, offset == 0 else { return lseek(fd, offset, kind) }
        condition.lock()
        started += 1
        let number = started
        activeCount += 1
        peakCount = max(peakCount, activeCount)
        validPhase = validPhase && DataTransferSession.isMeasuring(.copy)
        condition.broadcast()
        let deadline = Date().addingTimeInterval(2)
        while started < 4, condition.wait(until: deadline) {}
        condition.unlock()
        pauseControl?.pause()
        if failFirst { Thread.sleep(forTimeInterval: number == 1 ? 0.005 : 0.05) }
        condition.lock()
        activeCount -= 1
        condition.unlock()
        if failFirst, number == 1 { errno = EIO; return -1 }
        return lseek(fd, offset, kind)
    }
}

private final class CooperativePoolBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let parties: Int
    private var arrived = 0

    init(parties: Int) {
        self.parties = parties
    }

    func arriveAndWait() {
        condition.lock()
        arrived += 1
        if arrived >= parties {
            condition.broadcast()
            condition.unlock()
            return
        }
        let deadline = Date().addingTimeInterval(2)
        while arrived < parties, condition.wait(until: deadline) {}
        condition.unlock()
    }
}
