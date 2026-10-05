import Darwin
import XCTest
@testable import AppPorts

final class FileCopierTests: XCTestCase {
    private let fileManager = FileManager.default

    func testDirectoryACLIsPreserved() async throws {
        let w = try makeWorkspace()
        defer { cleanup(w.root) }
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "everyone allow read,readattr,readextattr,readsecurity", w.source.path]
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        func aclText(_ url: URL) throws -> String {
            guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return "" }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard let text = acl_to_text(acl, nil) else { return "" }
            defer { acl_free(text) }
            return String(cString: text)
        }
        let original = try aclText(w.source)
        XCTAssertFalse(original.isEmpty)
        _ = try await FileCopier().copyDirectory(from: w.source, to: w.destination, progressHandler: nil)
        XCTAssertEqual(try aclText(w.destination), original)
        XCTAssertEqual(try aclText(w.source), original)
    }

    func testCopiesManySmallFilesWithRootAndNestedDirectoryMetadata() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        let nested = workspace.source.appendingPathComponent("Resources/Nested")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        for index in 0..<1500 {
            try Data("small payload \(index)".utf8).write(to: nested.appendingPathComponent("file-\(index).txt"))
        }

        let executable = workspace.source.appendingPathComponent("run")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o751], ofItemAtPath: executable.path)
        let directories = [workspace.source, workspace.source.appendingPathComponent("Resources"), nested]
        for directory in directories {
            try setAttribute("com.appports.test.directory", value: Data(directory.lastPathComponent.utf8), at: directory)
            try setAttribute("com.appports.test.empty", value: Data(), at: directory)
            try fileManager.setAttributes([
                .creationDate: Date(timeIntervalSince1970: 1_600_000_000),
                .modificationDate: Date(timeIntervalSince1970: 1_610_000_000),
                .posixPermissions: 0o550
            ], ofItemAtPath: directory.path)
        }
        try setAttribute("com.appports.test.file", value: Data("preserved".utf8), at: executable)

        let progress = ProgressRecorder()
        let copiedBytes = try await FileCopier(networkVolumeDetector: { _ in true }).copyDirectory(
            from: workspace.source,
            to: workspace.destination,
            progressHandler: { await progress.append($0) }
        )

        for index in 0..<1500 {
            let copied = workspace.destination.appendingPathComponent("Resources/Nested/file-\(index).txt")
            XCTAssertEqual(try Data(contentsOf: copied), Data("small payload \(index)".utf8))
        }
        let copiedExecutable = workspace.destination.appendingPathComponent("run")
        XCTAssertEqual(try permissions(at: copiedExecutable), 0o751)
        XCTAssertEqual(try attribute("com.appports.test.file", at: copiedExecutable), Data("preserved".utf8))
        for directory in directories {
            let suffix = String(directory.path.dropFirst(workspace.source.path.count))
            let copied = URL(fileURLWithPath: workspace.destination.path + suffix)
            XCTAssertEqual(try permissions(at: copied), 0o550)
            XCTAssertEqual(try attribute("com.appports.test.directory", at: copied), Data(directory.lastPathComponent.utf8))
            XCTAssertEqual(try attribute("com.appports.test.empty", at: copied), Data())
            let original = try fileManager.attributesOfItem(atPath: directory.path)
            let actual = try fileManager.attributesOfItem(atPath: copied.path)
            for key: FileAttributeKey in [.creationDate, .modificationDate] {
                let expectedDate = try XCTUnwrap(original[key] as? Date)
                let copiedDate = try XCTUnwrap(actual[key] as? Date)
                XCTAssertEqual(copiedDate.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
            }
        }
        let updates = await progress.values()
        let final = try XCTUnwrap(updates.last)
        let total = (0..<1500).reduce(Int64(0)) { $0 + Int64("small payload \($1)".utf8.count) } + Int64("#!/bin/sh\nexit 0\n".utf8.count)
        XCTAssertEqual(final.copiedBytes, total)
        XCTAssertEqual(final.totalBytes, total)
        XCTAssertEqual(copiedBytes, total)
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.copiedBytes <= $1.copiedBytes })
    }

    func testCopiesLinksWithoutFollowingThemAndSkipsManagedMetadataAndSockets() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        let outside = workspace.root.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try setAttribute("com.apple.quarantine", value: Data("0081;test;AppPorts;".utf8), at: outside)
        try fileManager.createSymbolicLink(atPath: workspace.source.appendingPathComponent("relative").path, withDestinationPath: "../outside")
        try fileManager.createSymbolicLink(atPath: workspace.source.appendingPathComponent("dangling").path, withDestinationPath: "missing-file")
        try fileManager.createSymbolicLink(atPath: workspace.source.appendingPathComponent("absolute").path, withDestinationPath: outside.path)
        for name in [".appports-link-metadata.plist", ".payload.appports-link-metadata.plist"] {
            try Data("management-only".utf8).write(to: workspace.source.appendingPathComponent(name))
        }
        let socketDescriptor = try makeSocket(at: workspace.source.appendingPathComponent("ipc.sock"))
        defer { close(socketDescriptor) }

        try await FileCopier().copyDirectory(
            from: workspace.source,
            to: workspace.destination,
            removeQuarantine: true,
            progressHandler: nil
        )

        for (name, target) in [("relative", "../outside"), ("dangling", "missing-file"), ("absolute", outside.path)] {
            XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: workspace.destination.appendingPathComponent(name).path), target)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.destination.appendingPathComponent(".appports-link-metadata.plist").path))
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.destination.appendingPathComponent(".payload.appports-link-metadata.plist").path))
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.destination.appendingPathComponent("ipc.sock").path))
        XCTAssertNotNil(try attribute("com.apple.quarantine", at: outside))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep.txt")), Data("outside".utf8))
    }

    func testSourceSymlinkIsCopiedAsALink() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        let sourceLink = workspace.root.appendingPathComponent("source-link")
        try fileManager.createSymbolicLink(at: sourceLink, withDestinationURL: workspace.source)
        try Data("content".utf8).write(to: workspace.source.appendingPathComponent("payload"))

        try await FileCopier().copyDirectory(from: sourceLink, to: workspace.destination, progressHandler: nil)

        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: workspace.destination.path), workspace.source.path)
    }

    func testQuarantineRemovalPreservesOtherAttributesAndTheSource() async throws {
        for removeQuarantine in [false, true] {
            let workspace = try makeWorkspace()
            defer { cleanup(workspace.root) }
            let child = workspace.source.appendingPathComponent("child")
            try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
            let file = child.appendingPathComponent("payload")
            try Data("payload".utf8).write(to: file)
            for item in [workspace.source, child, file] {
                try setAttribute("com.apple.quarantine", value: Data("0081;test;AppPorts;".utf8), at: item)
                try setAttribute("com.appports.test.keep", value: Data("keep".utf8), at: item)
            }

            try await FileCopier().copyDirectory(
                from: workspace.source,
                to: workspace.destination,
                removeQuarantine: removeQuarantine,
                progressHandler: nil
            )

            for suffix in ["", "/child", "/child/payload"] {
                let source = URL(fileURLWithPath: workspace.source.path + suffix)
                let target = URL(fileURLWithPath: workspace.destination.path + suffix)
                XCTAssertNotNil(try attribute("com.apple.quarantine", at: source))
                XCTAssertEqual(try attribute("com.appports.test.keep", at: target), Data("keep".utf8))
                if removeQuarantine {
                    XCTAssertNil(try attribute("com.apple.quarantine", at: target))
                } else {
                    XCTAssertNotNil(try attribute("com.apple.quarantine", at: target))
                }
            }
        }
    }

    func testSingleFileRetainsPermissionsAndReportsActualSize() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        let file = workspace.source.appendingPathComponent("tool")
        try Data("executable".utf8).write(to: file)
        try fileManager.setAttributes([.posixPermissions: 0o751], ofItemAtPath: file.path)
        try setAttribute("com.appports.test.keep", value: Data("keep".utf8), at: file)
        let recorder = ProgressRecorder()

        try await FileCopier().copyDirectory(
            from: file,
            to: workspace.destination,
            estimatedTotalBytes: 900,
            progressHandler: { await recorder.append($0) }
        )

        XCTAssertEqual(try Data(contentsOf: workspace.destination), Data("executable".utf8))
        XCTAssertEqual(try permissions(at: workspace.destination), 0o751)
        XCTAssertEqual(try attribute("com.appports.test.keep", at: workspace.destination), Data("keep".utf8))
        let updates = await recorder.values()
        let final = try XCTUnwrap(updates.last)
        XCTAssertEqual(final.copiedBytes, 10)
        XCTAssertEqual(final.totalBytes, 10)
    }

    func testNetworkCopiesAreConcurrentAndBoundedForEitherEndpoint() async throws {
        for networkSource in [false, true] {
            let workspace = try makeWorkspace()
            defer { cleanup(workspace.root) }
            try createPayloads(count: 16, in: workspace.source)
            let probe = CopyProbe(firstBatchSize: 4)
            let networkEndpoint = networkSource ? workspace.source : workspace.destination
            let copier = FileCopier(
                networkVolumeDetector: { $0.standardizedFileURL == networkEndpoint.standardizedFileURL },
                copyOperation: { source, destination in
                    await probe.begin()
                    do {
                        try FileManager.default.copyItem(at: source, to: destination)
                        await probe.finish()
                    } catch {
                        await probe.finish()
                        throw error
                    }
                }
            )

            try await copier.copyDirectory(from: workspace.source, to: workspace.destination, progressHandler: nil)

            let stats = await probe.snapshot()
            XCTAssertEqual(stats.peak, 4)
            XCTAssertEqual(stats.started, 16)
            XCTAssertEqual(stats.finished, 16)
            XCTAssertEqual(stats.active, 0)
            XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: workspace.destination.path).count, 16)
        }
    }

    func testLocalCopiesRemainSerial() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        try createPayloads(count: 16, in: workspace.source)
        let probe = CopyProbe(firstBatchSize: 1)
        let copier = FileCopier(
            networkVolumeDetector: { _ in false },
            copyOperation: { source, destination in
                await probe.begin()
                await Task.yield()
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    await probe.finish()
                } catch {
                    await probe.finish()
                    throw error
                }
            }
        )

        try await copier.copyDirectory(from: workspace.source, to: workspace.destination, progressHandler: nil)

        let stats = await probe.snapshot()
        XCTAssertEqual(stats.peak, 1)
        XCTAssertEqual(stats.finished, 16)
        XCTAssertEqual(stats.active, 0)
    }

    func testFailureWaitsForAllInFlightWritesBeforeReturning() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        try createPayloads(count: 4, in: workspace.source)
        let probe = CopyProbe(firstBatchSize: 4)
        let cancelled = AsyncGate()
        let copier = FileCopier(
            networkVolumeDetector: { _ in true },
            copyOperation: { source, destination in
                await probe.begin()
                if source.lastPathComponent == "file-0" {
                    await probe.finish()
                    throw TestError.copyFailed
                }
                // 模拟不能中断的系统写入：收到取消后仍会完成写入。
                await withTaskCancellationHandler(operation: {
                    await cancelled.wait()
                }, onCancel: {
                    Task { await cancelled.open() }
                })
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    await probe.finish()
                } catch {
                    await probe.finish()
                    throw error
                }
            }
        )

        do {
            try await copier.copyDirectory(from: workspace.source, to: workspace.destination, progressHandler: nil)
            XCTFail("Expected the file copy failure")
        } catch TestError.copyFailed {
            // 传播原始失败，不被其他任务的 CancellationError 覆盖。
        }

        let stats = await probe.snapshot()
        XCTAssertEqual(stats.active, 0)
        XCTAssertEqual(stats.started, 4)
        XCTAssertEqual(stats.finished, 4)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: workspace.destination.path).count, 3)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: workspace.source.path).count, 4)
        try fileManager.removeItem(at: workspace.destination)
        await Task.yield()
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.destination.path))
    }

    func testUnknownSizeAndSlowSmallFilesKeepReportingProgress() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        try createPayloads(count: 8, in: workspace.source)
        let clock = ManualClock()
        let recorder = ProgressRecorder()
        let copier = FileCopier(
            networkVolumeDetector: { _ in false },
            copyOperation: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                clock.advance(by: 0.3)
            },
            clock: { clock.now() }
        )

        try await copier.copyDirectory(
            from: workspace.source,
            to: workspace.destination,
            progressHandler: { await recorder.append($0) }
        )

        let updates = await recorder.values()
        XCTAssertEqual(updates.first?.copiedBytes, 0)
        XCTAssertEqual(updates.count, 10)
        XCTAssertTrue(updates.dropLast().allSatisfy { $0.totalBytes == 0 })
        XCTAssertTrue(updates.dropFirst().dropLast().allSatisfy { !$0.currentFile.isEmpty && $0.copiedBytes > 0 })
        XCTAssertEqual(updates.last?.totalBytes, updates.last?.copiedBytes)
    }

    func testExistingEstimateIsUsedWithoutPreventingAnAccurateFinalTotal() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        try createPayloads(count: 4, in: workspace.source)
        let clock = ManualClock()
        let recorder = ProgressRecorder()
        let copier = FileCopier(
            copyOperation: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                clock.advance(by: 0.3)
            },
            clock: { clock.now() }
        )

        try await copier.copyDirectory(
            from: workspace.source,
            to: workspace.destination,
            estimatedTotalBytes: 1,
            progressHandler: { await recorder.append($0) }
        )

        let updates = await recorder.values()
        XCTAssertTrue(updates.dropLast().allSatisfy { $0.totalBytes == 1 })
        XCTAssertTrue(updates.allSatisfy { (0...1).contains($0.percentage) })
        let final = try XCTUnwrap(updates.last)
        XCTAssertGreaterThan(final.totalBytes, 1)
        XCTAssertEqual(final.totalBytes, final.copiedBytes)
    }

    func testDirectoriesLinksAndEmptyFilesTriggerItemProgress() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        for index in 0..<60 {
            try fileManager.createDirectory(at: workspace.source.appendingPathComponent("directory-\(index)"), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: workspace.source.appendingPathComponent("link-\(index)").path, withDestinationPath: "missing")
            try Data().write(to: workspace.source.appendingPathComponent("empty-\(index)"))
        }
        let recorder = ProgressRecorder()
        let copier = FileCopier(clock: { 0 })

        try await copier.copyDirectory(from: workspace.source, to: workspace.destination, progressHandler: { await recorder.append($0) })

        let updates = await recorder.values()
        XCTAssertGreaterThanOrEqual(updates.count, 5)
        XCTAssertTrue(updates.allSatisfy { $0.copiedBytes == 0 })
        XCTAssertTrue(updates.dropFirst().dropLast().allSatisfy { !$0.currentFile.isEmpty })
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: workspace.destination.path).count, 180)
    }

    func testRejectsCopyIntoSourceAndDestinationDirectorySymlinks() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        try createPayloads(count: 1, in: workspace.source)
        do {
            try await FileCopier().copyDirectory(from: workspace.source, to: workspace.source.appendingPathComponent("nested"), progressHandler: nil)
            XCTFail("Expected a destination inside the source to be rejected")
        } catch {}
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.source.appendingPathComponent("nested").path))

        let outside = workspace.root.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: workspace.destination, withDestinationURL: outside)
        do {
            try await FileCopier().copyDirectory(from: workspace.source, to: workspace.destination, progressHandler: nil)
            XCTFail("Expected a destination symlink to be rejected")
        } catch {}
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testNetworkVolumeDetectionUsesExistingParentOfNewDestination() throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        let nested = workspace.destination.appendingPathComponent("does/not/exist")
        XCTAssertEqual(FileCopier.isNetworkVolume(at: nested), FileCopier.isNetworkVolume(at: workspace.root))
    }

    func testCopyThroughAnAncestorSymlinkKeepsRelativePaths() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        let nested = workspace.source.appendingPathComponent("Contents/Resources")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nested.appendingPathComponent("payload"))
        let alias = workspace.root.appendingPathComponent("short")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: workspace.source)
        let sourceThroughAlias = alias.appendingPathComponent("Contents")

        try await FileCopier().copyDirectory(from: sourceThroughAlias, to: workspace.destination, progressHandler: nil)

        XCTAssertEqual(try Data(contentsOf: workspace.destination.appendingPathComponent("Resources/payload")), Data("payload".utf8))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: workspace.destination.path), ["Resources"])
    }

    func testExistingDirectoryIsNeverRemovedToMakeRoomForAFile() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        try createPayloads(count: 1, in: workspace.source)
        let existingDirectory = workspace.destination.appendingPathComponent("file-0")
        try fileManager.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        let existingFile = existingDirectory.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: existingFile)

        do {
            try await FileCopier().copyDirectory(from: workspace.source, to: workspace.destination, progressHandler: nil)
            XCTFail("Expected a conflicting destination directory to cause a failure")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: existingFile), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: workspace.source.appendingPathComponent("file-0")), Data("payload-0".utf8))
    }

    func testPreservesRootAndNestedDirectoryGroupsLikeFoundationCreation() async throws {
        let groupCount = getgroups(0, nil)
        guard groupCount > 0 else { throw XCTSkip("No supplementary groups available") }
        var groups = [gid_t](repeating: 0, count: Int(groupCount))
        guard getgroups(groupCount, &groups) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let alternateGroup = groups.contains(80) ? gid_t(80) : groups.first { $0 != getegid() }
        guard let groupID = alternateGroup, groupID != getegid() else {
            throw XCTSkip("A supplementary group different from the default group is required")
        }
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        let nested = workspace.source.appendingPathComponent("GroupShared")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: nested.appendingPathComponent("payload"))
        for directory in [workspace.source, nested] {
            try fileManager.setAttributes([.groupOwnerAccountID: NSNumber(value: groupID), .posixPermissions: 0o770], ofItemAtPath: directory.path)
        }
        let originalAttributes = try fileManager.attributesOfItem(atPath: nested.path)
        let legacyDirectory = workspace.root.appendingPathComponent("legacy")
        try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: false, attributes: originalAttributes)
        let legacyAttributes = try fileManager.attributesOfItem(atPath: legacyDirectory.path)
        let legacyGroup = try XCTUnwrap(legacyAttributes[.groupOwnerAccountID] as? NSNumber)
        XCTAssertEqual(legacyGroup.uint32Value, groupID)

        try await FileCopier().copyDirectory(from: workspace.source, to: workspace.destination, progressHandler: nil)

        for directory in [workspace.destination, workspace.destination.appendingPathComponent("GroupShared")] {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let actualGroup = try XCTUnwrap(attributes[.groupOwnerAccountID] as? NSNumber)
            XCTAssertEqual(actualGroup, legacyGroup)
            XCTAssertEqual(try permissions(at: directory), 0o770)
        }
        XCTAssertEqual(try Data(contentsOf: workspace.destination.appendingPathComponent("GroupShared/payload")), Data("shared".utf8))
    }

    func testRemoveCopyDeletesReadOnlyTreesWithoutChangingLinkedOutsideData() async throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        let nested = workspace.source.appendingPathComponent("Nested/Deep")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: nested.appendingPathComponent("payload"))
        let outside = workspace.root.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("keep"))
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outside.path)
        try fileManager.createSymbolicLink(at: workspace.source.appendingPathComponent("outside-link"), withDestinationURL: outside)
        for directory in [workspace.source, workspace.source.appendingPathComponent("Nested"), nested] {
            try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        try await FileCopier().copyDirectory(from: workspace.source, to: workspace.destination, progressHandler: nil)
        // 覆盖缺少 read/execute 权限的部分副本：不能先枚举再放开父目录权限。
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: workspace.destination.appendingPathComponent("Nested").path)
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: workspace.destination.path)

        try FileCopier.removeCopy(at: workspace.destination)

        XCTAssertFalse(fileManager.fileExists(atPath: workspace.destination.path))
        XCTAssertEqual(try permissions(at: workspace.source), 0o500)
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("payload")), Data("source".utf8))
        XCTAssertEqual(try permissions(at: outside), 0o500)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep")), Data("outside".utf8))
    }

    func testRemoveCopyTreatsRootSymlinkAndRegularFileAsLeaves() throws {
        let workspace = try makeWorkspace()
        defer { cleanup(workspace.root) }
        try Data("keep".utf8).write(to: workspace.source.appendingPathComponent("payload"))
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: workspace.source.path)
        try fileManager.createSymbolicLink(at: workspace.destination, withDestinationURL: workspace.source)

        try FileCopier.removeCopy(at: workspace.destination)

        var info = stat()
        XCTAssertNotEqual(lstat(workspace.destination.path, &info), 0)
        XCTAssertEqual(try permissions(at: workspace.source), 0o500)
        XCTAssertEqual(try Data(contentsOf: workspace.source.appendingPathComponent("payload")), Data("keep".utf8))
        try Data("delete".utf8).write(to: workspace.destination)
        try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: workspace.destination.path)
        try FileCopier.removeCopy(at: workspace.destination)
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.destination.path))
    }

    func testRemoveCopyRestoresSurvivingDirectoryModesWhenDeletionFails() throws {
        let workspace = try makeWorkspace()
        let nested = workspace.destination.appendingPathComponent("Nested")
        let lockedFile = nested.appendingPathComponent("locked")
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.destination.path)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
            try? fileManager.setAttributes([.immutable: false], ofItemAtPath: lockedFile.path)
            cleanup(workspace.root)
        }
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("locked".utf8).write(to: lockedFile)
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: lockedFile.path)
        try fileManager.setAttributes([.posixPermissions: 0o100], ofItemAtPath: nested.path)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: workspace.destination.path)

        XCTAssertThrowsError(try FileCopier.removeCopy(at: workspace.destination)) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error.code, NSFileWriteNoPermissionError)
        }

        XCTAssertEqual(try permissions(at: workspace.destination), 0o500)
        XCTAssertEqual(try permissions(at: nested), 0o100)
        XCTAssertEqual(try Data(contentsOf: lockedFile), Data("locked".utf8))
    }

    private enum TestError: Error {
        case copyFailed
    }

    private struct Workspace {
        let root: URL
        let source: URL
        let destination: URL
    }

    private func makeWorkspace() throws -> Workspace {
        // UNIX socket 的路径长度有限，用较短的临时路径，且每个测试独占目录。
        let root = URL(fileURLWithPath: "/tmp/AppPortsCopy-\(UUID().uuidString.prefix(12))")
        let source = root.appendingPathComponent("source")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        return Workspace(root: root, source: source, destination: root.appendingPathComponent("destination"))
    }

    private func createPayloads(count: Int, in directory: URL) throws {
        for index in 0..<count {
            try Data("payload-\(index)".utf8).write(to: directory.appendingPathComponent("file-\(index)"))
        }
    }

    private func cleanup(_ root: URL) {
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileResourceTypeKey]) {
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.fileResourceTypeKey]))?.fileResourceType == .directory {
                    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
            }
        }
        try? fileManager.removeItem(at: root)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func setAttribute(_ name: String, value: Data, at url: URL) throws {
        let result = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func attribute(_ name: String, at url: URL) throws -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if size == 0 { return Data() }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        if count < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return data.prefix(count)
    }

    private func makeSocket(at url: URL) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return descriptor
    }

    private actor ProgressRecorder {
        private var progress: [FileCopier.Progress] = []
        func append(_ value: FileCopier.Progress) { progress.append(value) }
        func values() -> [FileCopier.Progress] { progress }
    }

    private actor CopyProbe {
        private let firstBatchSize: Int
        private var active = 0
        private var peak = 0
        private var started = 0
        private var finished = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(firstBatchSize: Int) { self.firstBatchSize = firstBatchSize }

        func begin() async {
            active += 1
            started += 1
            peak = max(peak, active)
            if started < firstBatchSize {
                await withCheckedContinuation { waiters.append($0) }
            } else if started == firstBatchSize {
                let ready = waiters
                waiters.removeAll()
                ready.forEach { $0.resume() }
            }
        }

        func finish() {
            active -= 1
            finished += 1
        }

        func snapshot() -> (active: Int, peak: Int, started: Int, finished: Int) {
            (active, peak, started, finished)
        }
    }

    private actor AsyncGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let ready = waiters
            waiters.removeAll()
            ready.forEach { $0.resume() }
        }
    }

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0

        func now() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return time
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            time += interval
        }
    }
}
