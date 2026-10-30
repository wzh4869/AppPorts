import Darwin
import Foundation
import Testing
@testable import AppPorts

struct ContainerMountResumeTests {
    @Test("Backoff starts when expensive verification fails, not when maintenance starts")
    func deadlineUsesFailureTime() async throws {
        let fixture = try Fixture(checkpoint: .restoreVerified)
        defer { fixture.remove() }
        _ = try await fixture.migrate()
        let initial = try #require(try fixture.store.transfers().first)
        try Data("unique changes".utf8).write(to: URL(fileURLWithPath: initial.backupPath!).appendingPathComponent("payload.txt"))
        let clock = DelayedInspectionClock()
        _ = await fixture.mover(safetyRunner: clock).performAutomaticMaintenance(now: { clock.read() })
        #expect(try fixture.store.transfer(operationID: initial.operationID)?.nextAutomaticRetryAt == Date(timeIntervalSince1970: 1180))
    }

    @Test("Manual backoff bypass preserves explicit keep and deferred choices", arguments: [DataTransferRecord.CleanupDisposition.keep, .deferred])
    func retryKeepsUserDisposition(_ disposition: DataTransferRecord.CleanupDisposition) async throws {
        let fixture = try Fixture(checkpoint: .restoreVerified)
        defer { fixture.remove() }
        _ = try await fixture.migrate()
        let initial = try #require(try fixture.store.transfers().first)
        try fixture.store.setCleanupDisposition(disposition, expected: initial)
        let saved = try #require(try fixture.store.transfer(operationID: initial.operationID))
        let calls = fixture.runner.calls
        _ = await fixture.mover().performAutomaticMaintenance(ignoresRetryBackoff: true)
        #expect(try fixture.store.transfer(operationID: initial.operationID) == saved)
        #expect(fixture.runner.calls == calls)
        try fixture.store.setCleanupDisposition(nil, expected: saved)
        _ = await fixture.mover().performAutomaticMaintenance(only: initial.operationID, ignoresRetryBackoff: true)
        #expect(try fixture.store.transfer(operationID: initial.operationID) == nil)
    }

    @Test("Legacy cleanup deadlines prevent repeated inspection and manual retry remains available")
    func legacyCleanupBackoff() async throws {
        let fixture = try Fixture(checkpoint: .restoreVerified)
        defer { fixture.remove() }
        let record = ContainerMountRecord(appName: "Synthetic", bundleIdentifier: nil, dataDirType: "containers",
            mountPointPath: fixture.source.path, volumeUUID: "OFFLINE", volumeName: "AppPorts-test", externalRootPath: fixture.external.path)
        let cleanup = ContainerCleanupRecord(kind: .migrationBackup, mountRecord: record, localPath: fixture.root.appendingPathComponent("legacy").path)
        try fixture.store.recordMigration(record, cleanup: cleanup)
        let time = Date()
        try fixture.store.recordCleanupRetry(.legacy(cleanup.id), failed: true, now: time)
        let saved = try fixture.store.pendingCleanups()
        let calls = fixture.runner.calls
        _ = await fixture.mover().performAutomaticMaintenance(now: { time })
        #expect(try fixture.store.pendingCleanups() == saved)
        #expect(fixture.runner.calls == calls)
        _ = await fixture.mover().performAutomaticMaintenance(ignoresRetryBackoff: true, now: { time })
        #expect(try fixture.store.pendingCleanups().first?.retryFailureCount == 2)
    }

