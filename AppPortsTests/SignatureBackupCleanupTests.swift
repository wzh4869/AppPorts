import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Unused signature backup cleanup")
struct SignatureBackupCleanupTests {
    @Test("An unused pre-signing snapshot and its record are retired without changing the app")
    func discardsVerifiedDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let appIdentity = try DataPathIdentity.capture(fixture.app)
        let snapshot = try fixture.snapshot()

        #expect(try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier))
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
        #expect(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent(snapshot.lastPathComponent).path))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
        #expect(try DataPathIdentity.capture(fixture.app) == appIdentity)
        #expect(try await !signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier))
    }

    @Test("An application that still has a replacement signature keeps a usable original")
    func preservesNeededOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let signed = try SignatureSnapshot.fingerprint(of: fixture.app)
        #expect(signed != original)
        #expect(try await !signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier))
        #expect(FileManager.default.fileExists(atPath: fixture.record.path))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == signed)
        try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
    }

    @Test("A different, unavailable or changed application cannot retire the original", arguments: ["content", "bundle-id", "offline", "second-copy"])
    func preservesUnprovenApplication(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let record = try Data(contentsOf: fixture.record)
        var current = fixture.app
        switch change {
        case "content": try Data("new application version".utf8).write(to: fixture.payload)
        case "bundle-id":
            let info = fixture.app.appendingPathComponent("Contents/Info.plist")
            var plist = try fixture.plist(info)
            plist["CFBundleIdentifier"] = "com.appports.tests.different"
            try fixture.write(plist, at: info)
        case "offline": try FileManager.default.moveItem(at: fixture.app, to: fixture.root.appendingPathComponent("Offline.app"))
        default:
            current = fixture.root.appendingPathComponent("Second.app")
            try SignatureSnapshot.copy(from: fixture.app, to: current)
            try Data("changed recorded application".utf8).write(to: fixture.payload)
        }
        #expect(try await !signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier, appURL: current))
        #expect(try Data(contentsOf: fixture.record) == record)
        #expect(try FileManager.default.fileExists(atPath: fixture.snapshot().path))
    }

    @Test("A moved application needs its recorded entry to identify the same real app", arguments: [false, true])
    func resolvesMovedApplication(portal: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let moved = fixture.root.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: fixture.app, to: moved)
        if portal { try FileManager.default.createSymbolicLink(at: fixture.app, withDestinationURL: moved) }
        #expect(try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier, appURL: portal ? fixture.app : moved) == portal)
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test("An offline re-signed app keeps its original even when another installed copy matches the snapshot")
    func preservesOfflineAppRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let second = fixture.root.appendingPathComponent("Second.app")
        try SignatureSnapshot.copy(from: fixture.app, to: second)
        let signer = fixture.signer()
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let moved = fixture.root.appendingPathComponent("MovedSigned.app")
        try FileManager.default.moveItem(at: fixture.app, to: moved)
        let record = try Data(contentsOf: fixture.record)
        #expect(try await !signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier, appURL: second))
        #expect(try Data(contentsOf: fixture.record) == record)
        try await signer.restoreSignature(appURL: moved, bundleIdentifier: fixture.identifier)
        #expect(try SignatureSnapshot.fingerprint(of: moved) == SignatureSnapshot.fingerprint(of: second))
    }

    @Test("An entry pointing at the snapshot itself can never cause the live app to be trashed")
    func rejectsLiveSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let snapshot = try fixture.snapshot()
        let record = try Data(contentsOf: fixture.record)
        try FileManager.default.moveItem(at: fixture.app, to: fixture.root.appendingPathComponent("Moved.app"))
        try FileManager.default.createSymbolicLink(at: fixture.app, withDestinationURL: snapshot)
        await #expect(throws: (any Error).self) {
            try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier, appURL: fixture.app)
        }
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try Data(contentsOf: fixture.record) == record)
    }

    @Test("Changed, missing or substituted snapshots are preserved with their record", arguments: ["content", "missing", "symlink"])
    func rejectsInvalidSnapshot(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let snapshot = try fixture.snapshot()
        let record = try Data(contentsOf: fixture.record)
        if change == "content" {
            try Data("unexplained change".utf8).write(to: snapshot.appendingPathComponent("Contents/Resources/payload"))
        } else {
            try FileManager.default.moveItem(at: snapshot, to: fixture.root.appendingPathComponent("Saved.app"))
            if change == "symlink" { try FileManager.default.createSymbolicLink(at: snapshot, withDestinationURL: fixture.app) }
        }
        await #expect(throws: (any Error).self) {
            try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        #expect(try Data(contentsOf: fixture.record) == record)
        #expect(FileManager.default.fileExists(atPath: fixture.payload.path))
    }

    @Test("Trash failure keeps the checkpoint and full snapshot available for a later retry")
    func retriesTrashFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer(trash: { _ in throw Expected.failure })
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let snapshot = try fixture.snapshot()
        await #expect(throws: Expected.self) {
            try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try fixture.plist(fixture.record)["cleanup"] != nil)
        #expect(try await fixture.signer().discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier))
    }

    @Test("Trash completion followed by a record-write failure resumes after reopening", arguments: [false, true])
    func retriesRecordRemovalFailure(restore: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer(deleteRecord: { _ in throw Expected.failure })
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        if restore {
            try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
            try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        } else {
            try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
            await #expect(throws: Expected.self) {
                try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
            }
        }
        #expect(try fixture.plist(fixture.record)["cleanup"] != nil)
        #expect(try !FileManager.default.fileExists(atPath: fixture.snapshot().path))
        if restore {
            try await fixture.signer().restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        } else {
            #expect(try await fixture.signer().discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
    }

    @Test("A pending cleanup can finish without a later signature creating another permanent backup")
    func signingAfterCleanupInterruption() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer(deleteRecord: { _ in throw Expected.failure })
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let oldSnapshot = try fixture.snapshot()
        await #expect(throws: Expected.self) {
            try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        let reopened = fixture.signer()
        try await reopened.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        try await reopened.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(!FileManager.default.fileExists(atPath: oldSnapshot.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
        #expect(try FileManager.default.contentsOfDirectory(at: fixture.backups, includingPropertiesForKeys: nil).allSatisfy { $0.pathExtension != "app" })
        #expect(try await !reopened.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier))
    }

    @Test("A replaced parent cannot inherit authorization for a missing snapshot")
    func rejectsReplacedParent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer(deleteRecord: { _ in throw Expected.failure })
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        await #expect(throws: Expected.self) {
            try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        let record = try Data(contentsOf: fixture.record)
        try FileManager.default.moveItem(at: fixture.backups, to: fixture.root.appendingPathComponent("OldBackups"))
        try FileManager.default.createDirectory(at: fixture.backups, withIntermediateDirectories: false)
        try record.write(to: fixture.record)
        await #expect(throws: (any Error).self) {
            try await fixture.signer().discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        #expect(try Data(contentsOf: fixture.record) == record)
    }

    @Test("A record or app changed during Trash completion is not silently finalized", arguments: [false, true])
    func rejectsChangeDuringCleanup(changeApp: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer(trash: { snapshot in
            try fixture.moveToFixtureTrash(snapshot)
            if changeApp {
                try Data("concurrent update".utf8).write(to: fixture.payload)
            } else {
                var record = try fixture.plist(fixture.record)
                record["backupDate"] = Date.distantFuture
                try fixture.write(record, at: fixture.record)
            }
        })
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        await #expect(throws: (any Error).self) {
            try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.record.path))
        if !changeApp { #expect(try fixture.plist(fixture.record)["backupDate"] as? Date == .distantFuture) }
    }

    @Test("No backup and legacy records do not create new storage or invent deletion permission", arguments: [false, true])
    func preservesLegacyOrMissingRecord(legacy: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if legacy {
            try FileManager.default.createDirectory(at: fixture.backups, withIntermediateDirectories: false)
            try fixture.write(["bundleIdentifier": fixture.identifier, "signingIdentity": "ad-hoc",
                               "originalPath": fixture.app.path, "backupDate": Date()], at: fixture.record)
        }
        #expect(try await !fixture.signer().discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier))
        #expect(FileManager.default.fileExists(atPath: fixture.record.path) == legacy)
        #expect(FileManager.default.fileExists(atPath: fixture.backups.path) == legacy)
    }

    @Test("Unused backup cleanup observes the existing cross-process signature lock")
    func respectsSignatureLock() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let before = try Data(contentsOf: fixture.record)
        let lock = OperationLock(fileURL: fixture.backups.appendingPathComponent("signature-operation.lock"))
        try #require(lock.tryAcquire())
        defer { lock.release() }
        do {
            _ = try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
            Issue.record("An occupied signature lock must prevent backup cleanup")
        } catch let error as OperationBlockage {
            #expect(error.reason == .signatureLockBusy)
        }
        #expect(try Data(contentsOf: fixture.record) == before)
    }

    private enum Expected: Error { case failure }

    private struct Fixture: Sendable {
        let root: URL
        let identifier = "com.appports.tests.cleanup." + UUID().uuidString.lowercased()
        var app: URL { root.appendingPathComponent("Current.app") }
        var backups: URL { root.appendingPathComponent("SignatureBackups") }
        var record: URL { backups.appendingPathComponent(identifier + ".plist") }
        var payload: URL { app.appendingPathComponent("Contents/Resources/payload") }
        var trash: URL { root.appendingPathComponent("FixtureTrash") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsSignatureCleanup-" + UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let binary = try #require(Bundle.main.url(forResource: "StubLauncherBinary", withExtension: nil))
            let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
            try FileManager.default.copyItem(at: binary, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try write(["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
                       "CFBundlePackageType": "APPL", "CFBundleVersion": "1"], at: app.appendingPathComponent("Contents/Info.plist"))
            try Data("original application payload".utf8).write(to: payload)
        }

        func signer(trash: (@Sendable (URL) throws -> Void)? = nil,
                    deleteRecord: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> CodeSigner {
            CodeSigner(backupDirectoryURL: backups, allowAdministratorPrompt: false,
                       trashBackupSnapshot: trash ?? { try self.moveToFixtureTrash($0) }, deleteBackupRecordFile: deleteRecord,
                       recoveryDependencyCheck: { _ in })
        }

        func moveToFixtureTrash(_ snapshot: URL) throws {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: snapshot, to: trash.appendingPathComponent(snapshot.lastPathComponent))
        }

        func snapshot() throws -> URL {
            let name = try #require(plist(record)["snapshotName"] as? String)
            return backups.appendingPathComponent(name)
        }

        func plist(_ path: URL) throws -> [String: Any] {
            try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any])
        }

        func write(_ plist: [String: Any], at path: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path, options: .atomic)
        }

        func remove() { try? SignatureSnapshot.remove(root) }
    }
}
