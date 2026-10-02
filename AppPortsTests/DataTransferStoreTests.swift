import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DataTransferStoreTests {
    @Test("A different volume cannot silently replace the same recorded source")
    func rejectsConflictingMountIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.mount("A", volume: "VOLUME-A")
        try fixture.store.upsert(first)
        let before = try Data(contentsOf: fixture.file)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try fixture.store.upsert(fixture.mount("A", volume: "VOLUME-B"))
        }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("A retained baseline survives reopen and never schedules deletion itself")
    func retainedBaselineSurvivesReopen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = fixture.transfer()
        try fixture.store.beginTransfer(transfer)
        try fixture.store.beginTransfer(transfer)
        #expect(try fixture.store.transfers().count == 1)
        transfer.phase = .copying
        try fixture.store.updateTransfer(transfer)
        transfer.phase = .verified
        transfer.baseline = Data("verified-source-v1".utf8)
        try fixture.store.updateTransfer(transfer)
        transfer.phase = .switching
        try fixture.store.updateTransfer(transfer)
        try fixture.store.finalizeTransfer(operationID: transfer.operationID, baseline: Data("verified-source-v1".utf8))
        let reopened = ContainerMountStore(fileURL: fixture.file)
        let retained = try #require(try reopened.transfers().first)
        #expect(retained.phase == .awaitingUserVerification)
        #expect(retained.baseline == Data("verified-source-v1".utf8))
        #expect(try reopened.unfinishedTransfers().map(\.operationID) == [transfer.operationID])
        #expect(throws: ContainerMountStore.StoreError.self) {
            try reopened.finishTransfer(operationID: transfer.operationID, deletionConfirmed: true)
        }
        try reopened.requestCleanup(operationID: transfer.operationID)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try reopened.finishTransfer(operationID: transfer.operationID, deletionConfirmed: false)
        }
        #expect(try reopened.transfers().count == 1)
        try reopened.finishTransfer(operationID: transfer.operationID, deletionConfirmed: true)
        #expect(try reopened.transfers().isEmpty)
    }

    @Test("Invalid or future state fails closed and does not change existing bytes", arguments: ["corrupt", "future", "phase", "missingBaseline"])
    func invalidStatePreservesBytes(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes: Data
        if kind == "corrupt" { bytes = Data("broken".utf8) }
        else {
            var object: [String: Any] = ["schemaVersion": 3, "mounts": [], "cleanups": [], "transfers": []]
            if kind == "future" { object["schemaVersion"] = 91 }
            if kind == "phase" || kind == "missingBaseline" {
                let encoded = try PropertyListEncoder().encode(fixture.transfer())
                var record = try #require(try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
                record["phase"] = kind == "phase" ? "deleteEverything" : "awaitingUserVerification"
                object["transfers"] = [record]
            }
            bytes = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        }
        try bytes.write(to: fixture.file)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.recordsStrict() }
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.beginTransfer(fixture.transfer()) }
        #expect(try Data(contentsOf: fixture.file) == bytes)
    }

    @Test("Legacy schemas are read without writes and failed upgrades preserve bytes", arguments: [1, 2])
    func legacyUpgradeIsAtomic(schema: Int) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mount = fixture.mount("Legacy")
        let cleanup = ContainerCleanupRecord(kind: .migrationBackup, mountRecord: mount, localPath: fixture.root.appendingPathComponent("old-backup").path)
        let bytes: Data
        if schema == 1 { bytes = try PropertyListEncoder().encode([mount]) }
        else { bytes = try PropertyListEncoder().encode(LegacyDocument(schemaVersion: 2, mounts: [mount], cleanups: [cleanup])) }
        try bytes.write(to: fixture.file)
        #expect(try fixture.store.recordsStrict() == [mount])
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try Data(contentsOf: fixture.file) == bytes)
        let rejecting = ContainerMountStore(fileURL: fixture.file, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: (any Error).self) { try rejecting.beginTransfer(fixture.transfer()) }
        #expect(try Data(contentsOf: fixture.file) == bytes)
        try fixture.store.beginTransfer(fixture.transfer())
        let reopened = ContainerMountStore(fileURL: fixture.file)
        #expect(try reopened.recordsStrict() == [mount])
        #expect(try reopened.pendingCleanups() == (schema == 2 ? [cleanup] : []))
        #expect(try reopened.transfers().count == 1)
    }

    @Test("An active mount and retention become visible atomically")
    func atomicMountRetention() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = fixture.transfer(mode: .mount)
        try fixture.store.beginTransfer(transfer)
        transfer.phase = .copying
        transfer.createdVolumeUUID = "CREATED-VOLUME"
        try fixture.store.updateTransfer(transfer)
        transfer.phase = .verified
        transfer.baseline = Data("baseline".utf8)
        try fixture.store.updateTransfer(transfer)
        transfer.phase = .switching
        try fixture.store.updateTransfer(transfer)
        let mount = fixture.mount("A", volume: "CREATED-VOLUME")
        let before = try Data(contentsOf: fixture.file)
        let rejecting = ContainerMountStore(fileURL: fixture.file, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: (any Error).self) { try rejecting.commitMigration(record: mount, transfer: transfer) }
        #expect(try Data(contentsOf: fixture.file) == before)
        try fixture.store.commitMigration(record: mount, transfer: transfer)
        #expect(try fixture.store.recordsStrict() == [mount])
        #expect(try fixture.store.transfers().first?.phase == .awaitingUserVerification)
        try fixture.store.commitMigration(record: mount, transfer: transfer)
        #expect(try fixture.store.recordsStrict().count == 1)
        #expect(try fixture.store.transfers().count == 1)
    }

    @Test("Another transaction cannot overlap a retained path")
    func rejectsRetainedPathConflict() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var first = fixture.transfer()
        try fixture.store.beginTransfer(first)
        first.phase = .needsRecovery
        first.recoverableReason = "Interrupted before copy"
        try fixture.store.updateTransfer(first)
        var second = fixture.transfer()
        second.originalPath = first.backupPath! + "/child"
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.beginTransfer(second) }
        #expect(try fixture.store.transfers().count == 1)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try fixture.store.upsert(fixture.mount("A/child"))
        }
    }

    @Test("Concurrent instances preserve independent records")
    func concurrentTransactionsDoNotLoseRecords() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let errors = LockedErrors()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            let store = ContainerMountStore(fileURL: fixture.file)
            do { try store.upsert(fixture.mount("item-\(index)", volume: "volume-\(index)")) }
            catch { errors.append(error) }
        }
        #expect(errors.count == 0)
        #expect(try fixture.store.recordsStrict().count == 24)
    }

    @Test("Restore preserves both the earlier original and the newly retained source")
    func restoreWithEarlierRetainedOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var migration = fixture.transfer(mode: .mount)
        migration.createdVolumeUUID = "CREATED-VOLUME"
        migration.destinationIdentity = DataPathIdentity(device: 2, inode: 500, volumeUUID: "CREATED-VOLUME")
        try fixture.store.beginTransfer(migration)
        migration.phase = .copying
        try fixture.store.updateTransfer(migration)
        migration.phase = .verified
        migration.baseline = Data("migration-baseline".utf8)
        try fixture.store.updateTransfer(migration)
        migration.phase = .switching
        try fixture.store.updateTransfer(migration)
        let mount = fixture.mount("A", volume: "CREATED-VOLUME")
        try fixture.store.commitMigration(record: mount, transfer: migration)
        var restore = DataTransferRecord(mode: .mount, direction: .restore, appName: "Fixture", dataDirType: "fixture",
            originalPath: migration.originalPath, activePath: migration.originalPath,
            destinationPath: fixture.root.appendingPathComponent("restore-staging").path,
            backupPath: migration.destinationPath,
            sourceIdentity: try #require(migration.destinationIdentity), priorOperationID: migration.operationID)
        try fixture.store.beginTransfer(restore)
        restore.phase = .copying
        try fixture.store.updateTransfer(restore)
        restore.phase = .verified
        restore.baseline = Data("restore-baseline".utf8)
        restore.destinationIdentity = DataPathIdentity(device: 1, inode: 900)
        try fixture.store.updateTransfer(restore)
        let before = try Data(contentsOf: fixture.file)
        let rejecting = ContainerMountStore(fileURL: fixture.file, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: (any Error).self) { try rejecting.beginRestore(transfer: restore, removingMount: mount) }
        #expect(try Data(contentsOf: fixture.file) == before)
        try fixture.store.beginRestore(transfer: restore, removingMount: mount)
        #expect(try fixture.store.recordsStrict().isEmpty)
        #expect(try fixture.store.transfer(operationID: restore.operationID)?.phase == .switching)
        try fixture.store.finalizeTransfer(operationID: restore.operationID, baseline: Data("restore-baseline".utf8))
        let reopened = ContainerMountStore(fileURL: fixture.file)
        #expect(try reopened.transfers().count == 2)
        #expect(try reopened.transfer(operationID: migration.operationID)?.backupPath == fixture.root.appendingPathComponent("A.backup").path)
        #expect(try reopened.transfer(operationID: restore.operationID)?.backupPath == fixture.root.appendingPathComponent("external/A").path)
        #expect(try reopened.transfers().allSatisfy { $0.phase == .awaitingUserVerification })
    }

    @Test("A retained path cannot be rewritten to erase recovery ownership")
    func retainedPathCannotBeRewritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = fixture.transfer()
        try fixture.store.beginTransfer(transfer)
        transfer.phase = .copying
        try fixture.store.updateTransfer(transfer)
        transfer.phase = .verified
        transfer.baseline = Data("baseline".utf8)
        try fixture.store.updateTransfer(transfer)
        transfer.phase = .switching
        try fixture.store.updateTransfer(transfer)
        try fixture.store.finalizeTransfer(operationID: transfer.operationID, baseline: Data("baseline".utf8))
        var retained = try #require(try fixture.store.transfer(operationID: transfer.operationID))
        retained.backupPath = fixture.root.appendingPathComponent("unrelated").path
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(retained) }
        #expect(try fixture.store.transfer(operationID: transfer.operationID)?.backupPath == fixture.root.appendingPathComponent("A.backup").path)
    }

    @Test("Copied phases require the destination identity as well as a baseline")
    func verifiedPhaseNeedsIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = fixture.transfer()
        transfer.destinationIdentity = nil
        try fixture.store.beginTransfer(transfer)
        transfer.phase = .copying
        try fixture.store.updateTransfer(transfer)
        transfer.phase = .verified
        transfer.baseline = Data("baseline".utf8)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(transfer) }
        #expect(try fixture.store.transfers().first?.phase == .copying)
    }

    @Test("Managed link index survives original cleanup and is removed atomically for restore")
    func managedLinkOutlivesRetention() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var migration = fixture.transfer()
        try fixture.store.beginTransfer(migration)
        migration.phase = .copying
        try fixture.store.updateTransfer(migration)
        migration.phase = .verified
        migration.baseline = Data("baseline".utf8)
        try fixture.store.updateTransfer(migration)
        migration.phase = .switching
        try fixture.store.updateTransfer(migration)
        try fixture.store.commitMigration(record: nil, transfer: migration)
        try fixture.store.requestCleanup(operationID: migration.operationID)
        try fixture.store.finishTransfer(operationID: migration.operationID, deletionConfirmed: true)
        let reopened = ContainerMountStore(fileURL: fixture.file)
        #expect(try reopened.transfers().isEmpty)
        let link = try #require(try reopened.managedLinks().first)
        #expect(link.originalPath == fixture.root.appendingPathComponent("A").path)
        #expect(link.destinationPath == fixture.root.appendingPathComponent("external/A").path)
        #expect(link.operationID == migration.operationID)
        #expect(throws: ContainerMountStore.StoreError.self) { try reopened.beginTransfer(fixture.transfer()) }
        var restore = DataTransferRecord(mode: .symlink, direction: .restore, appName: "Fixture", dataDirType: "fixture",
            originalPath: link.originalPath, activePath: link.originalPath,
            destinationPath: fixture.root.appendingPathComponent("restore-staging").path,
            backupPath: link.destinationPath, sourceIdentity: link.destinationIdentity, priorOperationID: link.operationID)
        try reopened.beginTransfer(restore)
        restore.phase = .copying
        try reopened.updateTransfer(restore)
        restore.phase = .verified
        restore.baseline = Data("restore-baseline".utf8)
        restore.destinationIdentity = DataPathIdentity(device: 1, inode: 200)
        try reopened.updateTransfer(restore)
        let before = try Data(contentsOf: fixture.file)
        let rejecting = ContainerMountStore(fileURL: fixture.file, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: (any Error).self) { try rejecting.beginRestore(transfer: restore, removingMount: nil) }
        #expect(try Data(contentsOf: fixture.file) == before)
        try reopened.beginRestore(transfer: restore, removingMount: nil)
        #expect(try reopened.managedLinks().isEmpty)
        #expect(try reopened.transfers().first?.phase == .switching)
    }

    @Test("Offline restore intent can identify only the volume until its private mount is inspected")
    func offlineVolumeIdentityMustResolveBeforeCopying() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mount = fixture.mount("A", volume: "OFFLINE-VOLUME")
        try fixture.store.upsert(mount)
        var restore = DataTransferRecord(mode: .mount, direction: .restore, appName: "Fixture", dataDirType: "fixture",
            originalPath: mount.mountPointPath, activePath: mount.mountPointPath,
            destinationPath: fixture.root.appendingPathComponent("restore-staging").path,
            sourceIdentity: DataPathIdentity(volumeUUID: "OFFLINE-VOLUME"))
        try fixture.store.beginTransfer(restore)
        #expect(try fixture.store.transfers().first?.sourceIdentity.isResolved == false)
        restore.phase = .copying
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(restore) }
        restore.phase = .preparing
        restore.sourceIdentity = DataPathIdentity(device: 3, inode: 600, volumeUUID: "DIFFERENT-VOLUME")
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(restore) }
        restore.sourceIdentity = DataPathIdentity(device: 3, inode: 600, volumeUUID: "OFFLINE-VOLUME")
        try fixture.store.updateTransfer(restore)
        restore.phase = .copying
        try fixture.store.updateTransfer(restore)
        #expect(try fixture.store.transfers().first?.sourceIdentity.inode == 600)
        restore.sourceIdentity = DataPathIdentity(device: 3, inode: 601, volumeUUID: "OFFLINE-VOLUME")
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(restore) }
    }

    @Test("An unstarted restore retries with its original operation identity and paths")
    func unstartedRestoreResumesSameIntent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mount = fixture.mount("A")
        try fixture.store.upsert(mount)
        var restore = fixture.restore(mount)
        try fixture.store.beginTransfer(restore)
        restore.legacyRootOwnership = .init(uid: geteuid(), gid: getegid())
        restore.legacyMountFlags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_DONTBROWSE | MNT_NODEV)
        try fixture.store.updateTransfer(restore)
        restore.phase = .needsRecovery
        restore.recoverableReason = "Ownership inspection failed before copying"
        try fixture.store.updateTransfer(restore)
        var unsafeGenericUpdate = restore
        unsafeGenericUpdate.phase = .preparing
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(unsafeGenericUpdate) }

        let reopened = ContainerMountStore(fileURL: fixture.file)
        let saved = try #require(try reopened.transfer(operationID: restore.operationID))
        let resumed = try reopened.resumeUnstartedMountRestore(saved, record: mount)
        var expected = saved
        expected.phase = .preparing
        expected.recoverableReason = nil
        #expect(resumed == expected)
        #expect(try reopened.transfers() == [expected])
        #expect(try reopened.recordsStrict() == [mount])
        #expect(try reopened.resumeUnstartedMountRestore(resumed, record: mount) == expected)
        let before = try Data(contentsOf: fixture.file)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try reopened.resumeUnstartedMountRestore(saved, record: mount)
        }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("Copy evidence or a changed restore shape cannot take the unstarted retry route",
          arguments: ["sourceIdentity", "destinationIdentity", "backupIdentity", "baseline", "createdVolume",
                      "activePath", "destinationPath", "missingStaging", "missingBackup", "copying"])
    func startedRestoreCannotResume(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mount = fixture.mount("A")
        try fixture.store.upsert(mount)
        var restore = fixture.restore(mount)
        switch kind {
        case "sourceIdentity", "copying": restore.sourceIdentity = DataPathIdentity(device: 3, inode: 600, volumeUUID: mount.volumeUUID)
        case "destinationIdentity": restore.destinationIdentity = DataPathIdentity(device: 1, inode: 901)
        case "backupIdentity": restore.backupIdentity = DataPathIdentity(device: 3, inode: 600)
        case "baseline": restore.baseline = Data("evidence-copy-started".utf8)
        case "createdVolume": restore.createdVolumeUUID = mount.volumeUUID
        case "activePath": restore.activePath = fixture.root.appendingPathComponent("elsewhere").path
        case "destinationPath": restore.destinationPath = fixture.root.appendingPathComponent("elsewhere").path
        case "missingStaging": restore.stagingPath = nil
        case "missingBackup": restore.backupPath = nil
        default: break
        }
        try fixture.store.beginTransfer(restore)
        restore.phase = kind == "copying" ? .copying : .needsRecovery
        restore.recoverableReason = "Interrupted"
        try fixture.store.updateTransfer(restore)
        let before = try Data(contentsOf: fixture.file)
        #expect(!restore.isUnstartedMountRestore)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try fixture.store.resumeUnstartedMountRestore(restore, record: mount)
        }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("Resume requires the exact current mount and application identity", arguments: ["volume", "app", "bundle", "type", "path"])
    func resumeRejectsDifferentMountRecord(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mount = fixture.mount("A")
        try fixture.store.upsert(mount)
        let restore = fixture.restore(mount)
        try fixture.store.beginTransfer(restore)
        let changed = ContainerMountRecord(appName: kind == "app" ? "Other" : mount.appName,
            bundleIdentifier: kind == "bundle" ? "test.other" : mount.bundleIdentifier,
            dataDirType: kind == "type" ? "other" : mount.dataDirType,
            mountPointPath: kind == "path" ? fixture.root.appendingPathComponent("Other").path : mount.mountPointPath,
            volumeUUID: kind == "volume" ? "OTHER-VOLUME" : mount.volumeUUID,
            volumeName: mount.volumeName, externalRootPath: mount.externalRootPath, createdAt: mount.createdAt)
        let before = try Data(contentsOf: fixture.file)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try fixture.store.resumeUnstartedMountRestore(restore, record: changed)
        }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("Legacy metadata persists separately from actual source ownership and cannot be rewritten", arguments: [false, true])
    func legacyOwnershipBaselineSurvivesReopen(online: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mount = fixture.mount("A")
        try fixture.store.upsert(mount)
        var restore = fixture.restore(mount)
        try fixture.store.beginTransfer(restore)
        let owner = TreeCopySnapshot.Ownership(uid: geteuid(), gid: getegid())
        restore.legacyRootOwnership = owner
        restore.legacyMountFlags = online ? UInt32(MNT_IGNORE_OWNERSHIP | MNT_DONTBROWSE) : nil
        try fixture.store.updateTransfer(restore)
        restore.sourceIdentity = DataPathIdentity(device: 3, inode: 600, volumeUUID: mount.volumeUUID)
        try fixture.store.updateTransfer(restore)
        restore.phase = .copying
        try fixture.store.updateTransfer(restore)
        let baseline = fixture.legacySnapshot(owner: owner)
        restore.baseline = try PropertyListEncoder().encode(baseline)
        restore.destinationIdentity = DataPathIdentity(device: 1, inode: 901)
        restore.backupIdentity = restore.sourceIdentity
        restore.phase = .verified
        try fixture.store.updateTransfer(restore)
        let reopened = ContainerMountStore(fileURL: fixture.file)
        let saved = try #require(try reopened.transfer(operationID: restore.operationID))
        let snapshot = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: #require(saved.baseline))
        #expect(saved == restore)
        #expect(snapshot.entries.first?.uid == 0)
        #expect(snapshot.restoredRootOwnership == owner)
        #expect(snapshot.destinationEntry(try #require(snapshot.entries.first)).uid == owner.uid)
        var changed = saved
        changed.legacyMountFlags = UInt32(MNT_IGNORE_OWNERSHIP)
        #expect(throws: ContainerMountStore.StoreError.self) { try reopened.updateTransfer(changed) }
        changed = saved
        changed.legacyRootOwnership = nil
        #expect(throws: ContainerMountStore.StoreError.self) { try reopened.updateTransfer(changed) }
    }

    @Test("Ownership exceptions cannot be attached after the source has been inspected")
    func legacyOwnershipCannotBeIntroducedLate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mount = fixture.mount("A")
        try fixture.store.upsert(mount)
        var restore = fixture.restore(mount)
        try fixture.store.beginTransfer(restore)
        restore.sourceIdentity = DataPathIdentity(device: 3, inode: 600, volumeUUID: mount.volumeUUID)
        try fixture.store.updateTransfer(restore)
        let before = try Data(contentsOf: fixture.file)
        restore.legacyRootOwnership = .init(uid: geteuid(), gid: getegid())
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(restore) }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("Pre-compatibility transfer and snapshot data decode without ownership exceptions")
    func missingLegacyFieldsRemainBackwardCompatible() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.transfer()
        let encoded = try PropertyListEncoder().encode(original)
        var record = try #require(try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        record.removeValue(forKey: "legacyRootOwnership")
        record.removeValue(forKey: "legacyMountFlags")
        // Binary plist preserves createdAt's subsecond value, matching the production store.
        // XML dates round to whole seconds, which would test date conversion instead of missing fields.
        let legacy = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode(DataTransferRecord.self, from: legacy)
        #expect(decoded == original)
        #expect(decoded.legacyRootOwnership == nil)
        #expect(decoded.legacyMountFlags == nil)

        let snapshot = fixture.legacySnapshot(owner: nil)
        let snapshotData = try PropertyListEncoder().encode(snapshot)
        var manifest = try #require(try PropertyListSerialization.propertyList(from: snapshotData, format: nil) as? [String: Any])
        manifest.removeValue(forKey: "restoredRootOwnership")
        let oldManifest = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        #expect(try PropertyListDecoder().decode(TreeCopySnapshot.self, from: oldManifest) == snapshot)
    }

    @Test("Corrupt legacy compatibility metadata fails closed on reopen",
          arguments: ["flagsWithoutOwner", "flagsWithoutNoowners", "otherUID", "otherGID", "wrongMode", "wrongDirection",
                      "missingManifestOverride", "unmarkedManifestOverride", "opaqueManifest", "wrongRootOwner", "wrongRootInode"])
    func invalidLegacyMetadataPreservesBytes(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var restore = fixture.restore(fixture.mount("A"))
        let owner = TreeCopySnapshot.Ownership(uid: geteuid(), gid: getegid())
        restore.legacyRootOwnership = owner
        restore.legacyMountFlags = UInt32(MNT_IGNORE_OWNERSHIP)
        restore.sourceIdentity = DataPathIdentity(device: 3, inode: 600, volumeUUID: "VOLUME-A")
        switch kind {
        case "flagsWithoutOwner": restore.legacyRootOwnership = nil
        case "flagsWithoutNoowners": restore.legacyMountFlags = UInt32(MNT_DONTBROWSE)
        case "otherUID": restore.legacyRootOwnership = .init(uid: geteuid() &+ 1, gid: getegid())
        case "otherGID": restore.legacyRootOwnership = .init(uid: geteuid(), gid: getegid() &+ 1)
        case "missingManifestOverride": restore.baseline = try PropertyListEncoder().encode(fixture.legacySnapshot(owner: nil))
        case "unmarkedManifestOverride":
            restore.legacyRootOwnership = nil
            restore.legacyMountFlags = nil
            restore.baseline = try PropertyListEncoder().encode(fixture.legacySnapshot(owner: owner))
        case "opaqueManifest": restore.baseline = Data("invalid-manifest".utf8)
        case "wrongRootOwner": restore.baseline = try PropertyListEncoder().encode(fixture.legacySnapshot(owner: owner, actualUID: geteuid() &+ 1))
        case "wrongRootInode": restore.baseline = try PropertyListEncoder().encode(fixture.legacySnapshot(owner: owner, inode: 601))
        default: break
        }
        let encoded = try PropertyListEncoder().encode(restore)
        var record = try #require(try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        if kind == "wrongMode" { record["mode"] = "symlink" }
        if kind == "wrongDirection" { record["direction"] = "migrate" }
        let object: [String: Any] = ["schemaVersion": 3, "mounts": [], "cleanups": [], "transfers": [record]]
        let bytes = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try bytes.write(to: fixture.file)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.transfers() }
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.beginTransfer(fixture.transfer()) }
        #expect(try Data(contentsOf: fixture.file) == bytes)
    }

    @Test("Contradictory legacy facts remain inspectable but never executable", arguments: [false, true])
    func conflictingLegacyRecordsRemainVisible(reversed: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let records = [fixture.mount("A", volume: "VOLUME-A"), fixture.mount("A/child", volume: "VOLUME-B")]
        let ordered = reversed ? records.reversed().map { $0 } : records
        let bytes = try PropertyListEncoder().encode(ordered)
        try bytes.write(to: fixture.file)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.recordsStrict() }
        let inspection = try fixture.store.recordsForInspection()
        #expect(inspection.mounts == ordered)
        #expect(inspection.validationError != nil)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.upsert(fixture.mount("Sibling")) }
        #expect(try Data(contentsOf: fixture.file) == bytes)
    }

    @Test("A normalized filesystem root cannot become an operation source")
    func rejectsDisguisedRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = fixture.transfer()
        transfer.originalPath = "/fixture/.."
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.beginTransfer(transfer) }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test("Filesystem identity capture does not follow a symlink")
    func identityDoesNotFollowLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target")
        try Data("fixture".utf8).write(to: target)
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let targetIdentity = try DataPathIdentity.capture(target)
        let linkIdentity = try DataPathIdentity.capture(link)
        #expect(targetIdentity.inode != linkIdentity.inode)
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: target, to: moved)
        #expect(try DataPathIdentity.capture(moved) == targetIdentity)
    }

    @Test("Normalizing a managed link replaces its index and retains both earlier copies")
    func managedLinkNormalizationPreservesLineage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var initial = fixture.transfer()
        try fixture.store.beginTransfer(initial)
        initial.phase = .copying
        try fixture.store.updateTransfer(initial)
        initial.phase = .verified
        initial.baseline = Data("initial".utf8)
        try fixture.store.updateTransfer(initial)
        initial.phase = .switching
        try fixture.store.updateTransfer(initial)
        try fixture.store.commitMigration(record: nil, transfer: initial)
        var normalization = DataTransferRecord(mode: .symlink, direction: .migrate, appName: "Fixture", dataDirType: "fixture",
            originalPath: initial.originalPath, activePath: initial.originalPath,
            destinationPath: fixture.root.appendingPathComponent("normalized/A").path,
            backupPath: initial.destinationPath, sourceIdentity: try #require(initial.destinationIdentity),
            priorOperationID: initial.operationID)
        try fixture.store.beginTransfer(normalization)
        normalization.phase = .copying
        try fixture.store.updateTransfer(normalization)
        normalization.phase = .verified
        normalization.baseline = Data("updated-source".utf8)
        normalization.destinationIdentity = DataPathIdentity(device: 3, inode: 999)
        try fixture.store.updateTransfer(normalization)
        normalization.phase = .switching
        try fixture.store.updateTransfer(normalization)
        try fixture.store.commitMigration(record: nil, transfer: normalization)
        let index = try #require(try fixture.store.managedLinks().first)
        #expect(index.operationID == normalization.operationID)
        #expect(index.destinationPath == fixture.root.appendingPathComponent("normalized/A").path)
        #expect(try fixture.store.transfers().count == 2)
        #expect(try fixture.store.transfer(operationID: initial.operationID)?.backupPath == fixture.root.appendingPathComponent("A.backup").path)
        #expect(try fixture.store.transfer(operationID: normalization.operationID)?.backupPath == fixture.root.appendingPathComponent("external/A").path)
        var restore = DataTransferRecord(mode: .symlink, direction: .restore, appName: "Fixture", dataDirType: "fixture",
            originalPath: normalization.originalPath, activePath: normalization.originalPath,
            destinationPath: normalization.originalPath, backupPath: normalization.destinationPath,
            stagingPath: fixture.root.appendingPathComponent("restore-staging").path,
            sourceIdentity: try #require(normalization.destinationIdentity), priorOperationID: normalization.operationID)
        try fixture.store.beginTransfer(restore)
        restore.phase = .copying
        try fixture.store.updateTransfer(restore)
        restore.phase = .verified
        restore.baseline = Data("restore-baseline".utf8)
        restore.destinationIdentity = DataPathIdentity(device: 1, inode: 1234)
        try fixture.store.updateTransfer(restore)
        try fixture.store.beginRestore(transfer: restore, removingMount: nil)
        try fixture.store.finalizeTransfer(operationID: restore.operationID, baseline: Data("restore-baseline".utf8))
        // The terminal restore must also remain: earlier copies depend on its
        // active local identity even though deleting it leaves valid topology.
        #expect(throws: ContainerMountStore.StoreError.self) {
            try fixture.store.requestCleanup(operationID: restore.operationID)
        }
        #expect(try fixture.store.transfer(operationID: restore.operationID)?.phase == .awaitingUserVerification)
        // The middle record is still the proof connecting the original migration to restore.
        // Refuse its deletion intent before any physical cleanup can occur.
        #expect(throws: ContainerMountStore.StoreError.self) {
            try fixture.store.requestCleanup(operationID: normalization.operationID)
        }
        #expect(try fixture.store.transfer(operationID: normalization.operationID)?.phase == .awaitingUserVerification)
        try fixture.store.requestCleanup(operationID: initial.operationID)
        try fixture.store.finishTransfer(operationID: initial.operationID, deletionConfirmed: true)
        try fixture.store.requestCleanup(operationID: normalization.operationID)
        try fixture.store.finishTransfer(operationID: normalization.operationID, deletionConfirmed: true)
        #expect(try fixture.store.transfers().map(\.operationID) == [restore.operationID])
        try fixture.store.requestCleanup(operationID: restore.operationID)
        try fixture.store.finishTransfer(operationID: restore.operationID, deletionConfirmed: true)
        #expect(try fixture.store.transfers().isEmpty)
    }

    @Test("A remount intervention persists until explicit resolution and cannot attach to an unknown volume")
    func remountInterventionSurvivesReopen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mount = fixture.mount("A", volume: "OFFLINE-VOLUME")
        try fixture.store.upsert(mount)
        try fixture.store.setRemountIntervention(volumeUUID: mount.volumeUUID, reason: "Unexpected local contents")
        let reopened = ContainerMountStore(fileURL: fixture.file)
        #expect(try reopened.remountIntervention(forVolumeUUID: mount.volumeUUID) == "Unexpected local contents")
        #expect(try reopened.recordsStrict() == [mount])
        #expect(throws: ContainerMountStore.StoreError.self) {
            try reopened.setRemountIntervention(volumeUUID: "UNRELATED", reason: "A different volume")
        }
        try reopened.setRemountIntervention(volumeUUID: mount.volumeUUID, reason: nil)
        #expect(try reopened.remountIntervention(forVolumeUUID: mount.volumeUUID) == nil)
        try reopened.setRemountIntervention(volumeUUID: mount.volumeUUID, reason: "Blocked again")
        try reopened.remove(mountPointPath: mount.mountPointPath)
        #expect(try reopened.remountIntervention(forVolumeUUID: mount.volumeUUID) == nil)
    }

    @Test("Known volume identity survives device reassignment without accepting another inode or volume")
    func volumeIdentityCanMatchAfterReattachment() {
        let saved = DataPathIdentity(device: 3, inode: 700, volumeUUID: "EXPECTED")
        #expect(saved.matchesFilesystemObject(DataPathIdentity(device: 19, inode: 700, volumeUUID: "expected")))
        #expect(!saved.matchesFilesystemObject(DataPathIdentity(device: 19, inode: 701, volumeUUID: "EXPECTED")))
        #expect(!saved.matchesFilesystemObject(DataPathIdentity(device: 3, inode: 700, volumeUUID: "OTHER")))
        #expect(!DataPathIdentity(device: 3, inode: 700).matchesFilesystemObject(DataPathIdentity(device: 19, inode: 700)))
        #expect(saved != DataPathIdentity(device: 19, inode: 700, volumeUUID: "EXPECTED"))
        #expect(!saved.matchesFilesystemObject(DataPathIdentity(volumeUUID: "EXPECTED")))
    }

    @Test("Capturing local identity records its volume and a dangling link uses its parent's volume")
    func captureRecordsVolumeWithoutFollowingLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let parent = try DataPathIdentity.capture(fixture.root)
        #expect(parent.volumeUUID != nil)
        let link = fixture.root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/UnavailableSyntheticVolume/target")
        let identity = try DataPathIdentity.capture(link)
        #expect(identity.volumeUUID == parent.volumeUUID)
        #expect(identity.inode != parent.inode)
    }

    private final class LockedErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [any Error] = []
        func append(_ error: any Error) { lock.lock(); defer { lock.unlock() }; values.append(error) }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    }

    private struct LegacyDocument: Codable {
        let schemaVersion: Int
        let mounts: [ContainerMountRecord]
        let cleanups: [ContainerCleanupRecord]
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let store: ContainerMountStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("TransferStore-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("state.plist")
            store = ContainerMountStore(fileURL: file)
        }
        func mount(_ leaf: String, volume: String = "VOLUME-A") -> ContainerMountRecord {
            ContainerMountRecord(appName: "Fixture", bundleIdentifier: "test.fixture", dataDirType: "fixture",
                mountPointPath: root.appendingPathComponent(leaf).path, volumeUUID: volume,
                volumeName: "Fixture", externalRootPath: root.appendingPathComponent("external").path)
        }
        func transfer(mode: DataTransferRecord.Mode = .symlink) -> DataTransferRecord {
            DataTransferRecord(mode: mode, direction: .migrate, appName: "Fixture", bundleIdentifier: "test.fixture",
                dataDirType: "fixture", originalPath: root.appendingPathComponent("A").path,
                activePath: root.appendingPathComponent("external/A").path,
                destinationPath: root.appendingPathComponent("external/A").path,
                backupPath: root.appendingPathComponent("A.backup").path,
                sourceIdentity: DataPathIdentity(device: 1, inode: 42),
                destinationIdentity: DataPathIdentity(device: 2, inode: 500))
        }
        func restore(_ mount: ContainerMountRecord) -> DataTransferRecord {
            let id = UUID()
            return DataTransferRecord(operationID: id, mode: .mount, direction: .restore,
                appName: mount.appName, bundleIdentifier: mount.bundleIdentifier, dataDirType: mount.dataDirType,
                originalPath: mount.mountPointPath, activePath: mount.mountPointPath, destinationPath: mount.mountPointPath,
                backupPath: root.appendingPathComponent("recovery-\(id.uuidString)").path,
                stagingPath: root.appendingPathComponent(".appports-restore-staging-\(id.uuidString)").path,
                sourceIdentity: DataPathIdentity(volumeUUID: mount.volumeUUID))
        }
        func legacySnapshot(owner: TreeCopySnapshot.Ownership?, actualUID: UInt32 = 0, inode: UInt64 = 600) -> TreeCopySnapshot {
            TreeCopySnapshot(restoredRootOwnership: owner, entries: [
                .init(path: "", kind: .directory, identity: .init(device: 3, inode: inode), mode: 0o755,
                      uid: actualUID, gid: 0, flags: 0, birthTime: .init(seconds: 1, nanoseconds: 0),
                      modificationTime: .init(seconds: 1, nanoseconds: 0), extendedAttributes: [:], acl: nil,
                      size: 0, digest: nil, linkTarget: nil, hardlinkGroup: nil)
            ], excludedRootEntries: [])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
