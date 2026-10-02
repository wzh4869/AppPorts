import Darwin
import Foundation
import XCTest
@testable import AppPorts

final class TreeCopySessionTests: XCTestCase {
    private let fm = FileManager.default

    func testSystemProvenanceIsDiagnosticWhileApplicationXattrsRemainStrict() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("content".utf8).write(to: w.source.appendingPathComponent("payload"))
        let baseline = try await TreeCopySession().copy(from: w.source, to: w.destination)
        var raw = try XCTUnwrap(try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(baseline), format: nil) as? [String: Any])
        var entries = try XCTUnwrap(raw["entries"] as? [[String: Any]])
        var attributes = try XCTUnwrap(entries[0]["extendedAttributes"] as? [String: Data])
        attributes["com.apple.provenance"] = Data("old OS provenance".utf8)
        entries[0]["extendedAttributes"] = attributes
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

    func testRejectsSpecialNodesAndImmutableFlagBeforeCreatingDestination() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        let fifo = w.source.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        await assertFails { try await TreeCopySession().copy(from: w.source, to: w.destination) }
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
        try fm.removeItem(at: fifo)
        try Data("locked".utf8).write(to: fifo)
        XCTAssertEqual(chflags(fifo.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(fifo.path, 0) }
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
        XCTAssertThrowsError(try TreeCopySession.verifyCopy(at: w.destination, against: snapshot))
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

    func testFinalCallbackDestinationWriteIsAlsoRejected() async throws {
        let w = try workspace()
        defer { cleanup(w.root) }
        try Data("source".utf8).write(to: w.source.appendingPathComponent("payload"))
        await assertFails {
            try await TreeCopySession().copy(from: w.source, to: w.destination, progressHandler: { progress in
                guard progress.currentFile.isEmpty else { return }
                try! Data("changed copy".utf8).write(to: w.destination.appendingPathComponent("payload"))
            })
        }
        XCTAssertEqual(try Data(contentsOf: w.source.appendingPathComponent("payload")), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: w.destination.appendingPathComponent("payload")), Data("changed copy".utf8))
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

    func testCompressedFlagFailsClosedBeforePayloadRead() async throws {
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
        XCTAssertEqual(try Data(contentsOf: file), Data("synthetic flag fixture".utf8))
        XCTAssertEqual(try info(file).st_flags, UInt32(UF_COMPRESSED))
        XCTAssertEqual(chmod(file.path, 0), 0)
        do {
            _ = try await TreeCopySession().copy(from: w.source, to: w.destination)
            XCTFail("Unverified compressed representation was accepted")
        } catch TreeCopyError.unsupportedMetadata {} catch {
            XCTFail("Compressed payload was accessed: \(error)")
        }
        XCTAssertFalse(fm.fileExists(atPath: w.destination.path))
        XCTAssertEqual(try info(file).st_flags, UInt32(UF_COMPRESSED))
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
    private func posix() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private func assertFails(_ operation: () async throws -> TreeCopySnapshot, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Unsafe copy succeeded", file: file, line: line) } catch {}
    }
}
