import Darwin
import XCTest
@testable import AppPorts

final class TreeCopySessionQuarantineTests: XCTestCase {
    func testVerificationIgnoresQuarantineButKeepsApplicationAttributes() throws {
        let base = URL(fileURLWithPath: "/Volumes/SanDisk/Projects/AppPorts/.tmp-diag")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("TreeCopyQuarantine-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("payload")
        try Data("payload".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try TreeCopySession.snapshot(at: source, profile: .appBundle)
        // Older manifests replayed the source quarantine into the ledger, so a
        // recorded marker must not fail verification against a clean replica.
        let quarantinedSnapshot = withInjectedAttribute(snapshot, key: "com.apple.quarantine",
                                                        value: Data("0081;test;AppPorts;".utf8))

        let replica = root.appendingPathComponent("Replica", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: replica)
        XCTAssertNoThrow(try TreeCopySession.verifyCopy(at: replica, against: quarantinedSnapshot, profile: .appBundle),
                         "a recorded quarantine must not fail verification of a clean replica")

        let applicationSnapshot = withInjectedAttribute(snapshot, key: "com.appports.test",
                                                        value: Data("keep".utf8))
        XCTAssertThrowsError(try TreeCopySession.verifyCopy(at: replica, against: applicationSnapshot, profile: .appBundle),
                             "application attributes must still participate in verification")
    }

    private func withInjectedAttribute(_ snapshot: TreeCopySnapshot, key: String, value: Data) -> TreeCopySnapshot {
        var entries = snapshot.entries
        for index in entries.indices where entries[index].path == "payload" {
            var attributes = entries[index].extendedAttributes
            attributes[key] = value
            entries[index] = TreeCopySnapshot.Entry(path: entries[index].path, kind: entries[index].kind,
                identity: entries[index].identity, mode: entries[index].mode, uid: entries[index].uid,
                gid: entries[index].gid, flags: entries[index].flags, birthTime: entries[index].birthTime,
                modificationTime: entries[index].modificationTime, extendedAttributes: attributes,
                resourceFork: entries[index].resourceFork, acl: entries[index].acl, size: entries[index].size,
                digest: entries[index].digest, linkTarget: entries[index].linkTarget,
                hardlinkGroup: entries[index].hardlinkGroup)
        }
        return TreeCopySnapshot(restoredRootOwnership: snapshot.restoredRootOwnership,
            ownershipCompatibility: snapshot.ownershipCompatibility, entries: entries,
            excludedRootEntries: snapshot.excludedRootEntries)
    }
}
