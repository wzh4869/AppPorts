import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DataPreparationRecoveryTests {
    @Test("Maintenance retires claimed inactive restore staging while preserving newer active data",
          arguments: ["claimed", "replaced", "unclaimed", "empty-active", "no-baseline", "changed", "new-file", "partial-removal"])
    func retiresPreservedRestoreStage(_ scenario: String) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        let id = UUID()
        let staging = fixture.local.deletingLastPathComponent().appendingPathComponent(".appports-restore-staging-" + id.uuidString)
        let recovery = fixture.root.appendingPathComponent("mounts/recovery-" + id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("older private copy".utf8).write(to: staging.appendingPathComponent("a.txt"))
        var transfer = DataTransferRecord(operationID: id, mode: .mount, direction: .restore,
            appName: "Fixture", dataDirType: DataDirType.containers.rawValue,
            originalPath: fixture.local.path, activePath: fixture.local.path, destinationPath: fixture.local.path,
            backupPath: recovery.path, sourceIdentity: try DataPathIdentity.capture(fixture.local))
        transfer.stagingPath = staging.path
        transfer.preparationPath = staging.path
        transfer.preparationParentIdentity = try DataPathIdentity.capture(staging.deletingLastPathComponent())
        transfer.destinationIdentity = try DataPathIdentity.capture(staging)
        transfer.phase = .copying
        if scenario != "no-baseline" && scenario != "empty-active" {
            transfer.baseline = try PropertyListEncoder().encode(TreeCopySession.snapshot(at: staging))
        }
        if scenario == "changed" { try Data("unique changed bytes".utf8).write(to: staging.appendingPathComponent("a.txt")) }
        if scenario == "new-file" { try Data("unique document".utf8).write(to: staging.appendingPathComponent("new.txt")) }
        let candidate = try TreeCopySession.snapshot(at: staging)
        if scenario == "partial-removal" {
            transfer.preparationRemovalBaseline = try PropertyListEncoder().encode(candidate)
            transfer.preparationRemovalParentIdentity = transfer.preparationParentIdentity
            try FileManager.default.removeItem(at: staging.appendingPathComponent("a.txt"))
        }
        var material = DataTransferMaterial(transfer: transfer, reason: "Interrupted restore")
        if scenario == "unclaimed" { material.recoveryRecord = nil }
        if scenario == "replaced" {
            try FileManager.default.moveItem(at: staging, to: fixture.root.appendingPathComponent("original-stage"))
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try Data("unclaimed replacement".utf8).write(to: staging.appendingPathComponent("a.txt"))
        }
        if scenario == "empty-active" {
            for name in try FileManager.default.contentsOfDirectory(atPath: fixture.local.path) {
                try FileManager.default.removeItem(at: fixture.local.appendingPathComponent(name))
            }
        } else { try Data("latest application data".utf8).write(to: fixture.local.appendingPathComponent("a.txt")) }
        let active = try TreeCopySession.snapshot(at: fixture.local)
        let encoded = try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(material), format: nil)
        try DurableFileIO.write(PropertyListSerialization.data(fromPropertyList: ["schemaVersion": 9,
            "mounts": [], "cleanups": [], "transfers": [], "preservedMaterials": [encoded]], format: .binary, options: 0), to: fixture.ledger)
        let messages = await fixture.mountMover().performAutomaticMaintenance()
        #expect(try TreeCopySession.snapshot(at: fixture.local) == active)
        if scenario == "claimed" || scenario == "partial-removal" {
            #expect(messages.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: staging.path))
            #expect(try fixture.store.preservedMaterials().isEmpty)
        } else {
            #expect(FileManager.default.fileExists(atPath: staging.path))
            let remaining = try #require(try fixture.store.preservedMaterials().first)
            #expect(remaining.recoveryRecord == material.recoveryRecord)
            if scenario != "replaced" { #expect(try TreeCopySession.snapshot(at: staging) == candidate) }
            if scenario != "unclaimed" {
                #expect(remaining.retryFailureCount == 1)
                #expect(remaining.nextAutomaticRetryAt != nil)
            }
        }
    }

    @Test("A partial real copy can be cancelled or restarted after reopening its ledger",
          arguments: ["symlink-migrate", "symlink-restore", "mount-migrate", "mount-restore"], [1, 4])
    func partialCopyHasExit(scenario: String, copies: Int) async throws {
        for restart in [false, true] {
            try await checkPartialCopyExit(scenario: scenario, restart: restart, copies: copies)
        }
    }

    private func checkPartialCopyExit(scenario: String, restart: Bool, copies: Int) async throws {
        let fixture = try Fixture(mount: scenario.hasPrefix("mount"))
        defer { fixture.remove() }
        let restore = scenario.hasSuffix("restore")
        if restore { try await fixture.migrateFirst() }
        let authority = fixture.authoritativeSource(restore: restore)
        let original = try TreeCopySession.snapshot(at: authority)
        let operation = Task {
            try await TreeCopySession.$concurrentSmallFileCopies.withValue(copies) {
                try await fixture.perform(restore: restore) { progress in
                    if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
        }
        await #expect(throws: (any Error).self) { try await operation.value }
        let pending = try #require(try fixture.store.transfers().last)
        #expect(pending.isPreparationRecoverable)
        #expect(pending.sourceBaseline != nil)
        #expect(pending.baseline == nil)
        #expect(pending.destinationIdentity != nil)
        let candidate = URL(fileURLWithPath: try #require(pending.preparationPath))
        #expect(try String(contentsOf: candidate.appendingPathComponent("a.txt"), encoding: .utf8) == "first")
        if copies == 1 {
            #expect(!FileManager.default.fileExists(atPath: candidate.appendingPathComponent("b.txt").path))
        } else {
            #expect(try String(contentsOf: candidate.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
        }
        let stopped = try TreeCopySession.snapshot(at: candidate)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(try TreeCopySession.snapshot(at: candidate) == stopped)
        #expect(!pending.isDataSwitchComplete)
        #expect(try TreeCopySession.snapshot(at: authority) == original)

        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if restart {
            let warning: String?
            if fixture.mount { warning = try await fixture.mountMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) }
            else { warning = try await fixture.dataMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) }
            #expect(warning == nil)
            #expect(try String(contentsOf: fixture.local.appendingPathComponent("a.txt"), encoding: .utf8) == "first")
            #expect(try String(contentsOf: fixture.local.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
        } else {
            if fixture.mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
            else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID) }
            #expect(try TreeCopySession.snapshot(at: authority) == original)
            if fixture.mount {
                #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == (restore ? 0 : 1))
            }
        }
        #expect(try cold.transfers().isEmpty)
        #expect(try cold.preservedMaterials().isEmpty)
    }

    @Test("Unknown creation windows remain visible after ending their reservation",
          arguments: ["symlink-migrate", "symlink-restore", "mount-migrate", "mount-restore"])
    func unknownCreationIsPreserved(scenario: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: scenario.hasPrefix("mount"), writer: writer)
        defer { fixture.remove() }
        let restore = scenario.hasSuffix("restore")
        if restore { try await fixture.migrateFirst() }
        writer.rejectNext(field: "destinationIdentity")
        await #expect(throws: (any Error).self) { try await fixture.perform(restore: restore, progress: nil) }
        let pending = try #require(try fixture.store.transfers().last)
        #expect(pending.sourceBaseline != nil)
        #expect(pending.destinationIdentity == nil)
        let candidate = URL(fileURLWithPath: try #require(pending.preparationPath))
        try Data("unique material".utf8).write(to: candidate.appendingPathComponent("unclaimed.txt"))
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        await #expect(throws: (any Error).self) {
            if fixture.mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
            else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID) }
        }
        if fixture.mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID, preserveUnclaimedMaterials: true) }
        else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID, preserveUnclaimedMaterials: true) }
        #expect(try cold.transfers().isEmpty)
        let material = try #require(try cold.preservedMaterials().first)
        #expect(material.id == pending.operationID)
        #expect(material.paths.contains(candidate.path))
        #expect(try String(contentsOf: candidate.appendingPathComponent("unclaimed.txt"), encoding: .utf8) == "unique material")
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("Failed mount candidates are disposable, while replaced roots and strict symlink copies are preserved",
          arguments: [false, true], ["source-write", "extra-file", "root-replaced", "parent-replaced"])
    func partialConflictsPreserveEverything(mount: Bool, conflict: String) async throws {
        let fixture = try Fixture(mount: mount)
        defer { fixture.remove() }
        let task = Task {
            try await fixture.perform(restore: false) { progress in
                if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        let pending = try #require(try fixture.store.transfers().first)
        let candidate = URL(fileURLWithPath: try #require(pending.preparationPath))
        if conflict == "source-write" { try Data("later source write".utf8).write(to: fixture.local.appendingPathComponent("a.txt")) }
        if conflict == "extra-file" { try Data("unique".utf8).write(to: candidate.appendingPathComponent("new.txt")) }
        if conflict == "root-replaced" {
            try FileManager.default.moveItem(at: candidate, to: fixture.root.appendingPathComponent("saved-candidate"))
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            try Data("replacement".utf8).write(to: candidate.appendingPathComponent("new.txt"))
        }
        if conflict == "parent-replaced" {
            let parent = candidate.deletingLastPathComponent()
            try FileManager.default.moveItem(at: parent, to: fixture.root.appendingPathComponent("saved-parent"))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        let source = try TreeCopySession.snapshot(at: fixture.local)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let disposable = mount && ["source-write", "extra-file"].contains(conflict)
        if disposable {
            try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID)
            #expect(try cold.transfer(operationID: pending.operationID) == nil)
            #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        } else {
            await #expect(throws: (any Error).self) {
                if mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
                else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID) }
            }
            #expect(try cold.transfer(operationID: pending.operationID) != nil)
            #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        }
        #expect(try TreeCopySession.snapshot(at: fixture.local) == source)
    }

    @Test("Upgraded failed copies discard candidate writes but retain the current source", arguments: Array(7...12), [false, true])
    func upgradedFailedCandidate(schema: Int, rolledBack: Bool) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        let pending = try await fixture.interruptMigration()
        let candidate = URL(fileURLWithPath: try #require(pending.stagingPath))
        try Data("latest original data".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        try Data("disposable candidate write".utf8).write(to: candidate.appendingPathComponent("unique.txt"))
        let source = try TreeCopySession.snapshot(at: fixture.local)
        // Re-encode the exact on-disk layout accepted by old writers. The
        // original 1.9.2/1.9.3 journals used schema 7–9 without activation facts.
        try fixture.rewriteJournal { document, transfers in
            document["schemaVersion"] = max(schema, rolledBack ? 9 : schema)
            if schema < 12 { transfers[0].removeValue(forKey: "candidateActivationAttempted") }
            if rolledBack { transfers[0]["rollbackCompletedAt"] = Date(timeIntervalSince1970: 10) }
        }
        let bytes = try Data(contentsOf: fixture.ledger)
        let diskState = fixture.root.appendingPathComponent("fake-disks.plist")
        try fixture.runner.saveSimulationState(to: diskState)
        let coldRunner = try FakeDiskCommandRunner.reopenSimulationState(from: diskState)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let loaded = try #require(try cold.transfer(operationID: pending.operationID))
        #expect(loaded.candidateActivationAttempted == (schema < 12 ? nil : false))
        #expect(try Data(contentsOf: fixture.ledger) == bytes)
        #expect(await fixture.mountMover(store: cold, runnerOverride: coldRunner).performAutomaticMaintenance().isEmpty)
        #expect(try cold.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        #expect(try TreeCopySession.snapshot(at: fixture.local) == source)
        #expect(coldRunner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        #expect(await fixture.mountMover(store: ContainerMountStore(fileURL: fixture.ledger), runnerOverride: coldRunner).performAutomaticMaintenance().isEmpty)
        #expect(coldRunner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
    }

    @Test("Reconnected failed candidates at the system automount are reclaimed after a cold upgrade", arguments: [9, 12], [false, true])
    func reconnectedFailedCandidate(schema: Int, rolledBack: Bool) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        let pending = try await fixture.interruptMigration()
        let automatic = try await fixture.automountCandidate(pending)
        try Data("latest original data".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        try Data("disposable candidate write".utf8).write(to: automatic.appendingPathComponent("unique.txt"))
        let source = try TreeCopySession.snapshot(at: fixture.local)
        try fixture.rewriteJournal { document, transfers in
            document["schemaVersion"] = schema
            if schema < 12 { transfers[0].removeValue(forKey: "candidateActivationAttempted") }
            if schema == 12 {
                // The real build 44 unplug occurred after verification but
                // before activation. Only its explicit false makes it disposable.
                transfers[0]["baseline"] = transfers[0]["sourceBaseline"]
                transfers[0]["phase"] = "needsRecovery"
            }
            if rolledBack { transfers[0]["rollbackCompletedAt"] = Date(timeIntervalSince1970: 10) }
            // Reattachment changes st_dev, while UUID and root inode survive.
            var identity = try #require(transfers[0]["destinationIdentity"] as? [String: Any])
            identity["device"] = 1
            transfers[0]["destinationIdentity"] = identity
        }
        let diskState = fixture.root.appendingPathComponent("fake-disks.plist")
        try fixture.runner.saveSimulationState(to: diskState)
        let coldRunner = try FakeDiskCommandRunner.reopenSimulationState(from: diskState)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let mover = fixture.mountMover(store: cold, runnerOverride: coldRunner)
        #expect(await mover.performAutomaticMaintenance().isEmpty)
        #expect(try cold.transfers().isEmpty)
        #expect(try TreeCopySession.snapshot(at: fixture.local) == source)
        #expect(coldRunner.commands(prefix: ["unmount", "disk7s9"]).count == 1)
        #expect(coldRunner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        #expect(await mover.performAutomaticMaintenance().isEmpty)
        #expect(coldRunner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
    }

    @Test("Unproven or busy automounts remain intact and manual retry reports the remaining cleanup",
          arguments: ["missing-marker", "wrong-name", "root-replaced", "path-reference", "foreign-volume", "busy", "attempted"])
    func unsafeAutomountedCandidate(_ scenario: String) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        let pending = try await fixture.interruptMigration()
        let automatic = try await fixture.automountCandidate(pending, name: scenario == "wrong-name" ? "Other" : nil)
        if scenario == "missing-marker" {
            try FileManager.default.removeItem(at: automatic.appendingPathComponent(ContainerVolumeMigrator.volumeMarkerFileName))
        }
        if scenario == "root-replaced" {
            let saved = fixture.root.appendingPathComponent("saved-candidate")
            try FileManager.default.moveItem(at: automatic, to: saved)
            try FileManager.default.copyItem(at: saved, to: automatic)
        }
        if scenario == "path-reference" {
            try fixture.store.upsert(ContainerMountRecord(appName: "Other", bundleIdentifier: nil,
                dataDirType: DataDirType.containers.rawValue,
                mountPointPath: automatic.appendingPathComponent("owned-by-other").path,
                volumeUUID: "OTHER-VOLUME", volumeName: "Other", externalRootPath: fixture.external.path))
        }
        if scenario == "attempted" {
            try fixture.rewriteJournal { _, transfers in
                transfers[0]["candidateActivationAttempted"] = true
                transfers[0]["baseline"] = transfers[0]["sourceBaseline"]
            }
        }
        try fixture.rewriteJournal { _, transfers in
            transfers[0]["rollbackCompletedAt"] = Date(timeIntervalSince1970: 10)
        }
        let source = try TreeCopySession.snapshot(at: fixture.local)
        let payload = try TreeCopySession.snapshot(at: automatic)
        let mover = fixture.mountMover(
            mountedVolumeUUID: { scenario == "foreign-volume" && $0.path == automatic.path ? "OTHER-VOLUME" : fixture.runner.mountedUUID(at: $0) },
            safetyRunner: CandidateWritersRunner(busyPath: scenario == "busy" ? automatic.path : nil))
        let warnings = await mover.performAutomaticMaintenance(only: pending.operationID, ignoresRetryBackoff: true)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("原数据入口已恢复；自动清理尚未完成：".localized) == true)
        #expect(try fixture.store.transfer(operationID: pending.operationID) != nil)
        #expect(fixture.runner.commands(prefix: ["unmount", "disk7s9"]).isEmpty)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try TreeCopySession.snapshot(at: automatic) == payload)
        #expect(try TreeCopySession.snapshot(at: fixture.local) == source)
    }

    private struct CandidateWritersRunner: ShellCommandRunning {
        let busyPath: String?
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            if let busyPath, arguments.contains(busyPath) {
                return ShellCommandResult(status: 0, standardOutput: Data("p999999\ncWriter\nf3\naw\n".utf8), standardError: Data(), timedOut: false)
            }
            return try await SyntheticNoWritersRunner().run(executable: executable, arguments: arguments, timeout: timeout)
        }
    }

    @Test("Verified but never activated candidates are disposable; unknown or attempted activation retains changed data",
          arguments: ["new", "legacy", "attempted"])
    func verifiedCandidateDisposal(_ history: String) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) {
            try await fixture.perform(restore: false) { progress in
                if progress.stage == .switching {
                    try? Data("source changed before activation".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
                }
            }
        }
        let pending = try #require(try fixture.store.transfers().first)
        #expect(pending.baseline != nil)
        #expect(pending.candidateActivationAttempted == false)
        let candidate = URL(fileURLWithPath: try #require(pending.stagingPath))
        // The normal path already unmounted its verified candidate.
        let payload = fixture.runner.detachedContents(for: try #require(pending.createdVolumeUUID)) ?? candidate
        try Data("candidate-only write".utf8).write(to: payload.appendingPathComponent("unique.txt"))
        try fixture.rewriteJournal { document, transfers in
            if history == "legacy" {
                document["schemaVersion"] = 9
                transfers[0].removeValue(forKey: "candidateActivationAttempted")
            } else if history == "attempted" { transfers[0]["candidateActivationAttempted"] = true }
        }
        let source = try TreeCopySession.snapshot(at: fixture.local)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        _ = await fixture.mountMover(store: cold).performAutomaticMaintenance()
        #expect(try TreeCopySession.snapshot(at: fixture.local) == source)
        if history == "new" {
            #expect(try cold.transfers().isEmpty)
            #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
            #expect(!FileManager.default.fileExists(atPath: candidate.path))
        } else {
            #expect(try cold.transfer(operationID: pending.operationID)?.rollbackCompletedAt != nil)
            #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
            #expect(try String(contentsOf: candidate.appendingPathComponent("unique.txt"), encoding: .utf8) == "candidate-only write")
        }
    }

    @Test("New unreadable source children do not strand a never activated candidate")
    func unreadableNewSourceChild() async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        _ = try await fixture.interruptMigration()
        let temporary = fixture.local.appendingPathComponent(".TemporaryItems")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let payload = temporary.appendingPathComponent("live-application-data")
        try Data("keep this source data".utf8).write(to: payload)
        try #require(chmod(temporary.path, 0) == 0)
        defer { _ = chmod(temporary.path, 0o700) }
        _ = await fixture.mountMover(store: ContainerMountStore(fileURL: fixture.ledger)).performAutomaticMaintenance()
        #expect(try fixture.store.transfers().isEmpty)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        try #require(chmod(temporary.path, 0o700) == 0)
        #expect(try String(contentsOf: payload, encoding: .utf8) == "keep this source data")
    }

    @Test("Failed candidate cleanup survives deletion and journal failures and honors automatic backoff",
          arguments: ["delete", "final-save", "checkpoint-save"])
    func failedCandidateCleanupRetries(_ failure: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: true, writer: writer)
        defer { fixture.remove() }
        let pending = try await fixture.interruptMigration()
        try Data("source remains authoritative".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        let source = try TreeCopySession.snapshot(at: fixture.local)
        if failure == "delete" { fixture.runner.failWhen(prefix: ["apfs", "deleteVolume"]) }
        if failure == "final-save" { writer.rejectEmptyUntilCleared() }
        if failure == "checkpoint-save" { writer.rejectAlways(field: "preparationRemovalParentIdentity") }
        let time = Date(timeIntervalSince1970: 1_000)
        _ = await fixture.mountMover().performAutomaticMaintenance(now: { time })
        let retained = try #require(try fixture.store.transfer(operationID: pending.operationID))
        #expect(retained.rollbackCompletedAt != nil)
        #expect(retained.retryFailureCount == 1)
        let deletions = fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count
        fixture.runner.clearFailure()
        writer.clearFault()
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        _ = await fixture.mountMover(store: cold).performAutomaticMaintenance(now: { time.addingTimeInterval(1) })
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == deletions)
        _ = await fixture.mountMover(store: cold).performAutomaticMaintenance(now: { time.addingTimeInterval(61) })
        #expect(try cold.transfers().isEmpty)
        #expect(try TreeCopySession.snapshot(at: fixture.local) == source)
        if failure == "final-save" { #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1) }
    }

    @Test("Failing to persist the activation attempt prevents any mount at the application entry")
    func activationSaveFailurePreventsSwitch() async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: true, writer: writer)
        defer { fixture.remove() }
        writer.rejectActivationAttempt()
        await #expect(throws: (any Error).self) { try await fixture.perform(restore: false, progress: nil) }
        let pending = try #require(try fixture.store.transfers().first)
        #expect(pending.candidateActivationAttempted == false)
        #expect(pending.baseline != nil)
        #expect(fixture.runner.commands(prefix: ["mount"]).allSatisfy { !$0.contains(fixture.local.path) })
        // A cold retry can now activate only after it successfully saves true.
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        _ = try await fixture.mountMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
        #expect(fixture.runner.isMounted(fixture.local))
        #expect(try String(contentsOf: fixture.local.appendingPathComponent("a.txt"), encoding: .utf8) == "first")
    }

    @Test("An unrelated record referencing the same candidate volume blocks whole-volume deletion",
          arguments: ["mount", "material", "material-recovery"])
    func anotherRecordOwnsCandidate(_ owner: String) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        let pending = try await fixture.interruptMigration()
        let uuid = try #require(pending.createdVolumeUUID)
        try fixture.store.finishAutomaticMountRollback(pending, preserving: "test pending cleanup", verifyingFilesystem: {})
        if owner == "mount" {
            let original = try #require(pending.recoveryMountRecord)
            let record = ContainerMountRecord(appName: original.appName, bundleIdentifier: original.bundleIdentifier,
                dataDirType: original.dataDirType, mountPointPath: fixture.home.appendingPathComponent("Other").path,
                volumeUUID: uuid, volumeName: original.volumeName, externalRootPath: original.externalRootPath)
            try fixture.store.upsert(record)
        } else {
            var other = pending
            other.originalPath = fixture.home.appendingPathComponent("Other").path
            let material = DataTransferMaterial(transfer: other, reason: "independent reference")
            // Keep the reference at a different path so only UUID ownership
            // can detect it, including a legacy summary lacking its UUID.
            var encoded = try #require(try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(material), format: nil) as? [String: Any])
            encoded["id"] = UUID().uuidString
            encoded["paths"] = [fixture.home.appendingPathComponent("Elsewhere").path]
            if owner == "material-recovery" { encoded.removeValue(forKey: "volumeUUID") }
            else { encoded.removeValue(forKey: "recoveryRecord") }
            try fixture.rewriteJournal { document, _ in document["preservedMaterials"] = [encoded] }
        }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        _ = await fixture.mountMover(store: cold).performAutomaticMaintenance()
        #expect(try cold.transfer(operationID: pending.operationID) != nil)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(fixture.runner.mountedUUID(at: URL(fileURLWithPath: try #require(pending.stagingPath))) == uuid)
    }

    @Test("Late system remounts or ledger references during the final device query prevent deletion", arguments: [false, true])
    func lateDeletionConflict(reference: Bool) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        let pending = try await fixture.interruptMigration()
        let uuid = try #require(pending.createdVolumeUUID)
        let otherPath = fixture.home.appendingPathComponent("Other")
        let diskRunner = FinalDeviceQueryRunner(base: fixture.runner) {
            if reference {
                let record = try #require(pending.recoveryMountRecord)
                try fixture.store.upsert(ContainerMountRecord(appName: record.appName,
                    bundleIdentifier: record.bundleIdentifier, dataDirType: record.dataDirType,
                    mountPointPath: otherPath.path, volumeUUID: uuid, volumeName: record.volumeName,
                    externalRootPath: record.externalRootPath))
            } else { fixture.runner.markVolumeMounted(uuid, at: otherPath.path) }
        }
        await #expect(throws: (any Error).self) {
            try await fixture.mountMover(diskRunner: diskRunner).cancelPreparation(operationID: pending.operationID)
        }
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try fixture.store.transfer(operationID: pending.operationID) != nil)
    }

    @Test("Missing deleted placeholders still require their parent synchronization on cold retry")
    func deletedPlaceholderRetriesBarrier() async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        let pending = try await fixture.interruptMigration()
        let probe = SyncProbe()
        let candidate = URL(fileURLWithPath: try #require(pending.stagingPath))
        for _ in 0..<2 {
            let cold = ContainerMountStore(fileURL: fixture.ledger)
            await #expect(throws: (any Error).self) {
                try await fixture.mountMover(store: cold, synchronizeCleanupParent: {
                    probe.record($0)
                    throw POSIXError(.EIO)
                }).cancelPreparation(operationID: pending.operationID)
            }
            #expect(try cold.transfer(operationID: pending.operationID) != nil)
            #expect(!FileManager.default.fileExists(atPath: candidate.path))
        }
        #expect(probe.paths.count == 2)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        let parent = candidate.deletingLastPathComponent()
        let saved = fixture.root.appendingPathComponent("saved-mount-parent")
        try FileManager.default.moveItem(at: parent, to: saved)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await fixture.mountMover().cancelPreparation(operationID: pending.operationID)
        }
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: saved, to: parent)
        try await fixture.mountMover(store: ContainerMountStore(fileURL: fixture.ledger)).cancelPreparation(operationID: pending.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
    }

    @Test("Recovery adopts only an empty replacement placeholder after its claim save failed")
    func cleanupPlaceholderClaimSaveFailure() async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: true, writer: writer)
        defer { fixture.remove() }
        fixture.runner.failWhen(prefix: ["mount", "nobrowse", "-mountPoint", fixture.local.path])
        await #expect(throws: (any Error).self) { try await fixture.perform(restore: false, progress: nil) }
        let pending = try #require(try fixture.store.transfers().first)
        writer.rejectNext(field: "candidateRemovalMountPointIdentity")
        await #expect(throws: (any Error).self) { try await fixture.mountMover().recoverWithIndependentBudget(pending) }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let retry = try #require(try cold.transfer(operationID: pending.operationID))
        #expect(retry.candidateRemovalMountPointIdentity == nil)
        _ = try await fixture.mountMover(store: cold).recoverWithIndependentBudget(retry)
        #expect(try cold.transfers().isEmpty)
        #expect(try String(contentsOf: fixture.local.appendingPathComponent("a.txt"), encoding: .utf8) == "first")
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
    }

    @Test("Legacy missing claims, foreign mounts, replaced sources, user deferral and offline containers remain intact",
          arguments: ["missing-parent", "missing-claim", "missing-marker", "foreign-mount", "source-replaced", "deferred", "offline"])
    func unsafeFailedCandidateIsRetained(_ scenario: String) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        let pending = try await fixture.interruptMigration()
        let candidate = URL(fileURLWithPath: try #require(pending.stagingPath))
        try Data("candidate-only data".utf8).write(to: candidate.appendingPathComponent("unique.txt"))
        try fixture.rewriteJournal { document, transfers in
            document["schemaVersion"] = 10
            transfers[0].removeValue(forKey: "candidateActivationAttempted")
            if scenario == "missing-parent" { transfers[0].removeValue(forKey: "stagingParentIdentity") }
            if scenario == "missing-claim" { transfers[0].removeValue(forKey: "destinationIdentity") }
            if scenario == "deferred" { transfers[0]["cleanupDisposition"] = "deferred" }
        }
        if scenario == "missing-marker" { try FileManager.default.removeItem(at: candidate.appendingPathComponent(ContainerVolumeMigrator.volumeMarkerFileName)) }
        if scenario == "foreign-mount" { fixture.runner.markVolumeMounted(try #require(pending.createdVolumeUUID), at: fixture.root.appendingPathComponent("foreign").path) }
        if scenario == "source-replaced" {
            try FileManager.default.moveItem(at: fixture.local, to: fixture.root.appendingPathComponent("saved-source"))
            try FileManager.default.createDirectory(at: fixture.local, withIntermediateDirectories: false)
            try Data("replacement source".utf8).write(to: fixture.local.appendingPathComponent("a.txt"))
        }
        if scenario == "offline" { fixture.runner.failWhen(prefix: ["apfs", "list"]) }
        let source = try TreeCopySession.snapshot(at: fixture.local)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        _ = await fixture.mountMover(store: cold).performAutomaticMaintenance()
        #expect(try cold.transfer(operationID: pending.operationID) != nil)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try TreeCopySession.snapshot(at: fixture.local) == source)
        #expect(try String(contentsOf: candidate.appendingPathComponent("unique.txt"), encoding: .utf8) == "candidate-only data")
    }

    @Test("A failed verified-baseline save can promote the complete candidate without recopying", arguments: [false, true])
    func completeCandidateSurvivesBaselineSave(mount: Bool) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: mount, writer: writer)
        defer { fixture.remove() }
        writer.rejectNext(field: "baseline")
        await #expect(throws: (any Error).self) { try await fixture.perform(restore: false, progress: nil) }
        let pending = try #require(try fixture.store.transfers().first)
        let identity = try #require(pending.destinationIdentity)
        #expect(pending.baseline == nil)
        let creations = fixture.runner.commands(prefix: ["apfs", "addVolume"])
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let observer = DataTransferProgress()
        let warning = try await observer.track { update -> String? in
            let progress: FileCopier.ProgressHandler = { value in
                await update(value)
                if value.stage == .switching {
                    // This original protection callback precedes final proof;
                    // it must not present an entry commit that has not begun.
                    #expect(observer.snapshot().directoryStep == 3)
                    #expect(observer.snapshot().unitFraction < 0.88)
                }
            }
            if mount { return try await fixture.mountMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: progress) }
            return try await fixture.dataMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: progress)
        }
        #expect(warning == nil)
        #expect(observer.snapshot().directoryStep == 5)
        #expect(observer.snapshot().hasEnteredCleanup)
        let active = mount ? fixture.local : fixture.external.appendingPathComponent("Payload")
        #expect(try DataPathIdentity.capture(active, volumeUUID: mount ? pending.createdVolumeUUID : nil).matchesFilesystemObject(identity))
        #expect(fixture.runner.commands(prefix: ["apfs", "addVolume"]) == creations)
    }

    @Test("A noowners restore partial can cancel or restart without leaving temporary ownership options", arguments: [false, true])
    func noownersPartialRestore(restart: Bool) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let runner = fixture.runner, local = fixture.local
        let previousCallCount = runner.calls.count
        let flags: @Sendable (URL) -> UInt32? = { url in
            guard url.path == local.path else { return UInt32(MNT_DONTBROWSE) }
            var noowners = true
            for call in runner.calls.dropFirst(previousCallCount) {
                let arguments = call.arguments
                if arguments.first == "-u", arguments.count >= 3 {
                    noowners = arguments[2].split(separator: ",").contains("noowners")
                } else if arguments.first == "mount", arguments.count == 7, arguments[3] == local.path {
                    noowners = arguments[5] == "noowners"
                }
            }
            return UInt32(MNT_DONTBROWSE | MNT_NODEV | MNT_NOSUID) | (noowners ? UInt32(MNT_IGNORE_OWNERSHIP) : 0)
        }
        let source = try TreeCopySession.snapshot(at: local)
        let record = try #require(try fixture.store.recordsStrict().first)
        let task = Task {
            try await fixture.mountMover(mountFlags: flags).restore(record: record, estimatedTotalBytes: 0) { progress in
                if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        let pending = try #require(try fixture.store.transfers().first)
        #expect(pending.sourceBaseline != nil)
        #expect(pending.originalSourceMountFlags.map { $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 } == true)
        #expect(flags(local).map { $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 } == true)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if restart {
            #expect(try await fixture.mountMover(store: cold, mountFlags: flags).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
            #expect(!runner.isMounted(local))
            #expect(try String(contentsOf: local.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
        } else {
            try await fixture.mountMover(store: cold, mountFlags: flags).cancelPreparation(operationID: pending.operationID)
            #expect(flags(local).map { $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 } == true)
            #expect(try TreeCopySession.snapshot(at: local) == source)
        }
        #expect(try cold.transfers().isEmpty)
    }

    @Test("Cancellation can finish after its candidate was removed but the final record save failed",
          arguments: ["symlink-migrate", "symlink-restore", "mount-migrate", "mount-restore"])
    func cancelAfterFinalSaveFailure(scenario: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: scenario.hasPrefix("mount"), writer: writer)
        defer { fixture.remove() }
        let restore = scenario.hasSuffix("restore")
        if restore { try await fixture.migrateFirst() }
        let authority = fixture.authoritativeSource(restore: restore)
        let source = try TreeCopySession.snapshot(at: authority)
        let task = Task {
            try await fixture.perform(restore: restore) { progress in
                if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        let pending = try #require(try fixture.store.transfers().first)
        writer.rejectNextEmptyTransfers()
        await #expect(throws: (any Error).self) {
            if fixture.mount { try await fixture.mountMover().cancelPreparation(operationID: pending.operationID) }
            else { try await fixture.dataMover().cancelPreparation(operationID: pending.operationID) }
        }
        #expect(try fixture.store.transfer(operationID: pending.operationID)?.preparationRemovalParentIdentity != nil)
        let deletions = fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if fixture.mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
        else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID) }
        #expect(try cold.transfers().isEmpty)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == deletions)
        #expect(try TreeCopySession.snapshot(at: authority) == source)
    }

    @Test("An inspected restore source with no created candidate can cancel or retry", arguments: [false, true])
    func sourceInspectedWithoutCandidate(restart: Bool) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: true, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        writer.rejectNext(field: "sourceBaseline")
        await #expect(throws: (any Error).self) { try await fixture.perform(restore: true, progress: nil) }
        let pending = try #require(try fixture.store.transfers().first)
        #expect(pending.sourceIdentity.isResolved)
        #expect(pending.sourceBaseline == nil)
        #expect(pending.destinationIdentity == nil)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if restart { #expect(try await fixture.mountMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil) }
        else { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
        #expect(try cold.transfers().isEmpty)
        #expect(try String(contentsOf: fixture.local.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
    }

    @Test("Cancelled restore directories keep their intent until their recorded parent is synchronized",
          arguments: [false, true], ["unchanged", "before-sync", "during-sync"])
    func removedRestoreDirectoryKeepsParentBarrier(mount: Bool, replacement: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: mount, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let parent = mount ? fixture.root.appendingPathComponent("mounts") : fixture.home
        let failures = SyncProbe()
        let failSync: @Sendable (URL, Bool) throws -> Void = { directory, alias in
            if directory.path == parent.path {
                failures.record(directory)
                throw POSIXError(.EIO)
            }
            try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
        }
        let sourceSnapshot: TreeCopySnapshot
        if mount {
            let record = try #require(try fixture.store.recordsStrict().first)
            try await fixture.mountMover().unmount(record: record)
            writer.rejectNext(field: "sourceBaseline")
            await #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try await fixture.perform(restore: true, progress: nil) }
            let inspected = try #require(try fixture.store.transfers().first)
            let recovery = URL(fileURLWithPath: try #require(inspected.backupPath))
            #expect(fixture.runner.isMounted(recovery))
            #expect(inspected.sourceIdentity.isResolved)
            #expect(inspected.sourceBaseline == nil)
            #expect(inspected.destinationIdentity == nil)
            #expect(inspected.recoveryMountPointIdentity != nil)
            #expect(!FileManager.default.fileExists(atPath: try #require(inspected.stagingPath)))
            sourceSnapshot = try TreeCopySession.snapshot(at: recovery)
            await #expect(throws: POSIXError(.EIO)) {
                try await fixture.cancelRestore(inspected.operationID, synchronizeDirectory: failSync)
            }
        } else {
            sourceSnapshot = try TreeCopySession.snapshot(at: fixture.external.appendingPathComponent("Payload"))
            // The stage claim is durable before the source baseline save fails.
            // No data candidate exists, so automatic cancellation owns this empty stage.
            writer.rejectNext(field: "sourceBaseline")
            let mover = fixture.dataMover(synchronizeDirectory: { directory, alias in
                if directory.path == parent.path {
                    let hasStage = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                        .contains { $0.hasPrefix(".appports-restore-") }
                    if !hasStage { try failSync(directory, alias); return }
                }
                try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
            })
            do {
                _ = try await mover.restore(item: fixture.item, progressHandler: nil)
                Issue.record("Expected the source baseline save to fail before copying")
            } catch DataDirError.copyFailed(let underlying) {
                let failure = underlying as NSError
                #expect(failure.domain == NSCocoaErrorDomain)
                #expect(failure.code == CocoaError.fileWriteOutOfSpace.rawValue)
            } catch {
                Issue.record("Unexpected source baseline save error: \(error)")
            }
        }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        let removed = URL(fileURLWithPath: try #require(mount ? pending.backupPath : pending.stagingPath))
        let parentIdentity = try #require(pending.stagingParentIdentity)
        let entryIdentity = try DataPathIdentity.capture(fixture.local)
        let entryMode = try fixture.permissions(at: fixture.local)
        if mount { #expect(entryMode == 0) }
        else { #expect(pending.stagingIdentity != nil) }
        #expect(try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity))
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(failures.paths == [parent.path])
        let source: URL
        if mount {
            let uuid = try #require(pending.sourceIdentity.volumeUUID)
            source = try #require(fixture.runner.detachedContents(for: uuid))
        } else { source = fixture.external.appendingPathComponent("Payload") }
        #expect(try TreeCopySession.snapshot(at: source) == sourceSnapshot)
        let ledger = try Data(contentsOf: fixture.ledger)
        let mounts = fixture.runner.commands(prefix: ["mount"])
        let unmounts = fixture.runner.commands(prefix: ["unmount"])
        await #expect(throws: POSIXError(.EIO)) {
            try await fixture.cancelRestore(pending.operationID, store: cold, synchronizeDirectory: failSync)
        }
        #expect(failures.paths == [parent.path, parent.path])
        #expect(try Data(contentsOf: fixture.ledger) == ledger)
        #expect(try cold.transfer(operationID: pending.operationID) == pending)

        if replacement != "unchanged" {
            let savedParent = fixture.root.appendingPathComponent("saved-cancellation-parent")
            if replacement == "before-sync" { try fixture.replaceCancellationParent(parent, savingTo: savedParent) }
            let attempted = SyncProbe()
            await #expect(throws: DataOperationSafety.Failure.self) {
                try await fixture.cancelRestore(pending.operationID,
                    store: ContainerMountStore(fileURL: fixture.ledger), synchronizeDirectory: { directory, alias in
                        attempted.record(directory)
                        try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
                        if replacement == "during-sync" {
                            try fixture.replaceCancellationParent(parent, savingTo: savedParent)
                        }
                    })
            }
            #expect(attempted.paths == (replacement == "before-sync" ? [] : [parent.path]))
            #expect(try DataPathIdentity.capture(savedParent).matchesFilesystemObject(parentIdentity))
            #expect(try !DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity))
            #expect(try Data(contentsOf: fixture.ledger) == ledger)
            try fixture.restoreCancellationParent(parent, from: savedParent)
        }

        let completed = ContainerMountStore(fileURL: fixture.ledger)
        let synchronized = SyncProbe()
        try await fixture.cancelRestore(pending.operationID, store: completed, synchronizeDirectory: { directory, alias in
            synchronized.record(directory)
            try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
        })
        #expect(synchronized.paths == [parent.path])
        #expect(try completed.transfers().isEmpty)
        #expect(try completed.preservedMaterials().isEmpty)
        #expect(try TreeCopySession.snapshot(at: source) == sourceSnapshot)
        #expect(try DataPathIdentity.capture(fixture.local) == entryIdentity)
        #expect(try fixture.permissions(at: fixture.local) == entryMode)
        #expect(fixture.runner.commands(prefix: ["mount"]) == mounts)
        #expect(fixture.runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        if mount { #expect(try completed.recordsStrict().count == 1) }
        else { #expect(try completed.managedLinks().count == 1) }
    }

    @Test("A restore intent saved before directory creation can still cancel",
          arguments: ["symlink", "legacy-symlink", "mount-online", "mount-offline"])
    func uncreatedRestoreDirectoryCanCancel(scenario: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: scenario.hasPrefix("mount"), writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        if scenario == "mount-offline" {
            try await fixture.mountMover().unmount(record: try #require(try fixture.store.recordsStrict().first))
        }
        writer.failAfterNextRestoreIntent()
        await #expect(throws: POSIXError(.EIO)) { try await fixture.perform(restore: true, progress: nil) }
        if scenario == "legacy-symlink" { try fixture.removeRecordedField("stagingParentIdentity") }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        #expect(pending.sourceBaseline == nil)
        #expect(pending.destinationIdentity == nil)
        #expect(pending.stagingIdentity == nil)
        #expect(pending.recoveryMountPointIdentity == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(pending.stagingPath)))
        if fixture.mount { #expect(!FileManager.default.fileExists(atPath: try #require(pending.backupPath))) }
        let source: URL
        if scenario == "mount-offline" {
            let uuid = try #require(pending.sourceIdentity.volumeUUID)
            source = try #require(fixture.runner.detachedContents(for: uuid))
        } else { source = fixture.authoritativeSource(restore: true) }
        let snapshot = try TreeCopySession.snapshot(at: source)
        let entryIdentity = try DataPathIdentity.capture(fixture.local)
        let entryMode = try fixture.permissions(at: fixture.local)
        if scenario == "mount-offline" { #expect(entryMode == 0) }
        let mounts = fixture.runner.commands(prefix: ["mount"])
        let unmounts = fixture.runner.commands(prefix: ["unmount"])
        let synchronized = SyncProbe()
        try await fixture.cancelRestore(pending.operationID, store: cold, synchronizeDirectory: { directory, alias in
            synchronized.record(directory)
            try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
        })
        #expect(synchronized.paths == (scenario == "symlink" ? [fixture.home.path] : []))
        #expect(try cold.transfers().isEmpty)
        #expect(try TreeCopySession.snapshot(at: source) == snapshot)
        #expect(try DataPathIdentity.capture(fixture.local) == entryIdentity)
        #expect(try fixture.permissions(at: fixture.local) == entryMode)
        #expect(fixture.runner.commands(prefix: ["mount"]) == mounts)
        #expect(fixture.runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("An unclaimed symlink restore stage is preserved even when empty", arguments: [false, true])
    func unclaimedSymlinkRestoreStageIsPreserved(hasPayload: Bool) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: false, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let source = fixture.external.appendingPathComponent("Payload")
        let sourceSnapshot = try TreeCopySession.snapshot(at: source)
        let entryIdentity = try DataPathIdentity.capture(fixture.local)
        writer.rejectNext(field: "stagingIdentity")
        await #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try await fixture.perform(restore: true, progress: nil) }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        #expect(pending.stagingParentIdentity != nil)
        #expect(pending.stagingIdentity == nil)
        #expect(pending.sourceBaseline == nil)
        #expect(pending.destinationIdentity == nil)
        let staging = URL(fileURLWithPath: try #require(pending.stagingPath))
        #expect(FileManager.default.fileExists(atPath: staging.path))
        if hasPayload { try Data("unclaimed payload".utf8).write(to: staging.appendingPathComponent("new.txt")) }
        let stagedSnapshot = try TreeCopySession.snapshot(at: staging)
        let ledger = try Data(contentsOf: fixture.ledger)
        do {
            try await fixture.dataMover(store: cold).cancelUnstartedRestore(operationID: pending.operationID)
            Issue.record("Expected cancellation to require the durable stage claim")
        } catch let failure as DataOperationSafety.Failure {
            if case .inspection(let path) = failure { #expect(path == staging.path) }
            else { Issue.record("Unexpected unclaimed stage failure: \(failure)") }
        } catch { Issue.record("Unexpected unclaimed stage cancellation error: \(error)") }
        #expect(try Data(contentsOf: fixture.ledger) == ledger)
        #expect(try TreeCopySession.snapshot(at: staging) == stagedSnapshot)
        try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID, preserveUnclaimedMaterials: true)
        #expect(try cold.transfers().isEmpty)
        let material = try #require(try cold.preservedMaterials().first)
        #expect(material.id == pending.operationID)
        #expect(material.paths.contains(staging.path))
        #expect(try TreeCopySession.snapshot(at: staging) == stagedSnapshot)
        #expect(try TreeCopySession.snapshot(at: source) == sourceSnapshot)
        #expect(try DataPathIdentity.capture(fixture.local) == entryIdentity)
        #expect(try cold.managedLinks().count == 1)
    }

    @Test("A private restore mount is not unmounted without its claim or matching volume",
          arguments: ["missing-claim", "foreign-volume"])
    func privateRestoreCancellationKeepsUnknownMount(conflict: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: true, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let record = try #require(try fixture.store.recordsStrict().first)
        try await fixture.mountMover().unmount(record: record)
        writer.rejectNext(field: "sourceBaseline")
        await #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try await fixture.perform(restore: true, progress: nil) }
        if conflict == "missing-claim" { try fixture.removeRecordedField("recoveryMountPointIdentity") }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        let recovery = URL(fileURLWithPath: try #require(pending.backupPath))
        let snapshot = try TreeCopySession.snapshot(at: recovery)
        let ledger = try Data(contentsOf: fixture.ledger)
        let unmounts = fixture.runner.commands(prefix: ["unmount"])
        let runner = fixture.runner
        let mover = fixture.mountMover(store: cold, mountedVolumeUUID: { path in
            if conflict == "foreign-volume", path.path == recovery.path { return "FOREIGN-VOLUME" }
            return runner.mountedUUID(at: path)
        })
        do {
            try await mover.cancelPreparation(operationID: pending.operationID)
            Issue.record("Expected the private mount claim or volume identity to reject cancellation")
        } catch let failure as DataOperationSafety.Failure {
            #expect(conflict == "missing-claim")
            if case .inspection(let path) = failure { #expect(path == recovery.path) }
            else { Issue.record("Unexpected safety failure: \(failure)") }
        } catch let failure as ContainerVolumeMigrator.MigrationError {
            #expect(conflict == "foreign-volume")
            if case .unexpectedMountedVolume(let path) = failure { #expect(path.path == recovery.path) }
            else { Issue.record("Unexpected volume failure: \(failure)") }
        } catch { Issue.record("Unexpected private mount cancellation error: \(error)") }
        #expect(fixture.runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(fixture.runner.isMounted(recovery))
        #expect(try TreeCopySession.snapshot(at: recovery) == snapshot)
        #expect(try Data(contentsOf: fixture.ledger) == ledger)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("Guarded restore placeholders still reject data, replacement, and changed permissions",
          arguments: ["nonempty", "replaced", "mode-change"])
    func guardedRestorePlaceholderConflictsKeepIntent(conflict: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: true, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let record = try #require(try fixture.store.recordsStrict().first)
        try await fixture.mountMover().unmount(record: record)
        writer.failAfterNextRestoreIntent()
        await #expect(throws: POSIXError(.EIO)) { try await fixture.perform(restore: true, progress: nil) }
        #expect(try fixture.permissions(at: fixture.local) == 0)
        if conflict == "nonempty" {
            // Model a new local write, then restore the actual guarded state
            // before calling cancellation. A locked directory is not proof of emptiness.
            try #require(chmod(fixture.local.path, 0o700) == 0)
            try Data("new local data".utf8).write(to: fixture.local.appendingPathComponent("new.txt"))
            try #require(chmod(fixture.local.path, 0) == 0)
        }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        let uuid = try #require(pending.sourceIdentity.volumeUUID)
        let source = try #require(fixture.runner.detachedContents(for: uuid))
        let snapshot = try TreeCopySession.snapshot(at: source)
        let entryIdentity = try DataPathIdentity.capture(fixture.local)
        let ledger = try Data(contentsOf: fixture.ledger)
        let unmounts = fixture.runner.commands(prefix: ["unmount"])
        let saved = fixture.local.deletingLastPathComponent().appendingPathComponent("saved-local-placeholder")
        let synchronized = SyncProbe()
        let runner = fixture.runner
        let mover = fixture.mountMover(store: cold, makeMountPointLease: { path, protection in
            let lease = try runner.makeMountPointLease(at: path, protection: protection)
            if path.path == fixture.local.path {
                if conflict == "replaced" {
                    // Keep the same parent: macOS needs access to update a
                    // guarded directory's parent when moving it elsewhere.
                    // This rename actually replaces the entry without opening it.
                    try #require(rename(path.path, saved.path) == 0)
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                    try Data("replacement data".utf8).write(to: path.appendingPathComponent("new.txt"))
                    guard chmod(path.path, 0) == 0 else { throw POSIXError(.EACCES) }
                } else if conflict == "mode-change" {
                    guard chmod(path.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
                }
            }
            return lease
        }, synchronizeCleanupParent: { directory in
            synchronized.record(directory)
            try DurableFileIO.syncDirectory(at: directory)
        })
        do {
            try await mover.cancelPreparation(operationID: pending.operationID)
            Issue.record("Expected the changed guarded placeholder to reject cancellation")
        } catch let failure as MountPointLease.Failure {
            switch failure {
            case .notEmpty: #expect(conflict == "nonempty")
            case .replaced: #expect(conflict == "replaced" || conflict == "mode-change")
            case .notDirectory: Issue.record("A real directory was unexpectedly rejected as not a directory")
            }
        } catch { Issue.record("Unexpected guarded placeholder error: \(error)") }
        #expect(synchronized.paths.isEmpty)
        #expect(try Data(contentsOf: fixture.ledger) == ledger)
        #expect(try TreeCopySession.snapshot(at: source) == snapshot)
        #expect(try DataPathIdentity.capture(conflict == "replaced" ? saved : fixture.local) == entryIdentity)
        #expect(try fixture.permissions(at: fixture.local) == (conflict == "mode-change" ? 0o700 : 0))
        #expect(fixture.runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        if conflict != "mode-change" {
            // Read the preserved payload only after proving cancellation kept
            // the placeholder locked and its intent unchanged.
            try #require(chmod(fixture.local.path, 0o700) == 0)
            #expect(try String(contentsOf: fixture.local.appendingPathComponent("new.txt"), encoding: .utf8)
                == (conflict == "nonempty" ? "new local data" : "replacement data"))
        }
    }

    @Test("Normalization uses the same partial cancellation and operation-preserving restart", arguments: [false, true])
    func normalizationPartial(restart: Bool) async throws {
        let fixture = try Fixture(mount: false)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let source = fixture.external.appendingPathComponent("Payload")
        let destination = fixture.external.appendingPathComponent("Normalized")
        let original = try TreeCopySession.snapshot(at: source)
        let task = Task {
            try await fixture.dataMover().normalizeManagedLinkAndComplete(localPath: fixture.local,
                currentExternalPath: source, normalizedExternalPath: destination) { progress in
                if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        let pending = try #require(try fixture.store.transfers().first)
        #expect(pending.sourceBaseline != nil)
        #expect(pending.stagingIdentity != nil)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if restart {
            #expect(try await fixture.dataMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
            #expect(try cold.managedLink(forOriginalPath: fixture.local.path)?.operationID == pending.operationID)
            #expect(try String(contentsOf: destination.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
        } else {
            try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID)
            #expect(try TreeCopySession.snapshot(at: source) == original)
        }
        #expect(try cold.transfers().isEmpty)
    }

    private final class FinalDeviceQueryRunner: ShellCommandRunning, @unchecked Sendable {
        let base: FakeDiskCommandRunner
        let mutation: @Sendable () throws -> Void
        private let lock = NSLock()
        private var performed = false
        init(base: FakeDiskCommandRunner, mutation: @escaping @Sendable () throws -> Void) {
            self.base = base
            self.mutation = mutation
        }
        private func claim(_ arguments: [String]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !performed, arguments == ["info", "-plist", "disk7s9"] else { return false }
            performed = true
            return true
        }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            if claim(arguments) { try mutation() }
            return try await base.run(executable: executable, arguments: arguments, timeout: timeout)
        }
    }

    private final class FaultWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var field: String?
        private var rejectEmpty = false
        private var stopAfterRestoreIntent = false
        private var persistent = false
        private var rejectActivation = false
        func rejectAlways(field: String) { lock.lock(); self.field = field; persistent = true; lock.unlock() }
        func rejectEmptyUntilCleared() { lock.lock(); rejectEmpty = true; persistent = true; lock.unlock() }
        func rejectActivationAttempt() { lock.lock(); rejectActivation = true; lock.unlock() }
        func clearFault() { lock.lock(); field = nil; rejectEmpty = false; persistent = false; rejectActivation = false; lock.unlock() }
        func rejectNext(field: String) { lock.lock(); self.field = field; lock.unlock() }
        func rejectNextEmptyTransfers() { lock.lock(); rejectEmpty = true; lock.unlock() }
        func failAfterNextRestoreIntent() { lock.lock(); stopAfterRestoreIntent = true; lock.unlock() }
        func write(_ bytes: Data, to url: URL) throws {
            lock.lock()
            let document = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
            let transfers = document?["transfers"] as? [[String: Any]] ?? []
            let reject = field.map { key in transfers.contains { $0[key] != nil } } == true || rejectEmpty && transfers.isEmpty
                || rejectActivation && transfers.contains { $0["candidateActivationAttempted"] as? Bool == true }
            let stopAfterWrite = stopAfterRestoreIntent && transfers.contains {
                $0["direction"] as? String == "restore" && $0["phase"] as? String == "preparing"
            }
            if reject && !persistent { field = nil; rejectEmpty = false; rejectActivation = false }
            if stopAfterWrite { stopAfterRestoreIntent = false }
            lock.unlock()
            if reject { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileIO.write(bytes, to: url)
            if stopAfterWrite { throw POSIXError(.EIO) }
        }
    }

    private final class SyncProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return values }
        func record(_ directory: URL) { lock.lock(); values.append(directory.path); lock.unlock() }
    }

    private struct Fixture: Sendable {
        let root: URL
        let home: URL
        let local: URL
        let external: URL
        let ledger: URL
        let mount: Bool
        let store: ContainerMountStore
        let runner: FakeDiskCommandRunner

        init(mount: Bool, writer: FaultWriter = FaultWriter()) throws {
            self.mount = mount
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsPreparation-\(UUID())").resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            local = home.appendingPathComponent(mount ? "Library/Containers/org.example.fixture/Data/Documents/Payload" : "Payload")
            external = root.appendingPathComponent("External")
            ledger = root.appendingPathComponent("records.plist")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            try Data("first".utf8).write(to: local.appendingPathComponent("a.txt"))
            try Data("second".utf8).write(to: local.appendingPathComponent("b.txt"))
            store = ContainerMountStore(fileURL: ledger, writeData: { try writer.write($0, to: $1) })
            runner = FakeDiskCommandRunner(createdVolumeUUID: try DataPathIdentity.capture(local).volumeUUID)
        }

        var item: DataDirItem { .init(name: "Payload", path: local, type: mount ? .containers : .custom, priority: .recommended, description: "") }
        func dataMover(store: ContainerMountStore? = nil,
                       synchronizeDirectory: @escaping @Sendable (URL, Bool) throws -> Void = {
                           try DurableFileIO.syncDirectory(at: $0, resolvingAlias: $1)
                       }) -> DataDirMover {
            DataDirMover(homeDir: home, store: store ?? self.store, runner: SyntheticNoWritersRunner(),
                         synchronizeDirectory: synchronizeDirectory)
        }
        func mountMover(store: ContainerMountStore? = nil,
                        runnerOverride: FakeDiskCommandRunner? = nil,
                        diskRunner: (any ShellCommandRunning)? = nil,
                        mountFlags: @escaping @Sendable (URL) -> UInt32? = { _ in UInt32(MNT_DONTBROWSE) },
                        mountedVolumeUUID: (@Sendable (URL) -> String?)? = nil,
                        makeMountPointLease: (@Sendable (URL, MountPointLease.Protection) throws -> any MountPointLeasing)? = nil,
                        safetyRunner: any ShellCommandRunning = SyntheticNoWritersRunner(),
                        synchronizeCleanupParent: @escaping @Sendable (URL) throws -> Void = {
                            try DurableFileIO.syncDirectory(at: $0)
                        }) -> ContainerVolumeMigrator {
            let runner = runnerOverride ?? runner
            let external = external
            return ContainerVolumeMigrator(disk: DiskUtility(runner: diskRunner ?? runner, commandTimeout: 5), store: store ?? self.store,
                stagingMountRootURL: root.appendingPathComponent("mounts"),
                automaticMountRootURL: root.appendingPathComponent("Volumes"), isMountPoint: { runner.isMounted($0) },
                mountedVolumePath: { $0.path.hasPrefix(external.path) ? "/SyntheticExternal" : "/" },
                mountedVolumeUUID: mountedVolumeUUID ?? { runner.mountedUUID(at: $0) },
                synchronizeAgent: { _ in }, availableCapacity: { _ in nil }, mountFlags: mountFlags,
                homeDirectory: home, safetyRunner: safetyRunner,
                makeMountPointLease: makeMountPointLease ?? { try runner.makeMountPointLease(at: $0, protection: $1) },
                synchronizeCleanupParent: synchronizeCleanupParent)
        }
        func permissions(at path: URL) throws -> mode_t {
            var info = stat()
            guard lstat(path.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return info.st_mode & 0o7777
        }
        func cancelRestore(_ operationID: UUID, store: ContainerMountStore? = nil,
                           synchronizeDirectory: @escaping @Sendable (URL, Bool) throws -> Void) async throws {
            if mount {
                try await mountMover(store: store, synchronizeCleanupParent: { try synchronizeDirectory($0, false) })
                    .cancelPreparation(operationID: operationID)
            } else {
                try await dataMover(store: store, synchronizeDirectory: synchronizeDirectory)
                    .cancelUnstartedRestore(operationID: operationID)
            }
        }
        func replaceCancellationParent(_ parent: URL, savingTo saved: URL) throws {
            try FileManager.default.moveItem(at: parent, to: saved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            // Keep the original link and source valid so only parent ownership
            // distinguishes this replacement from a legitimate cold retry.
            if !mount { try FileManager.default.moveItem(at: saved.appendingPathComponent(local.lastPathComponent), to: local) }
        }
        func restoreCancellationParent(_ parent: URL, from saved: URL) throws {
            if !mount { try FileManager.default.moveItem(at: local, to: saved.appendingPathComponent(local.lastPathComponent)) }
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.moveItem(at: saved, to: parent)
        }
        func interruptMigration() async throws -> DataTransferRecord {
            let task = Task {
                try await perform(restore: false) { progress in
                    if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            await #expect(throws: (any Error).self) { try await task.value }
            return try #require(try store.transfers().first)
        }
        func automountCandidate(_ transfer: DataTransferRecord, name: String? = nil) async throws -> URL {
            let uuid = try #require(transfer.createdVolumeUUID)
            let staging = try #require(transfer.stagingPath)
            let volumeName = try #require(transfer.volumeCreationName)
            let automatic = root.appendingPathComponent("Volumes").appendingPathComponent(name ?? volumeName)
            try FileManager.default.createDirectory(at: automatic, withIntermediateDirectories: true)
            let unmount = try await runner.run(executable: "/synthetic/diskutil", arguments: ["unmount", staging], timeout: 5)
            #expect(unmount.status == 0)
            let mount = try await runner.run(executable: "/synthetic/diskutil", arguments: ["mount", "nobrowse", "-mountPoint", automatic.path, uuid], timeout: 5)
            #expect(mount.status == 0)
            return automatic
        }
        func rewriteJournal(_ change: (inout [String: Any], inout [[String: Any]]) throws -> Void) throws {
            var document = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: ledger), format: nil) as? [String: Any])
            var transfers = try #require(document["transfers"] as? [[String: Any]])
            try change(&document, &transfers)
            document["transfers"] = transfers
            try DurableFileIO.write(PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0), to: ledger)
        }
        func removeRecordedField(_ field: String) throws {
            var document = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: ledger), format: nil) as? [String: Any])
            var transfers = try #require(document["transfers"] as? [[String: Any]])
            #expect(transfers.count == 1)
            transfers[0].removeValue(forKey: field)
            document["transfers"] = transfers
            try DurableFileIO.write(PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0), to: ledger)
        }
        func migrateFirst() async throws {
            if mount { _ = try await mountMover().migrateAndComplete(item: item, externalRootURL: external, appName: "Fixture", bundleIdentifier: nil, progressHandler: nil) }
            else { _ = try await dataMover().migrateAndComplete(item: item, to: external, progressHandler: nil) }
        }
        func perform(restore: Bool, progress: FileCopier.ProgressHandler?) async throws {
            if mount {
                if restore {
                    let record = try #require(try store.recordsStrict().first)
                    _ = try await mountMover().restore(record: record, estimatedTotalBytes: 0, progressHandler: progress)
                } else { _ = try await mountMover().migrate(item: item, externalRootURL: external, appName: "Fixture", bundleIdentifier: nil, progressHandler: progress) }
            } else {
                if restore { try await dataMover().restore(item: item, progressHandler: progress) }
                else { try await dataMover().migrate(item: item, to: external, progressHandler: progress) }
            }
        }
        func authoritativeSource(restore: Bool) -> URL { restore && !mount ? external.appendingPathComponent("Payload") : local }
        func remove() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/chmod")
            task.arguments = ["-R", "u+rwx", root.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            if (try? task.run()) != nil { task.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
