import Darwin
import Foundation
import Testing
@testable import AppPorts

struct PrivilegedDataCleanupTests {
    private struct Fixture {
        let root: URL
        let retained: URL
        let active: URL
        let request: PrivilegedDataCleanup.Request

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("AppPortsDataCleanupTests-" + UUID().uuidString)
            retained = root.appendingPathComponent("OldCopy")
            active = root.appendingPathComponent("CurrentData")
            for directory in [retained, active] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("original".utf8).write(to: directory.appendingPathComponent("payload"))
            }
            let identity = try DataPathIdentity.capture(retained)
            let baseline = try PropertyListEncoder().encode(TreeCopySession.snapshot(at: retained))
            var transfer = DataTransferRecord(mode: .symlink, direction: .restore,
                appName: "Example", dataDirType: DataDirType.logs.rawValue,
                originalPath: active.path, activePath: active.path, destinationPath: active.path,
                backupPath: retained.path, sourceIdentity: identity,
                destinationIdentity: try DataPathIdentity.capture(active), backupIdentity: identity,
                phase: .cleanupRequested, baseline: baseline)
            transfer.cleanupParentIdentity = try DataPathIdentity.capture(root)
            request = .init(transfer: transfer, currentLocation: transfer)
        }

        func remove() {
            guard root.lastPathComponent.hasPrefix("AppPortsDataCleanupTests-") else { return }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Administrator cleanup executes the strict remover and leaves current local data unchanged")
    func removesOnlyRecordedOldCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let activeIdentity = try DataPathIdentity.capture(fixture.active)
        let active = try TreeCopySession.snapshot(at: fixture.active)
        let encoded = try PropertyListEncoder().encode(fixture.request)
        let request = try PropertyListDecoder().decode(PrivilegedDataCleanup.Request.self, from: encoded)
        try PrivilegedDataCleanup.perform(request)
        #expect(!FileManager.default.fileExists(atPath: fixture.retained.path))
        #expect(try DataPathIdentity.capture(fixture.active) == activeIdentity)
        try TreeCopySession.verifyUnchanged(at: fixture.active, against: active)
    }

    @Test("Administrator cleanup uses the latest restored location for an older migration record")
    func followsRestoredLocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = fixture.request.transfer
        let formerExternal = fixture.root.appendingPathComponent("FormerExternalLocation").path
        var original = DataTransferRecord(operationID: old.operationID, mode: .symlink, direction: .migrate,
            appName: old.appName, dataDirType: old.dataDirType, originalPath: old.originalPath,
            activePath: formerExternal, destinationPath: formerExternal, backupPath: old.backupPath,
            sourceIdentity: old.sourceIdentity, backupIdentity: old.backupIdentity,
            phase: .cleanupRequested, baseline: old.baseline)
        original.cleanupParentIdentity = old.cleanupParentIdentity
        try PrivilegedDataCleanup.perform(.init(transfer: original, currentLocation: fixture.request.currentLocation))
        #expect(!FileManager.default.fileExists(atPath: fixture.retained.path))
        #expect(try String(contentsOf: fixture.active.appendingPathComponent("payload")) == "original")
    }

    @Test("Authorization cannot bypass changed content or an absent deletion checkpoint",
          arguments: ["changed-content", "no-checkpoint", "active-is-retained", "active-replaced"])
    func refusesInvalidCleanup(_ scenario: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = fixture.request.transfer
        var current = fixture.request.currentLocation
        switch scenario {
        case "changed-content": try Data("modified".utf8).write(to: fixture.retained.appendingPathComponent("payload"))
        case "no-checkpoint": transfer.cleanupParentIdentity = nil
        case "active-is-retained": current.activePath = fixture.retained.path
        default:
            try FileManager.default.moveItem(at: fixture.active, to: fixture.root.appendingPathComponent("OriginalCurrentData"))
            try FileManager.default.createDirectory(at: fixture.active, withIntermediateDirectories: false)
        }
        #expect(throws: (any Error).self) {
            try PrivilegedDataCleanup.perform(.init(transfer: transfer, currentLocation: current))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.retained.appendingPathComponent("payload").path))
    }

    @Test("Cleanup diagnostics keep the operation, stage, retained path and native cause")
    func preservesFailureFacts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let failure = DataCleanupFailure(transfer: fixture.request.transfer, stage: "remove_retained_copy",
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)))
        let native = failure as NSError
        let fields = try #require(native.userInfo[OperationBlockage.diagnosticFieldsKey] as? [String: String])
        #expect(fields["blocking_operation_id"] == fixture.request.transfer.operationID.uuidString)
        #expect(fields["cleanup_path"] == fixture.retained.path)
        #expect(fields["cleanup_stage"] == "remove_retained_copy")
        #expect((native.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM))
        #expect(failure.localizedDescription.contains(fixture.retained.path))
        #expect(DataCleanupFailure.isPermissionFailure(POSIXError(.EACCES)))
        #expect(!DataCleanupFailure.isPermissionFailure(POSIXError(.EIO)))
        #expect(!DataCleanupResolution.requiresAdministrator(fixture.request.transfer))
    }
}