    private final class DelayedInspectionClock: ShellCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1000)
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return time }
        private func advance() { lock.lock(); defer { lock.unlock() }; time = Date(timeIntervalSince1970: 1120) }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            advance()
            return ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
        }
    }

    @Test("Actual cleanup waits until its deadline, manual retry bypasses it, and failures remain daily")
    func maintenanceBackoff() async throws {
        let fixture = try Fixture(checkpoint: .restoreVerified)
        defer { fixture.remove() }
        _ = try await fixture.migrate()
        let initial = try #require(try fixture.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(initial.backupPath))
        try Data("unique changed data".utf8).write(to: backup.appendingPathComponent("payload.txt"))
        var time = Date(timeIntervalSince1970: 1000)
        for index in 0..<7 {
            let currentTime = time
            _ = await fixture.mover().performAutomaticMaintenance(now: { currentTime })
            let failed = try #require(try fixture.store.transfer(operationID: initial.operationID))
            #expect(failed.retryFailureCount == min(index + 1, 5))
            let deadline = try #require(failed.nextAutomaticRetryAt)
            #expect(deadline == time.addingTimeInterval(CleanupRetryBackoff.delays[min(index, 4)]))
            let calls = fixture.runner.calls
            _ = await fixture.mover().performAutomaticMaintenance(now: { currentTime })
            #expect(try fixture.store.transfer(operationID: initial.operationID) == failed)
            #expect(fixture.runner.calls == calls)
            time = deadline
        }
        let manualTime = time.addingTimeInterval(-1)
        _ = await fixture.mover().performAutomaticMaintenance(ignoresRetryBackoff: true, now: { manualTime })
        #expect(try fixture.store.transfer(operationID: initial.operationID)?.nextAutomaticRetryAt == manualTime.addingTimeInterval(86400))
        #expect(try fixture.payload(at: backup) == "unique changed data")
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("Cleanup backoff never blocks recovery of a missing original entry")
    func recoveryBypassesBackoff() async throws {
        let fixture = try Fixture(checkpoint: .migrationMoved)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let transfer = try #require(try fixture.store.transfers().first)
        let now = Date()
        try fixture.store.recordCleanupRetry(.transfer(transfer.operationID), failed: true, now: now)
        _ = await fixture.mover().performAutomaticMaintenance(now: { now })
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("Ordinary DS_Store changes can be cleaned but business data and non-regular names survive",
          arguments: ["regular", "business", "directory", "symlink", "hardlink"])
    func metadataCleanupEvidence(_ kind: String) async throws {
        let fixture = try Fixture(checkpoint: .restoreVerified)
        defer { fixture.remove() }
        try Data("finder".utf8).write(to: fixture.source.appendingPathComponent(".DS_Store"))
        _ = try await fixture.migrate()
        let transfer = try #require(try fixture.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
        let metadata = backup.appendingPathComponent(".DS_Store")
        if kind == "regular" { try Data("finder rewrote this".utf8).write(to: metadata) }
        if kind == "business" { try Data("unique changed data".utf8).write(to: backup.appendingPathComponent("payload.txt")) }
        if ["directory", "symlink", "hardlink"].contains(kind) {
            try FileManager.default.removeItem(at: metadata)
            if kind == "directory" { try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false) }
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: fixture.source.appendingPathComponent("payload.txt")) }
            if kind == "hardlink" { try FileManager.default.linkItem(at: backup.appendingPathComponent("payload.txt"), to: metadata) }
        }
        _ = await fixture.mover().performAutomaticMaintenance()
        #expect(FileManager.default.fileExists(atPath: backup.path) == (kind != "regular"))
        #expect(try fixture.payload(at: fixture.source) == "original")
        if kind == "business" { #expect(try fixture.payload(at: backup) == "unique changed data") }
    }

    @Test("Ordinary restore resumes an interrupted restore without a separate recovery action", arguments: [
        Checkpoint.restoreVerified, .restoreSwitch, .restoreFinalized
    ])
    func ordinaryRestoreResumesPendingWork(checkpoint: Checkpoint) async throws {
        let fixture = try Fixture(checkpoint: checkpoint)
        defer { fixture.remove() }
        let migration = try await fixture.migrate()
        await #expect(throws: (any Error).self) {
            try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        // The last mount can disappear before local activation. Its durable
        // transfer must keep the login/reconnect recovery agent installed.
        #expect(try ContainerMountAgentInstaller.requiresAgent(store: fixture.store))
        let created = fixture.runner.commands(prefix: ["apfs", "addVolume"])
        #expect(try await fixture.mover().restoreAndComplete(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil) == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.store.recordsStrict().isEmpty)
        #expect(try !ContainerMountAgentInstaller.requiresAgent(store: fixture.store))
        #expect(fixture.runner.commands(prefix: ["apfs", "addVolume"]) == created)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("A missing or replaced old backup cannot prevent retrieval of newly written active data", arguments: [false, true])
    func restoresCurrentDataWithoutOldBackup(replaced: Bool) async throws {
        let fixture = try Fixture(checkpoint: .migrationCommitted)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let pending = try #require(try fixture.store.transfers().first)
        let record = try #require(pending.recoveryMountRecord)
        let backup = URL(fileURLWithPath: try #require(pending.backupPath))
        try FileManager.default.moveItem(at: backup, to: fixture.root.appendingPathComponent("UserSavedOriginal"))
        if replaced {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
            try Data("unrelated replacement".utf8).write(to: backup.appendingPathComponent("keep"))
        }
        try Data("latest active data".utf8).write(to: fixture.source.appendingPathComponent("payload.txt"))
        _ = try await fixture.mover().restoreAndComplete(record: record, estimatedTotalBytes: 0, progressHandler: nil)
        #expect(!fixture.runner.isMounted(fixture.source))
        #expect(try fixture.payload(at: fixture.source) == "latest active data")
        if replaced { #expect(try String(contentsOf: backup.appendingPathComponent("keep"), encoding: .utf8) == "unrelated replacement") }
    }

    @Test("Activated mount and restored local trees accept writes before final recovery", arguments: [Checkpoint.migrationCommitted, .restoreFinalized])
    func activeWritesAfterFinalSaveFailure(checkpoint: Checkpoint) async throws {
        let fixture = try Fixture(checkpoint: checkpoint)
        defer { fixture.remove() }
        if checkpoint == .migrationCommitted {
            await #expect(throws: (any Error).self) { try await fixture.migrate() }
        } else {
            let migration = try await fixture.mover().migrateAndComplete(item: fixture.item, externalRootURL: fixture.external,
                appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
            await #expect(throws: (any Error).self) {
                try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
            }
        }
        let pending = try #require(try fixture.store.transfers().first)
        try Data("new active value".utf8).write(to: fixture.source.appendingPathComponent("payload.txt"))
        try Data("new document".utf8).write(to: fixture.source.appendingPathComponent("created-after-switch.txt"))
        #expect(chmod(fixture.source.path, 0o700) == 0)
        let active = try TreeCopySession.snapshot(at: fixture.source)
        let created = fixture.runner.commands(prefix: ["apfs", "addVolume"])
        #expect(try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
        #expect(try TreeCopySession.snapshot(at: fixture.source) == active)
        #expect(fixture.runner.commands(prefix: ["apfs", "addVolume"]) == created)
        #expect(try fixture.store.transfers().isEmpty)
    }
    @Test("Verified mount migration resumes its original operation without creating or copying another volume", arguments: [
        Checkpoint.migrationVerified, .migrationUnmounted, .migrationMoved, .migrationCommitted
    ])
    func resumesMigration(checkpoint: Checkpoint) async throws {
        let fixture = try Fixture(checkpoint: checkpoint)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let pending = try #require(try fixture.store.transfers().first)
        let mount = try #require(pending.recoveryMountRecord)
        #expect(pending.isVerifiedSwitchRecoverable || pending.isPreparationRecoverable)
        let created = fixture.runner.commands(prefix: ["apfs", "addVolume"])

        let warning = try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)

        #expect(warning == nil)
        #expect(try fixture.store.recordsStrict() == [mount])
        #expect(try fixture.store.transfers().isEmpty)
        #expect(fixture.runner.mountedUUID(at: fixture.source) == mount.volumeUUID)
        #expect(fixture.runner.commands(prefix: ["apfs", "addVolume"]) == created)
        #expect(try fixture.payload(at: fixture.source) == "original")
        let completedCalls = fixture.runner.calls
        #expect(try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
        #expect(fixture.runner.calls == completedCalls)
    }

    @Test("Verified mount restore finishes a retained staging copy or an already switched local copy", arguments: [
        Checkpoint.restoreVerified, .restoreSwitch, .restoreFinalized
    ])
    func resumesRestore(checkpoint: Checkpoint) async throws {
        let fixture = try Fixture(checkpoint: checkpoint)
        defer { fixture.remove() }
        let migration = try await fixture.migrate()
        await #expect(throws: (any Error).self) {
            try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let pending = try #require(try fixture.store.transfers().first { $0.direction == .restore })
        #expect(pending.isVerifiedSwitchRecoverable || pending.isPreparationRecoverable)
        let copiedIdentity = try #require(pending.destinationIdentity)
        let created = fixture.runner.commands(prefix: ["apfs", "addVolume"])

        let warning = try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)

        #expect(warning == nil)
        #expect(try fixture.store.recordsStrict().isEmpty)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(!fixture.runner.isMounted(fixture.source))
        #expect(try DataPathIdentity.capture(fixture.source).matchesFilesystemObject(copiedIdentity))
        #expect(fixture.runner.commands(prefix: ["apfs", "addVolume"]) == created)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("An already restored local copy can finalize while its old volume is unavailable")
    func finalizesRestoreWithoutOldVolume() async throws {
        let fixture = try Fixture(checkpoint: .restoreFinalized)
        defer { fixture.remove() }
        let migration = try await fixture.mover().migrateAndComplete(item: fixture.item, externalRootURL: fixture.external,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        await #expect(throws: (any Error).self) {
            try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let pending = try #require(try fixture.store.transfers().first)
        let local = try TreeCopySession.snapshot(at: fixture.source)
        let mounts = fixture.runner.commands(prefix: ["mount"])
        fixture.runner.failWhen(prefix: ["info"])

        let warning = try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)

        #expect(warning != nil)
        #expect(try fixture.store.transfer(operationID: pending.operationID)?.isDataSwitchComplete == true)
        #expect(try fixture.store.recordsStrict().isEmpty)
        #expect(fixture.runner.commands(prefix: ["mount"]) == mounts)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try TreeCopySession.snapshot(at: fixture.source) == local)
        #expect(try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) != nil)
        #expect(try TreeCopySession.snapshot(at: fixture.source) == local)
        fixture.runner.clearFailure()
        #expect(try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
        #expect(try fixture.store.transfers().isEmpty)
    }

    @Test("Resume discards never activated migration copies and retains changed restore copies", arguments: [
        Checkpoint.migrationVerified, .restoreVerified
    ])
    func changedCopyBlocksResume(checkpoint: Checkpoint) async throws {
        let fixture = try Fixture(checkpoint: checkpoint)
        defer { fixture.remove() }
        if checkpoint == .migrationVerified {
            await #expect(throws: (any Error).self) { try await fixture.migrate() }
        } else {
            let migration = try await fixture.migrate()
            await #expect(throws: (any Error).self) {
                try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
            }
        }
        let pending = try #require(try fixture.store.transfers().first { $0.isVerifiedSwitchRecoverable || $0.isPreparationRecoverable })
        let staged = URL(fileURLWithPath: try #require(pending.stagingPath))
        try Data("changed copy".utf8).write(to: staged.appendingPathComponent("payload.txt"))
        let original = try TreeCopySession.snapshot(at: fixture.source)
        let mountCalls = fixture.runner.commands(prefix: ["mount"])
        let unmountCalls = fixture.runner.commands(prefix: ["unmount"])

        if checkpoint == .migrationVerified {
            #expect(try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
        } else {
            await #expect(throws: (any Error).self) {
                try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
            }
        }

        if checkpoint == .migrationVerified {
            #expect(try fixture.payload(at: fixture.source) == "original")
            #expect(fixture.runner.isMounted(fixture.source))
            #expect(pending.candidateActivationAttempted == false)
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            #expect(try fixture.store.transfer(operationID: pending.operationID) == nil)
            #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        } else {
            #expect(try TreeCopySession.snapshot(at: fixture.source) == original)
            #expect(fixture.runner.commands(prefix: ["mount"]) == mountCalls)
            #expect(try fixture.payload(at: staged) == "changed copy")
            #expect(try fixture.store.transfer(operationID: pending.operationID)?.baseline == pending.baseline)
            #expect(fixture.runner.commands(prefix: ["unmount"]) == unmountCalls)
            #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        }
    }

    @Test("A ledger change during resume inspection is preserved and stops all disk mutations")
    func changedLedgerBlocksResume() async throws {
        let fixture = try Fixture(checkpoint: .migrationVerified)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        var replacement = try #require(try fixture.store.transfers().first)
        replacement.recoverableReason = "Updated by another operation"
        let expected = replacement
        let store = fixture.store
        let commands = fixture.runner.calls

        await #expect(throws: (any Error).self) {
            try await fixture.mover().resumeVerifiedTransfer(operationID: expected.operationID) { _ in
                try? store.updateTransfer(expected)
            }
        }

        #expect(try store.transfer(operationID: expected.operationID) == expected)
        #expect(fixture.runner.calls == commands)
    }

    @Test("A standard automatic mount resumes only with matching recorded UUID and marker", arguments: [
        "matching", "marker-mismatch", "uuid-mismatch"
    ])
    func automaticMountIdentity(scenario: String) async throws {
        let fixture = try Fixture(checkpoint: .migrationUnmounted)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let pending = try #require(try fixture.store.transfers().first)
        let mount = try #require(pending.recoveryMountRecord)
        let automatic = URL(fileURLWithPath: "/Volumes").appendingPathComponent(mount.volumeName)
        let detached = try #require(fixture.runner.detachedContents(for: mount.volumeUUID))
        let retainedCopy = try TreeCopySession.snapshot(at: detached)
        // Only the fake mount table uses /Volumes. Its data remains in the
        // private temporary fixture; this test never creates a /Volumes entry.
        fixture.runner.markVolumeMounted(mount.volumeUUID, at: automatic.path)
        let runner = fixture.runner
        let service = fixture.mover(
            volumeUUIDMarker: { $0.path == automatic.path && scenario != "marker-mismatch" ? mount.volumeUUID : "OTHER-UUID" },
            mountedVolumeUUID: { scenario == "uuid-mismatch" && $0.path == automatic.path ? "OTHER-UUID" : runner.mountedUUID(at: $0) },
            mountFlags: { $0.path == automatic.path ? UInt32(MNT_IGNORE_OWNERSHIP) : UInt32(MNT_DONTBROWSE) })
        let unmounts = runner.commands(prefix: ["unmount"])
        let mounts = runner.commands(prefix: ["mount"])
        if scenario == "matching" {
            #expect(try await service.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
            #expect(runner.commands(prefix: ["unmount"]).contains(["unmount", automatic.path]))
            #expect(runner.commands(prefix: ["-u"]).isEmpty)
            #expect(runner.commands(prefix: ["mount"]).allSatisfy { $0[3].hasPrefix(fixture.root.path + "/") })
            #expect(try fixture.payload(at: fixture.source) == "original")
            #expect(try fixture.store.transfers().isEmpty)
        } else {
            await #expect(throws: (any Error).self) {
                try await service.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
            }
            #expect(runner.commands(prefix: ["unmount"]) == unmounts)
            #expect(runner.commands(prefix: ["mount"]) == mounts)
            #expect(try TreeCopySession.snapshot(at: detached) == retainedCopy)
            #expect(try fixture.payload(at: fixture.source) == "original")
        }
    }

    @Test("The mount helper rechecks the ledger after its disk query before creating or locking a mount point")
    func diskQueryLedgerChangePreventsMount() async throws {
        let fixture = try Fixture(checkpoint: .migrationMoved)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let pending = try #require(try fixture.store.transfers().first)
        let staging = URL(fileURLWithPath: try #require(pending.stagingPath))
        let backup = URL(fileURLWithPath: try #require(pending.backupPath))
        let unchanged = try TreeCopySession.snapshot(at: backup)
        var replacement = pending
        replacement.recoverableReason = "Changed during disk inspection"
        let expected = replacement
        let store = fixture.store
        let intercepted = DiskInfoInterception(base: fixture.runner, uuid: try #require(pending.createdVolumeUUID), occurrence: 2) {
            try store.updateTransfer(expected)
        }
        let mounts = fixture.runner.commands(prefix: ["mount"])

        await #expect(throws: (any Error).self) {
            try await fixture.mover(diskRunner: intercepted).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
        }

        #expect(try store.transfer(operationID: pending.operationID) == expected)
        #expect(fixture.runner.commands(prefix: ["mount"]) == mounts)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try TreeCopySession.snapshot(at: backup) == unchanged)
    }

    @Test("A retained backup changed during the final mount query is not connected or overwritten")
    func diskQueryBackupChangePreventsFinalMount() async throws {
        let fixture = try Fixture(checkpoint: .migrationVerified)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let pending = try #require(try fixture.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(pending.backupPath))
        let intercepted = DiskInfoInterception(base: fixture.runner, uuid: try #require(pending.createdVolumeUUID), occurrence: 2) {
            try Data("new retained data".utf8).write(to: backup.appendingPathComponent("payload.txt"))
        }
        let mounts = fixture.runner.commands(prefix: ["mount"])

        await #expect(throws: (any Error).self) {
            try await fixture.mover(diskRunner: intercepted).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
        }

        #expect(fixture.runner.commands(prefix: ["mount"]).filter { $0.contains(fixture.source.path) }
            == mounts.filter { $0.contains(fixture.source.path) })
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try fixture.payload(at: fixture.source) == "new retained data")
        #expect(try fixture.store.transfer(operationID: pending.operationID) == nil)
        #expect(try fixture.store.recordsForInspection().preservedMaterials.isEmpty)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
    }

    @Test("Rolled-back private staging cannot block a fresh restore or replace its new data")
    func rollbackCleanupDoesNotOwnTheNextRestore() async throws {
        let fixture = try Fixture(checkpoint: .restoreSwitch)
        defer { fixture.remove() }
        let migration = try await fixture.migrate()
        await #expect(throws: (any Error).self) {
            try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let pending = try #require(try fixture.store.transfers().first { $0.direction == .restore })
        let staging = URL(fileURLWithPath: try #require(pending.stagingPath))
        try Data("unclaimed changed content".utf8).write(to: staging.appendingPathComponent("preserve-me"))
        _ = try await fixture.mover().recoverWithIndependentBudget(pending, finishPreparedRestore: false)
        let rolledBack = try #require(try fixture.store.transfer(operationID: pending.operationID))
        #expect(rolledBack.rollbackCompletedAt != nil)
        #expect(rolledBack.topologyEntries.allSatisfy { $0.path != fixture.source.path })
        try Data("written after rollback".utf8).write(to: fixture.source.appendingPathComponent("payload.txt"))
        let warning = try await fixture.mover().restoreAndComplete(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        #expect(warning != nil)
        #expect(try fixture.payload(at: fixture.source) == "written after rollback")
        #expect(!fixture.runner.isMounted(fixture.source))
        #expect(try fixture.store.recordsStrict().isEmpty)
        // A cold maintenance pass must not put the old mount back or touch the
        // unknown staging file just because this old record still exists.
        _ = await fixture.mover().performAutomaticMaintenance()
        #expect(try fixture.payload(at: fixture.source) == "written after rollback")
        #expect(try fixture.store.recordsStrict().isEmpty)
        #expect(try String(contentsOf: staging.appendingPathComponent("preserve-me"), encoding: .utf8) == "unclaimed changed content")
    }

    @Test("A replacement volume during the writer probe is rejected before any ownership update")
    func writerProbeVolumeChangePreventsOwnershipUpdate() async throws {
        let fixture = try Fixture(checkpoint: .restoreVerified)
        defer { fixture.remove() }
        let migration = try await fixture.migrate()
        await #expect(throws: (any Error).self) {
            try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let pending = try #require(try fixture.store.transfers().first { $0.direction == .restore })
        let probe = ReplacementVolumeProbe()
        let source = fixture.source
        let runner = fixture.runner
        let service = fixture.mover(
            mountedVolumeUUID: { probe.didProbe && $0.path == source.path ? "REPLACEMENT-UUID" : runner.mountedUUID(at: $0) },
            mountFlags: { $0.path == source.path ? UInt32(MNT_IGNORE_OWNERSHIP) : UInt32(MNT_DONTBROWSE) },
            safetyRunner: probe)

        await #expect(throws: (any Error).self) {
            try await service.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
        }

        #expect(probe.didProbe)
        #expect(runner.commands(prefix: ["-u"]).isEmpty)
        #expect(try fixture.payload(at: source) == "original")
        let unchanged = try #require(try fixture.store.transfer(operationID: pending.operationID))
        #expect(unchanged == pending)
        #expect(unchanged.isPreparationRecoverable)
        #expect(unchanged.sourceBaseline != nil && unchanged.baseline == nil)
    }

    private final class DiskInfoInterception: ShellCommandRunning, @unchecked Sendable {
        let base: FakeDiskCommandRunner
        let uuid: String
        let action: @Sendable () throws -> Void
        private let lock = NSLock()
        private var remaining: Int

        init(base: FakeDiskCommandRunner, uuid: String, occurrence: Int, action: @escaping @Sendable () throws -> Void) {
            self.base = base
            self.uuid = uuid
            self.remaining = occurrence
            self.action = action
        }

        private func shouldAct(_ arguments: [String]) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard arguments.first == "info", arguments.last == uuid, remaining > 0 else { return false }
            remaining -= 1
            return remaining == 0
        }

        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            let result = try await base.run(executable: executable, arguments: arguments, timeout: timeout)
            if shouldAct(arguments) { try action() }
            return result
        }
    }

    private final class ReplacementVolumeProbe: ShellCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var probed = false
        var didProbe: Bool { lock.lock(); defer { lock.unlock() }; return probed }
        private func markProbed() { lock.lock(); defer { lock.unlock() }; probed = true }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            markProbed()
            return ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
        }
    }

    enum Checkpoint: Sendable {
        case migrationVerified, migrationUnmounted, migrationMoved, migrationCommitted
        case restoreVerified, restoreSwitch, restoreFinalized
    }

    private final class InterruptingWriter: @unchecked Sendable {
        let checkpoint: Checkpoint
        private let lock = NSLock()
        private var interrupted = false

        init(_ checkpoint: Checkpoint) { self.checkpoint = checkpoint }

        func write(_ data: Data, to url: URL) throws {
            lock.lock()
            defer { lock.unlock() }
            let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let transfers = document?["transfers"] as? [[String: Any]] ?? []
            let shouldInterrupt = transfers.contains { transfer in
                let direction = transfer["direction"] as? String
                let phase = transfer["phase"] as? String
                switch checkpoint {
                case .migrationVerified: return direction == "migrate" && phase == "verified"
                case .migrationUnmounted: return direction == "migrate" && phase == "switching" && transfer["backupIdentity"] == nil
                case .migrationMoved: return direction == "migrate" && phase == "switching" && transfer["backupIdentity"] != nil
                case .migrationCommitted: return direction == "migrate" && phase == "awaitingUserVerification"
                case .restoreVerified: return direction == "restore" && phase == "verified"
                case .restoreSwitch: return direction == "restore" && phase == "switching"
                case .restoreFinalized: return direction == "restore" && phase == "awaitingUserVerification"
                }
            }
            if !interrupted, shouldInterrupt {
                interrupted = true
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let external: URL
        let store: ContainerMountStore
        let runner: FakeDiskCommandRunner

        init(checkpoint: Checkpoint) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerMountResumeTests-\(UUID())")
                .resolvingSymlinksInPath()
            source = root.appendingPathComponent("Home/Library/Containers/com.example.resume/Data/Documents/Payload")
            external = root.appendingPathComponent("External/AppPorts")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("payload.txt"))
            let uuid = try #require(try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
            let writer = InterruptingWriter(checkpoint)
            store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"), writeData: { try writer.write($0, to: $1) })
        }

        var item: DataDirItem {
            DataDirItem(name: "Payload", path: source, type: .containers, priority: .critical, description: "fixture")
        }

        func mover(diskRunner: (any ShellCommandRunning)? = nil,
                   volumeUUIDMarker: (@Sendable (URL) -> String?)? = nil,
                   mountedVolumeUUID: (@Sendable (URL) -> String?)? = nil,
                   mountFlags: (@Sendable (URL) -> UInt32?)? = nil,
                   safetyRunner: any ShellCommandRunning = SyntheticNoWritersRunner()) -> ContainerVolumeMigrator {
            let runner = runner
            let externalPath = external.path
            return ContainerVolumeMigrator(disk: DiskUtility(runner: diskRunner ?? runner, commandTimeout: 5), store: store,
                stagingMountRootURL: root.appendingPathComponent("mounts"),
                isMountPoint: { runner.isMounted($0) },
                mountedVolumePath: { $0.path.hasPrefix(externalPath) ? "/SyntheticExternal" : "/" },
                mountedVolumeUUID: mountedVolumeUUID ?? { runner.mountedUUID(at: $0) }, volumeUUIDMarker: volumeUUIDMarker ?? { _ in nil },
                synchronizeAgent: { _ in }, availableCapacity: { _ in nil },
                mountFlags: mountFlags ?? { _ in UInt32(MNT_DONTBROWSE) }, homeDirectory: root.appendingPathComponent("Home"),
                safetyRunner: safetyRunner, makeMountPointLease: { try runner.makeMountPointLease(at: $0) })
        }

        @discardableResult
        func migrate() async throws -> ContainerVolumeMigrator.MigrationResult {
            try await mover().migrate(item: item, externalRootURL: external, appName: "Synthetic",
                bundleIdentifier: nil, progressHandler: nil)
        }

        func payload(at root: URL) throws -> String {
            try String(contentsOf: root.appendingPathComponent("payload.txt"), encoding: .utf8)
        }

        func remove() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["-R", "u+rwx", root.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
