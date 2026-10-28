import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DataTransferWorkflowAuditTests {
    @Test("A failed final save accepts subsequent writes at the activated data entry", arguments: ["migrate", "restore"])
    func activeWritesAfterFinalSaveFailure(direction: String) async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        if direction == "restore" { _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil) }
        writer.failTransition = (direction, "awaitingUserVerification")
        await #expect(throws: (any Error).self) {
            if direction == "migrate" { try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil) }
            else { try await fixture.mover.restore(item: fixture.item, progressHandler: nil) }
        }
        let pending = try #require(try fixture.store.transfers().first)
        let baseline = pending.baseline
        try Data("new active write".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        try Data("new document".utf8).write(to: fixture.local.appendingPathComponent("created-after-switch.txt"))
        let active = direction == "migrate" ? fixture.destination : fixture.local
        #expect(chmod(active.path, 0o700) == 0)
        let current = try TreeCopySession.snapshot(at: active)
        writer.failTransition = nil
        let cold = DataDirMover(homeDir: fixture.home, store: ContainerMountStore(fileURL: fixture.ledger), runner: fixture.runner)
        #expect(try await cold.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
        #expect(try TreeCopySession.snapshot(at: active) == current)
        #expect(baseline != nil)
        #expect(try fixture.store.transfers().isEmpty)
    }

    @Test("Normal restore copies current data even when an interrupted migration's old copy conflicts")
    func activeRestoreIgnoresOldCopyConflict() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        writer.failTransition = ("migrate", "awaitingUserVerification")
        await #expect(throws: (any Error).self) { try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil) }
        let interrupted = try #require(try fixture.store.transfers().first)
        let old = URL(fileURLWithPath: try #require(interrupted.backupPath))
        try Data("old copy edited".utf8).write(to: old.appendingPathComponent("a.txt"))
        try Data("current active value".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        try Data("latest".utf8).write(to: fixture.local.appendingPathComponent("latest.txt"))
        writer.failTransition = nil
        let result = try await fixture.mover.restoreAndComplete(item: fixture.item, progressHandler: nil)
        #expect(result.cleanupWarning != nil)
        #expect(try fixture.text("a.txt") == "current active value")
        #expect(try fixture.text("latest.txt") == "latest")
        #expect(try String(contentsOf: old.appendingPathComponent("a.txt"), encoding: .utf8) == "old copy edited")
        #expect(try fixture.store.managedLinks().isEmpty)
        #expect(try fixture.store.transfers().contains { $0.direction == .restore && $0.isDataSwitchComplete })
    }
    @Test("Use data on both disks between full moves without retaining old copies")
    func useDataBetweenCycles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for cycle in 1...2 {
            let migrated = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
            #expect(migrated.cleanupWarning == nil)
            try Data("external edit \(cycle)".utf8).write(to: fixture.destination.appendingPathComponent("a.txt"))
            try Data("new document \(cycle)".utf8).write(to: fixture.destination.appendingPathComponent("new.txt"))
            try FileManager.default.removeItem(at: fixture.destination.appendingPathComponent("b.txt"))
            let restored = try await fixture.mover.restoreAndComplete(item: fixture.item, progressHandler: nil)
            #expect(restored.cleanupWarning == nil)
            #expect(try fixture.text("a.txt") == "external edit \(cycle)")
            #expect(try fixture.text("new.txt") == "new document \(cycle)")
            #expect(!FileManager.default.fileExists(atPath: fixture.local.appendingPathComponent("b.txt").path))
            #expect(try fixture.store.transfers().isEmpty)
            #expect(try fixture.store.managedLinks().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["Payload"])
            try Data("local edit \(cycle)".utf8).write(to: fixture.local.appendingPathComponent("b.txt"))
        }
    }

    @Test("A partial cleanup resumes after reopening without changing current data", arguments: [false, true])
    func partialCleanupAfterRestart(leaveQuarantine: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let retained = try await fixture.retainedMigration()
        let backup = URL(fileURLWithPath: try #require(retained.backupPath))
        let active = try TreeCopySession.snapshot(at: fixture.destination)
        try fixture.checkpoint(retained)
        try FileManager.default.removeItem(at: backup.appendingPathComponent("a.txt"))
        if leaveQuarantine {
            try FileManager.default.moveItem(at: backup.appendingPathComponent("b.txt"),
                to: backup.appendingPathComponent(".appports-deleting-\(retained.operationID)"))
        }
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: #require(retained.baseline))
        #expect(chmod(backup.path, try #require(baseline.entries.first).mode | 0o700) == 0)
        let fresh = fixture.mover
        try await fresh.cleanupRetainedTransfer(operationID: retained.operationID)
        try await fresh.cleanupRetainedTransfer(operationID: retained.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try TreeCopySession.snapshot(at: fixture.destination) == active)
    }

    @Test("Root preference-file cleanup resumes its recorded exclusive rename")
    func fileRootQuarantineAfterRestart() async throws {
        let fixture = try Fixture(fileRoot: true)
        defer { fixture.remove() }
        let retained = try await fixture.retainedMigration()
        let backup = URL(fileURLWithPath: try #require(retained.backupPath))
        let quarantine = backup.deletingLastPathComponent().appendingPathComponent(".appports-deleting-\(retained.operationID)")
        try fixture.checkpoint(retained)
        try FileManager.default.moveItem(at: backup, to: quarantine)
        try await fixture.mover.cleanupRetainedTransfer(operationID: retained.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: quarantine.path))
        #expect(try Data(contentsOf: fixture.destination) == Data("preference data".utf8))
    }

    @Test("Partial deletion preserves hardlink identity when the old representative name is gone")
    func partialHardlinkCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.local.appendingPathComponent("b.txt")
        #expect(link(original.path, fixture.local.appendingPathComponent("c.txt").path) == 0)
        try FileManager.default.createSymbolicLink(atPath: fixture.local.appendingPathComponent("pointer").path, withDestinationPath: "b.txt")
        let transfer = try await fixture.retainedMigration()
        let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
        let active = try TreeCopySession.snapshot(at: fixture.destination)
        try fixture.checkpoint(transfer)
        try FileManager.default.removeItem(at: backup.appendingPathComponent("b.txt"))
        try await fixture.mover.cleanupRetainedTransfer(operationID: transfer.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try TreeCopySession.snapshot(at: fixture.destination) == active)
    }

    @Test("Resumed cleanup preserves changed, replaced or additional data", arguments: ["edit", "replace", "add", "foreign-quarantine"])
    func partialCleanupRejectsChangedRemainder(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let retained = try await fixture.retainedMigration()
        let backup = URL(fileURLWithPath: try #require(retained.backupPath))
        try fixture.checkpoint(retained)
        try FileManager.default.removeItem(at: backup.appendingPathComponent("a.txt"))
        let remaining = backup.appendingPathComponent("b.txt")
        if change == "edit" { try Data("changed data".utf8).write(to: remaining) }
        if change == "replace" {
            try FileManager.default.moveItem(at: remaining, to: fixture.root.appendingPathComponent("saved-original"))
            try Data("second".utf8).write(to: remaining)
        }
        if change == "add" { try Data("new data".utf8).write(to: backup.appendingPathComponent("new.txt")) }
        if change == "foreign-quarantine" {
            try Data("unrelated".utf8).write(to: backup.appendingPathComponent(".appports-deleting-\(retained.operationID)"))
        }
        let before = try TreeCopySession.snapshot(at: backup)
        await #expect(throws: (any Error).self) { try await fixture.mover.cleanupRetainedTransfer(operationID: retained.operationID) }
        #expect(try TreeCopySession.snapshot(at: backup) == before)
        #expect(try fixture.store.transfer(operationID: retained.operationID)?.phase == .cleanupRequested)
        #expect(try fixture.text("a.txt") == "first")
        #expect(try fixture.text("b.txt") == "second")
    }

    @Test("An absent backup is not treated as deleted without its original online parent")
    func missingBackupWithReplacedParent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        try await fixture.mover.restore(item: fixture.item, progressHandler: nil)
        let retained = try #require(try fixture.store.transfers().first)
        try fixture.checkpoint(retained)
        let offline = fixture.root.appendingPathComponent("DetachedExternal")
        try FileManager.default.moveItem(at: fixture.external, to: offline)
        try FileManager.default.createDirectory(at: fixture.external, withIntermediateDirectories: false)
        let ledger = try Data(contentsOf: fixture.ledger)
        let currentData = try TreeCopySession.snapshot(at: fixture.local)
        let retainedData = try TreeCopySession.snapshot(at: offline)
        await #expect(throws: DataOperationSafety.Failure.self) {
            try await fixture.mover.cleanupRetainedTransfer(operationID: retained.operationID)
        }
        let reason = DataOperationSafety.Failure.conflict(fixture.external.path).localizedDescription
        try expectLedgerUnchangedApartFromRetry(try Data(contentsOf: fixture.ledger), ledger, recoveryReason: reason)
        #expect(try TreeCopySession.snapshot(at: fixture.local) == currentData)
        #expect(try TreeCopySession.snapshot(at: offline) == retainedData)
        #expect(try String(contentsOf: offline.appendingPathComponent("Payload/a.txt"), encoding: .utf8) == "first")
        #expect(try fixture.text("a.txt") == "first")
    }

    @Test("Missing backups without a persisted deletion checkpoint remain recoverable")
    func unexplainedMissingBackupIsNotForgotten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let retained = try await fixture.retainedMigration()
        try FileManager.default.moveItem(at: URL(fileURLWithPath: try #require(retained.backupPath)),
            to: fixture.root.appendingPathComponent("moved-backup"))
        await #expect(throws: (any Error).self) { try await fixture.mover.cleanupRetainedTransfer(operationID: retained.operationID) }
        try expectTransfersUnchangedApartFromRetry(try fixture.store.transfers(), [retained])
    }

    @Test("Cleanup rechecks current data after process inspection suspends the operation", arguments: [false, true])
    func activeReplacementDuringPreflight(removeOnly: Bool) async throws {
        let runner = InspectingRunner()
        let fixture = try Fixture(runner: runner)
        defer { fixture.remove() }
        let retained = try await fixture.retainedMigration()
        runner.onNextInspection {
            try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("moved-active"))
            if !removeOnly {
                try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
                try Data("replacement".utf8).write(to: fixture.destination.appendingPathComponent("a.txt"))
            }
        }
        await #expect(throws: (any Error).self) { try await fixture.mover.cleanupRetainedTransfer(operationID: retained.operationID) }
        try expectTransfersUnchangedApartFromRetry(try fixture.store.transfers(), [retained])
        #expect(try String(contentsOf: URL(fileURLWithPath: try #require(retained.backupPath)).appendingPathComponent("a.txt"), encoding: .utf8) == "first")
    }

    @Test("A restore failing before copying leaves no permanent reservation", arguments: ["copying-save", "unsupported-source"])
    func unstartedRestoreCanRetry(failure: String) async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        let externalIdentity = try DataPathIdentity.capture(fixture.destination)
        if failure == "copying-save" { writer.failRestoreCopying = true }
        let unsupported = fixture.destination.appendingPathComponent("temporary-hardlink")
        if failure == "unsupported-source" { try linkOutsideSelection(unsupported, root: fixture.root) }
        await #expect(throws: (any Error).self) { try await fixture.mover.restoreAndComplete(item: fixture.item, progressHandler: nil) }
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.store.managedLinks().count == 1)
        #expect(try DataPathIdentity.capture(fixture.destination) == externalIdentity)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["Payload"])
        writer.failRestoreCopying = false
        if failure == "unsupported-source" { try FileManager.default.removeItem(at: unsupported) }
        let result = try await fixture.mover.restoreAndComplete(item: fixture.item, progressHandler: nil)
        #expect(result.cleanupWarning == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.text("a.txt") == "first")
    }

    /// A hard link whose peer lives outside the copied tree. The copier copies
    /// named pipes and refuses only nodes it cannot reproduce, so a link count
    /// the selection cannot account for is what forces an unsupported source
    /// here; the earlier FIFO fixture stopped failing once pipes were copied.
    private func expectTransfersUnchangedApartFromRetry(_ actual: [DataTransferRecord], _ expected: [DataTransferRecord]) throws {
        #expect(actual.count == expected.count)
        for original in expected {
            var current = try #require(actual.first { $0.operationID == original.operationID })
            // A failed cleanup records scheduling facts, while all identities,
            // baselines, phases and ownership reservations stay unchanged.
            #expect((current.retryFailureCount ?? 0) >= (original.retryFailureCount ?? 0))
            current.retryFailureCount = original.retryFailureCount
            current.nextAutomaticRetryAt = original.nextAutomaticRetryAt
            #expect(current == original)
        }
    }

    private func expectLedgerUnchangedApartFromRetry(_ actual: Data, _ expected: Data, recoveryReason: String) throws {
        var priorDocument = try #require(try PropertyListSerialization.propertyList(from: expected, format: nil) as? [String: Any])
        let priorSchema = try #require(priorDocument["schemaVersion"] as? Int)
        var priorTransfers = try #require(priorDocument["transfers"] as? [[String: Any]])
        try #require(priorTransfers.count == 1)
        // A checkpointed cleanup records the failure reason as well as its retry schedule.
        priorTransfers[0]["recoverableReason"] = recoveryReason
        priorDocument["transfers"] = priorTransfers
        let actualDocument = try #require(try PropertyListSerialization.propertyList(from: actual, format: nil) as? [String: Any])
        func withoutSchedule(_ original: [String: Any]) throws -> NSDictionary {
            var document = original
            var transfers = try #require(document["transfers"] as? [[String: Any]])
            for index in transfers.indices {
                transfers[index].removeValue(forKey: "retryFailureCount")
                transfers[index].removeValue(forKey: "nextAutomaticRetryAt")
            }
            document["transfers"] = transfers
            // Only the schedule's format upgrade is permitted here.
            if document["schemaVersion"] as? Int == 11, priorSchema < 11 { document["schemaVersion"] = priorSchema }
            return document as NSDictionary
        }
        #expect(try withoutSchedule(actualDocument) == withoutSchedule(priorDocument))
    }

    private func linkOutsideSelection(_ url: URL, root: URL) throws {
        let outside = root.appendingPathComponent("outside-payload")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.linkItem(at: outside, to: url)
    }

    @Test("A cleanup checkpoint save failure never starts physical deletion")
    func checkpointWriteFailure() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        let retained = try await fixture.retainedMigration()
        let backup = URL(fileURLWithPath: try #require(retained.backupPath))
        let snapshot = try TreeCopySession.snapshot(at: backup)
        writer.failCheckpoint = true
        await #expect(throws: (any Error).self) { try await fixture.mover.cleanupRetainedTransfer(operationID: retained.operationID) }
        #expect(try TreeCopySession.snapshot(at: backup) == snapshot)
        let pending = try #require(try fixture.store.transfer(operationID: retained.operationID))
        #expect(pending.phase == .cleanupRequested)
        #expect(pending.cleanupParentIdentity == nil)
        #expect(DataTransferGroup(transfer: pending).canCleanup)
        writer.failCheckpoint = false
        try await fixture.mover.cleanupRetainedTransfer(operationID: retained.operationID)
        #expect(try fixture.store.transfers().isEmpty)
    }

    @Test("The durable cleanup checkpoint survives reopening and is immutable")
    func checkpointSchemaAndIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let retained = try await fixture.retainedMigration()
        try fixture.checkpoint(retained)
        let document = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.ledger), format: nil) as? [String: Any])
        #expect(document["schemaVersion"] as? Int == 7)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        var checkpointed = try #require(try cold.transfer(operationID: retained.operationID))
        #expect(checkpointed.cleanupParentIdentity != nil)
        let ledger = try Data(contentsOf: fixture.ledger)
        checkpointed.cleanupParentIdentity = nil
        #expect(throws: ContainerMountStore.StoreError.self) { try cold.updateTransfer(checkpointed) }
        #expect(throws: ContainerMountStore.StoreError.self) {
            try cold.beginCleanupDeletion(operationID: retained.operationID, parentIdentity: DataPathIdentity(device: 1, inode: 99))
        }
        #expect(try Data(contentsOf: fixture.ledger) == ledger)
    }

    @Test("Verified migration and restore continue the same operation after ledger failures",
          arguments: ["migrate", "restore"], ["verified", "switching", "awaitingUserVerification"])
    func verifiedSwitchRetry(direction: String, phase: String) async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        if direction == "restore" {
            _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        }
        writer.failTransition = (direction, phase)
        await #expect(throws: (any Error).self) {
            if direction == "migrate" {
                _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
            } else { _ = try await fixture.mover.restoreAndComplete(item: fixture.item, progressHandler: nil) }
        }
        let interrupted = try #require(try fixture.store.transfers().last)
        #expect(interrupted.isVerifiedSwitchRecoverable || interrupted.isPreparationRecoverable)
        #expect(DataTransferGroup(transfer: interrupted).resumeTransfer == interrupted)
        let destinationIdentity = try #require(interrupted.destinationIdentity)
        writer.failTransition = nil
        let reopened = DataDirMover(homeDir: fixture.home, store: ContainerMountStore(fileURL: fixture.ledger), runner: fixture.runner)
        let warning = try await reopened.resumeVerifiedTransfer(operationID: interrupted.operationID, progressHandler: nil)
        #expect(warning == nil)
        #expect(try fixture.store.transfers().isEmpty)
        let current = direction == "migrate" ? fixture.destination : fixture.local
        #expect(try DataPathIdentity.capture(current).matchesFilesystemObject(destinationIdentity))
        #expect(try fixture.text("a.txt") == "first")
        #expect(try fixture.text("b.txt") == "second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["Payload"])
        if direction == "migrate" { #expect(try fixture.store.managedLinks().first?.operationID == interrupted.operationID) }
        else { #expect(try fixture.store.managedLinks().isEmpty); #expect(!FileManager.default.fileExists(atPath: fixture.destination.path)) }
        // Repeated UI delivery is an idempotent no-op after completion.
        #expect(try await reopened.resumeVerifiedTransfer(operationID: interrupted.operationID, progressHandler: nil) == nil)
    }

    @Test("A process ending between rename and ledger update can finish its existing switch", arguments: ["migrate", "restore", "restore-relative"])
    func interruptedRenameRetry(scenario: String) async throws {
        let direction = scenario == "migrate" ? "migrate" : "restore"
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        if direction == "restore" {
            _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
            if scenario == "restore-relative" {
                try FileManager.default.removeItem(at: fixture.local)
                try FileManager.default.createSymbolicLink(atPath: fixture.local.path, withDestinationPath: "../External/Payload")
            }
        }
        writer.failTransition = (direction, "switching")
        await #expect(throws: (any Error).self) {
            if direction == "migrate" { try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil) }
            else { try await fixture.mover.restore(item: fixture.item, progressHandler: nil) }
        }
        var transfer = try #require(try fixture.store.transfers().last)
        writer.failTransition = nil
        transfer.phase = .switching
        transfer.recoverableReason = nil
        if direction == "migrate" {
            try fixture.store.updateTransfer(transfer)
            try FileManager.default.moveItem(at: fixture.local, to: URL(fileURLWithPath: #require(transfer.backupPath)))
            #expect(transfer.backupIdentity == nil)
        } else {
            try fixture.store.beginRestore(transfer: transfer, removingMount: nil)
            let previous = URL(fileURLWithPath: try #require(transfer.stagingPath)).appendingPathComponent("previous-entry")
            try FileManager.default.moveItem(at: fixture.local, to: previous)
        }
        let warning = try await fixture.mover.resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: nil)
        #expect(warning == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.text("a.txt") == "first")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["Payload"])
    }

    @Test("Link normalization can finish after its final commit fails")
    func normalizationRetry() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        let normalized = fixture.root.appendingPathComponent("Normalized/Payload")
        writer.failTransition = ("migrate", "awaitingUserVerification")
        await #expect(throws: (any Error).self) {
            _ = try await fixture.mover.normalizeManagedLinkAndComplete(localPath: fixture.local,
                currentExternalPath: fixture.destination, normalizedExternalPath: normalized)
        }
        let interrupted = try #require(try fixture.store.transfers().first)
        writer.failTransition = nil
        #expect(try await fixture.mover.resumeVerifiedTransfer(operationID: interrupted.operationID, progressHandler: nil) == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.store.managedLinks().first?.destinationPath == normalized.path)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try fixture.text("a.txt") == "first")
    }

    @Test("Verified switch retry preserves changed or replaced data", arguments: ["source-edit", "destination-edit", "destination-replace", "local-conflict"])
    func verifiedRetryRejectsChangedData(change: String) async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        writer.failTransition = ("migrate", "switching")
        await #expect(throws: (any Error).self) { try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil) }
        let transfer = try #require(try fixture.store.transfers().first)
        writer.failTransition = nil
        if change == "source-edit" { try Data("edited original".utf8).write(to: fixture.local.appendingPathComponent("a.txt")) }
        if change == "destination-edit" { try Data("edited destination".utf8).write(to: fixture.destination.appendingPathComponent("a.txt")) }
        if change == "destination-replace" {
            try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("saved-copy"))
            try FileManager.default.copyItem(at: fixture.root.appendingPathComponent("saved-copy"), to: fixture.destination)
        }
        if change == "local-conflict" {
            try FileManager.default.moveItem(at: fixture.local, to: URL(fileURLWithPath: #require(transfer.backupPath)))
            try FileManager.default.createDirectory(at: fixture.local, withIntermediateDirectories: false)
            try Data("different local data".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        }
        let original = try TreeCopySession.snapshot(at: fixture.local)
        let destination = try TreeCopySession.snapshot(at: fixture.destination)
        await #expect(throws: (any Error).self) { try await fixture.mover.resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: nil) }
        #expect(try TreeCopySession.snapshot(at: fixture.local) == original)
        #expect(try TreeCopySession.snapshot(at: fixture.destination) == destination)
        #expect(try fixture.store.transfers().map(\.operationID) == [transfer.operationID])
    }

    @Test("A damaged cleanup manifest throws instead of crashing on duplicate paths")
    func duplicateManifestPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transfer = try await fixture.retainedMigration()
        let encoded = try #require(transfer.baseline)
        var propertyList = try #require(try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        var entries = try #require(propertyList["entries"] as? [[String: Any]])
        entries.append(try #require(entries.first))
        propertyList["entries"] = entries
        let damaged = try PropertyListDecoder().decode(TreeCopySnapshot.self,
            from: PropertyListSerialization.data(fromPropertyList: propertyList, format: .binary, options: 0))
        #expect(throws: TreeCopyError.self) {
            try TreeCopySession.verifyRemovalRemainder(at: URL(fileURLWithPath: #require(transfer.backupPath)),
                against: damaged, removalID: transfer.operationID)
        }
    }

    @Test("Restoring first completes a verified migration whose final commit failed")
    func restoreCompletesInterruptedMigrationFirst() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        writer.failTransition = ("migrate", "awaitingUserVerification")
        await #expect(throws: (any Error).self) { try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil) }
        let interrupted = try #require(try fixture.store.transfers().first)
        #expect(interrupted.phase == .needsRecovery)
        writer.failTransition = nil
        let result = try await fixture.mover.restoreAndComplete(item: fixture.item, progressHandler: nil)
        #expect(result.cleanupWarning == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.store.managedLinks().isEmpty)
        #expect(try fixture.text("a.txt") == "first")
    }

    @Test("An older restored chain can finish its failed migration record without reinstating the link")
    func legacyFailedPredecessorWithCompletedRestore() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        writer.failTransition = ("migrate", "awaitingUserVerification")
        await #expect(throws: (any Error).self) { try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil) }
        let interrupted = try #require(try fixture.store.transfers().first)
        writer.failTransition = nil
        // Construct the valid ledger shape emitted by the older restore path.
        var temporarilyCompleted = interrupted
        temporarilyCompleted.phase = .awaitingUserVerification
        temporarilyCompleted.recoverableReason = nil
        try fixture.store.updateTransfer(temporarilyCompleted)
        try await fixture.mover.restore(item: fixture.item, progressHandler: nil)
        try fixture.store.updateTransfer(interrupted)
        try Data("local edits after restore".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        let localIdentity = try DataPathIdentity.capture(fixture.local)
        let group = try #require(DataTransferGroup.groups(from: fixture.store.transfers()).first)
        #expect(group.resumeTransfer == interrupted)
        #expect(try await fixture.mover.resumeVerifiedTransfer(operationID: interrupted.operationID, progressHandler: nil) == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.store.managedLinks().isEmpty)
        #expect(try DataPathIdentity.capture(fixture.local) == localIdentity)
        #expect(try fixture.text("a.txt") == "local edits after restore")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["Payload"])
    }

    @Test("An already restored local tree can finish its record while its old external copy is offline")
    func completedRestoreWithOfflineRetainedCopy() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        writer.failTransition = ("restore", "awaitingUserVerification")
        await #expect(throws: (any Error).self) { try await fixture.mover.restore(item: fixture.item, progressHandler: nil) }
        let transfer = try #require(try fixture.store.transfers().first)
        writer.failTransition = nil
        let offline = fixture.root.appendingPathComponent("OfflineExternal")
        try FileManager.default.moveItem(at: fixture.external, to: offline)
        let warning = try await fixture.mover.resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: nil)
        #expect(warning != nil)
        #expect(try fixture.store.transfer(operationID: transfer.operationID)?.isDataSwitchComplete == true)
        #expect(try fixture.text("a.txt") == "first")
        try FileManager.default.moveItem(at: offline, to: fixture.external)
        try await fixture.mover.cleanupRetainedLineage(operationID: transfer.operationID)
        #expect(try fixture.store.transfers().isEmpty)
    }

    @Test("An offline old restore copy permits a new destination and later cleanup of the full location chain",
          arguments: [false, true])
    func remigrateWhilePreviousRestoreCopyIsOffline(restoreAgain: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        try await fixture.mover.restore(item: fixture.item, progressHandler: nil)
        let oldRestore = try #require(try fixture.store.transfers().first)
        let offline = fixture.root.appendingPathComponent("OfflineExternal")
        try FileManager.default.moveItem(at: fixture.external, to: offline)
        try Data("current local data".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        let nextDrive = fixture.root.appendingPathComponent("NextExternal")
        try FileManager.default.createDirectory(at: nextDrive, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: nextDrive.appendingPathComponent("sentinel.txt"))

        let migrated = try await fixture.mover.migrateAndComplete(item: fixture.item, to: nextDrive, progressHandler: nil)
        #expect(migrated.cleanupWarning != nil)
        let nextMigration = try #require(try fixture.store.transfers().first { $0.direction == .migrate })
        #expect(nextMigration.priorOperationID == oldRestore.operationID)
        #expect(nextMigration.isDataSwitchComplete)
        #expect(nextMigration.retainedCopyRemovedAt != nil)
        #expect(nextMigration.baseline == nil && nextMigration.sourceBaseline == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(nextMigration.backupPath)))
        #expect(try fixture.text("a.txt") == "current local data")
        #expect(try fixture.store.managedLink(forOriginalPath: fixture.local.path)?.operationID == nextMigration.operationID)
        var terminal = nextMigration
        if restoreAgain {
            try Data("current data from the second drive".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
            let restored = try await fixture.mover.restoreAndComplete(item: fixture.item, progressHandler: nil)
            #expect(restored.cleanupWarning != nil)
            terminal = try #require(try fixture.store.transfers().first { $0.priorOperationID == nextMigration.operationID })
            #expect(terminal.direction == .restore && terminal.isDataSwitchComplete)
            #expect(try fixture.store.managedLinks().isEmpty)
        }
        let group = try #require(DataTransferGroup.groups(from: fixture.store.transfers()).first)
        #expect(group.currentTransfer.operationID == terminal.operationID)
        #expect(group.canCleanup)
        #expect(group.retainedCopies.map(\.id) == [oldRestore.operationID])
        let active = try TreeCopySession.snapshot(at: fixture.local.resolvingSymlinksInPath())
        try FileManager.default.moveItem(at: offline, to: fixture.external)
        let cold = DataDirMover(homeDir: fixture.home, store: ContainerMountStore(fileURL: fixture.ledger), runner: fixture.runner)
        try await cold.cleanupRetainedLineage(operationID: terminal.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try TreeCopySession.snapshot(at: fixture.local.resolvingSymlinksInPath()) == active)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(FileManager.default.fileExists(atPath: nextDrive.appendingPathComponent("Payload").path) == !restoreAgain)
        #expect(try String(contentsOf: nextDrive.appendingPathComponent("sentinel.txt"), encoding: .utf8) == "unrelated")
    }

    @Test("A deleted new copy keeps its baseline until the removal fact is durably saved")
    func removalProofFailureCanRetryWithoutDeletingReusedPath() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        try await fixture.mover.restore(item: fixture.item, progressHandler: nil)
        let oldRestore = try #require(try fixture.store.transfers().first)
        let offline = fixture.root.appendingPathComponent("OfflineExternal")
        try FileManager.default.moveItem(at: fixture.external, to: offline)
        let nextDrive = fixture.root.appendingPathComponent("NextExternal")
        try FileManager.default.createDirectory(at: nextDrive, withIntermediateDirectories: false)

        writer.failRemovalProof = true
        let result = try await fixture.mover.migrateAndComplete(item: fixture.item, to: nextDrive, progressHandler: nil)
        #expect(result.cleanupWarning != nil)
        let pending = try #require(try fixture.store.transfers().first { $0.priorOperationID == oldRestore.operationID })
        let backup = URL(fileURLWithPath: try #require(pending.backupPath))
        #expect(pending.isDataSwitchComplete && pending.phase == .cleanupRequested)
        #expect(pending.retainedCopyRemovedAt == nil)
        #expect(pending.baseline != nil && pending.sourceBaseline != nil && pending.cleanupParentIdentity != nil)
        #expect(try TreeCopySession.retainedRemovalURL(at: backup, removalID: pending.operationID) == nil)
        let activeData = try TreeCopySession.snapshot(at: fixture.local.resolvingSymlinksInPath())

        writer.failRemovalProof = false
        let cold = DataDirMover(homeDir: fixture.home, store: ContainerMountStore(fileURL: fixture.ledger), runner: fixture.runner)
        // An empty replacement parent must not turn a missing path into proof
        // that AppPorts deleted it. The original online parent is required.
        let savedHome = fixture.root.appendingPathComponent("SavedHome")
        try FileManager.default.moveItem(at: fixture.home, to: savedHome)
        try FileManager.default.createDirectory(at: fixture.home, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await cold.cleanupRetainedTransfer(operationID: pending.operationID)
        }
        #expect(try fixture.store.transfer(operationID: pending.operationID)?.retainedCopyRemovedAt == nil)
        #expect(try fixture.store.transfer(operationID: pending.operationID)?.baseline == pending.baseline)
        try FileManager.default.removeItem(at: fixture.home)
        try FileManager.default.moveItem(at: savedHome, to: fixture.home)
        try await cold.cleanupRetainedTransfer(operationID: pending.operationID)
        let proof = try #require(try fixture.store.transfer(operationID: pending.operationID))
        #expect(proof.retainedCopyRemovedAt != nil)
        #expect(proof.baseline == nil && proof.sourceBaseline == nil && proof.preparationRemovalBaseline == nil)
        #expect(proof.sourceIdentity == pending.sourceIdentity && proof.destinationIdentity == pending.destinationIdentity)
        #expect(proof.materialPaths.isEmpty)
        let group = try #require(DataTransferGroup.groups(from: fixture.store.transfers()).first)
        #expect(group.retainedCopies.map(\.id) == [oldRestore.operationID])

        // The removed backup name is now free. Completing older A only
        // retires B's small identity node and must never delete a new occupant.
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        try Data("new unrelated content".utf8).write(to: backup.appendingPathComponent("sentinel.txt"))
        let replacement = try TreeCopySession.snapshot(at: backup)
        try FileManager.default.moveItem(at: offline, to: fixture.external)
        try await cold.cleanupRetainedLineage(operationID: pending.operationID)
        try await cold.cleanupRetainedTransfer(operationID: pending.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try TreeCopySession.snapshot(at: backup) == replacement)
        #expect(try TreeCopySession.snapshot(at: fixture.local.resolvingSymlinksInPath()) == activeData)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test("A new migration after restore still rejects changed local identity and the reserved old destination",
          arguments: ["local-replaced", "old-offline-target", "old-occupied-target", "old-staging-target"])
    func remigrationDoesNotBorrowOldRestoreAuthority(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        try await fixture.mover.restore(item: fixture.item, progressHandler: nil)
        let before = try fixture.store.transfers()
        let restore = try #require(before.first)
        let offline = fixture.root.appendingPathComponent("OfflineExternal")
        var target = fixture.root.appendingPathComponent("NextExternal")
        if change == "old-occupied-target" {
            target = fixture.external
            try Data("modified old copy".utf8).write(to: fixture.destination.appendingPathComponent("a.txt"))
        } else {
            try FileManager.default.moveItem(at: fixture.external, to: offline)
            if change == "old-offline-target" { target = fixture.external }
            if change == "old-staging-target" { target = URL(fileURLWithPath: try #require(restore.stagingPath)) }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        if change == "local-replaced" {
            try FileManager.default.moveItem(at: fixture.local, to: fixture.home.appendingPathComponent("SavedLocal"))
            try FileManager.default.createDirectory(at: fixture.local, withIntermediateDirectories: false)
            try Data("another installation's data".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        }
        let current = try TreeCopySession.snapshot(at: fixture.local)
        await #expect(throws: (any Error).self) {
            try await fixture.mover.migrateAndComplete(item: fixture.item, to: target, progressHandler: nil)
        }
        try expectTransfersUnchangedApartFromRetry(try fixture.store.transfers(), before)
        #expect(try TreeCopySession.snapshot(at: fixture.local) == current)
        #expect(try fixture.store.managedLinks().isEmpty)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: target.path).contains { $0.hasPrefix(".appports-copy-") })
    }

    @Test("A verified retry keeps its preceding restored-copy identity while the old drive is offline")
    func remigrationRecoveryKeepsPriorRestore() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        try await fixture.mover.restore(item: fixture.item, progressHandler: nil)
        let restored = try #require(try fixture.store.transfers().first)
        let offline = fixture.root.appendingPathComponent("OfflineExternal")
        try FileManager.default.moveItem(at: fixture.external, to: offline)
        let target = fixture.root.appendingPathComponent("NextExternal")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        writer.failTransition = ("migrate", "verified")
        await #expect(throws: (any Error).self) {
            try await fixture.mover.migrateAndComplete(item: fixture.item, to: target, progressHandler: nil)
        }
        let pending = try #require(try fixture.store.transfers().first { $0.priorOperationID == restored.operationID })
        writer.failTransition = nil
        let cold = DataDirMover(homeDir: fixture.home, store: ContainerMountStore(fileURL: fixture.ledger), runner: fixture.runner)
        #expect(try await cold.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) != nil)
        #expect(try fixture.store.transfer(operationID: pending.operationID)?.isDataSwitchComplete == true)
        #expect(try fixture.text("a.txt") == "first")
        try FileManager.default.moveItem(at: offline, to: fixture.external)
        try await cold.cleanupRetainedLineage(operationID: pending.operationID)
        #expect(try fixture.store.transfers().isEmpty)
    }

    @Test("Cancelling a new destination preserves an older offline copy and releases only the new attempt")
    func remigrationCancellationPreservesRestoredLineage() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        try await fixture.mover.restore(item: fixture.item, progressHandler: nil)
        let restored = try #require(try fixture.store.transfers().first)
        let localData = try TreeCopySession.snapshot(at: fixture.local)
        let offline = fixture.root.appendingPathComponent("OfflineExternal")
        try FileManager.default.moveItem(at: fixture.external, to: offline)
        let target = fixture.root.appendingPathComponent("NextExternal")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        writer.failTransition = ("migrate", "verified")
        await #expect(throws: (any Error).self) {
            try await fixture.mover.migrateAndComplete(item: fixture.item, to: target, progressHandler: nil)
        }
        let pending = try #require(try fixture.store.transfers().first { $0.priorOperationID == restored.operationID })
        #expect(pending.isPreparationRecoverable)
        writer.failTransition = nil
        let cold = DataDirMover(homeDir: fixture.home, store: ContainerMountStore(fileURL: fixture.ledger), runner: fixture.runner)
        try await cold.cancelPreparation(operationID: pending.operationID)
        try expectTransfersUnchangedApartFromRetry(try fixture.store.transfers(), [restored])
        #expect(try fixture.store.managedLinks().isEmpty)
        #expect(try TreeCopySession.snapshot(at: fixture.local) == localData)
        #expect(!FileManager.default.fileExists(atPath: try #require(pending.preparationPath)))
        #expect(try await cold.migrateAndComplete(item: fixture.item, to: target, progressHandler: nil).cleanupWarning != nil)
        let next = try #require(try fixture.store.transfers().first { $0.priorOperationID == restored.operationID })
        #expect(next.operationID != pending.operationID && next.retainedCopyRemovedAt != nil)
        try FileManager.default.moveItem(at: offline, to: fixture.external)
        try await cold.cleanupRetainedLineage(operationID: next.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.text("a.txt") == "first")
    }

    @Test("A changed ledger is never overwritten by a failed resume")
    func resumePreservesConcurrentLedgerChange() async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        writer.failTransition = ("migrate", "switching")
        await #expect(throws: (any Error).self) { try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil) }
        var transfer = try #require(try fixture.store.transfers().first)
        transfer.recoverableReason = "Updated by another operation"
        let changed = transfer
        writer.failTransition = nil
        let source = try TreeCopySession.snapshot(at: fixture.local)
        await #expect(throws: (any Error).self) {
            try await fixture.mover.resumeVerifiedTransfer(operationID: changed.operationID) { _ in
                try? fixture.store.updateTransfer(changed)
            }
        }
        #expect(try fixture.store.transfer(operationID: changed.operationID) == changed)
        #expect(try TreeCopySession.snapshot(at: fixture.local) == source)
    }

    @Test("The first cleanup rechecks data after saving its checkpoint", arguments: ["active-replace", "backup-remove"])
    func cleanupRechecksAfterCheckpoint(change: String) async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(writer: writer)
        defer { fixture.remove() }
        let transfer = try await fixture.retainedMigration()
        let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
        writer.onNextCheckpoint {
            if change == "active-replace" {
                try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("disconnected-active"))
                try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
                try Data("replacement".utf8).write(to: fixture.destination.appendingPathComponent("a.txt"))
            } else { try FileManager.default.removeItem(at: backup.appendingPathComponent("a.txt")) }
        }
        await #expect(throws: (any Error).self) { try await fixture.mover.cleanupRetainedTransfer(operationID: transfer.operationID) }
        #expect(try String(contentsOf: backup.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
        #expect(try fixture.store.transfer(operationID: transfer.operationID)?.phase == .cleanupRequested)
    }

    @Test("A single preference file can resume a completed switch", arguments: ["migrate", "restore"])
    func preferenceFileSwitchRetry(direction: String) async throws {
        let writer = AuditWriter()
        let fixture = try Fixture(fileRoot: true, writer: writer)
        defer { fixture.remove() }
        if direction == "restore" { _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil) }
        writer.failTransition = (direction, "awaitingUserVerification")
        await #expect(throws: (any Error).self) {
            if direction == "migrate" { try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil) }
            else { try await fixture.mover.restore(item: fixture.item, progressHandler: nil) }
        }
        let pending = try #require(try fixture.store.transfers().first)
        writer.failTransition = nil
        #expect(try await fixture.mover.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try Data(contentsOf: fixture.local) == Data("preference data".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["Payload"])
    }

    private struct Fixture: Sendable {
        let root: URL
        let home: URL
        let local: URL
        let external: URL
        let destination: URL
        let ledger: URL
        let store: ContainerMountStore
        let runner: any ShellCommandRunning
        var mover: DataDirMover { DataDirMover(homeDir: home, store: store, runner: runner) }
        var item: DataDirItem { .init(name: "Payload", path: local, type: .custom, priority: .optional, description: "") }

        init(fileRoot: Bool = false, runner: any ShellCommandRunning = InspectingRunner(), writer: AuditWriter = AuditWriter()) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsWorkflowAudit-\(UUID())").resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            local = home.appendingPathComponent("Payload")
            external = root.appendingPathComponent("External")
            destination = external.appendingPathComponent("Payload")
            ledger = root.appendingPathComponent("records.plist")
            self.runner = runner
            store = ContainerMountStore(fileURL: ledger, writeData: { try writer.write($0, to: $1) })
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            if fileRoot {
                try Data("preference data".utf8).write(to: local)
            } else {
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
                try Data("first".utf8).write(to: local.appendingPathComponent("a.txt"))
                try Data("second".utf8).write(to: local.appendingPathComponent("b.txt"))
            }
        }

        func retainedMigration() async throws -> DataTransferRecord {
            try await mover.migrate(item: item, to: external, progressHandler: nil)
            return try #require(try store.transfers().first)
        }
        func checkpoint(_ transfer: DataTransferRecord) throws {
            let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
            try store.requestCleanup(operationID: transfer.operationID)
            try store.beginCleanupDeletion(operationID: transfer.operationID,
                parentIdentity: DataPathIdentity.capture(backup.deletingLastPathComponent().resolvingSymlinksInPath()))
        }
        func text(_ name: String) throws -> String { try String(contentsOf: local.appendingPathComponent(name), encoding: .utf8) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class InspectingRunner: ShellCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable () throws -> Void)?
        func onNextInspection(_ body: @escaping @Sendable () throws -> Void) { lock.lock(); callback = body; lock.unlock() }
        private func inspect() throws {
            lock.lock()
            let action = callback
            callback = nil
            lock.unlock()
            try action?()
        }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            try inspect()
            return .init(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
        }
    }

    private final class AuditWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var rejectCopying = false
        private var rejectCheckpoint = false
        private var rejectRemovalProof = false
        private var rejectedTransition: (String, String)?
        private var checkpointAction: (@Sendable () throws -> Void)?
        func onNextCheckpoint(_ action: @escaping @Sendable () throws -> Void) {
            lock.lock(); checkpointAction = action; lock.unlock()
        }
        var failTransition: (String, String)? {
            get { lock.lock(); defer { lock.unlock() }; return rejectedTransition }
            set { lock.lock(); rejectedTransition = newValue; lock.unlock() }
        }
        var failRestoreCopying: Bool {
            get { lock.lock(); defer { lock.unlock() }; return rejectCopying }
            set { lock.lock(); rejectCopying = newValue; lock.unlock() }
        }
        var failCheckpoint: Bool {
            get { lock.lock(); defer { lock.unlock() }; return rejectCheckpoint }
            set { lock.lock(); rejectCheckpoint = newValue; lock.unlock() }
        }
        var failRemovalProof: Bool {
            get { lock.lock(); defer { lock.unlock() }; return rejectRemovalProof }
            set { lock.lock(); rejectRemovalProof = newValue; lock.unlock() }
        }
        func write(_ data: Data, to url: URL) throws {
            lock.lock(); defer { lock.unlock() }
            let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let transfers = document?["transfers"] as? [[String: Any]] ?? []
            if rejectCopying && transfers.contains(where: { $0["direction"] as? String == "restore" && $0["phase"] as? String == "copying" }) {
                throw CocoaError(.fileWriteNoPermission)
            }
            if rejectCheckpoint && transfers.contains(where: { $0["cleanupParentIdentity"] != nil }) { throw CocoaError(.fileWriteNoPermission) }
            if rejectRemovalProof && transfers.contains(where: { $0["retainedCopyRemovedAt"] != nil }) { throw CocoaError(.fileWriteNoPermission) }
            if let rejectedTransition, transfers.contains(where: {
                $0["direction"] as? String == rejectedTransition.0 && $0["phase"] as? String == rejectedTransition.1
            }) { throw CocoaError(.fileWriteNoPermission) }
            if transfers.contains(where: { $0["cleanupParentIdentity"] != nil }), let action = checkpointAction {
                checkpointAction = nil
                try action()
            }
            try data.write(to: url, options: .atomic)
        }
    }
}
