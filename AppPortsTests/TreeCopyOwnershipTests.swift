import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Data copies on ownership-ignoring volumes")
struct TreeCopyOwnershipTests {
    struct Scenario: Sendable {
        let sourceIgnoresOwnership: Bool
        let destinationIgnoresOwnership: Bool
    }

    static let scenarios = [
        Scenario(sourceIgnoresOwnership: false, destinationIgnoresOwnership: true),
        Scenario(sourceIgnoresOwnership: true, destinationIgnoresOwnership: false),
        Scenario(sourceIgnoresOwnership: true, destinationIgnoresOwnership: true)
    ]

    @Test("Real APFS noowners copies retain metadata, links, restoration and cleanup", arguments: scenarios)
    func copyAndRestore(scenario: Scenario) async throws {
        try await withImage { image in
            let source = (scenario.sourceIgnoresOwnership ? image.mountPoint : image.root).appendingPathComponent("source")
            let destination = (scenario.destinationIgnoresOwnership ? image.mountPoint : image.root).appendingPathComponent("copy")
            try await makeTree(at: source)
            let baseline = try await TreeCopySession().copy(from: source, to: destination)
            let contract = try #require(baseline.ownershipCompatibility)
            #expect(contract.sourceIgnoresOwnership == scenario.sourceIgnoresOwnership)
            #expect(contract.destinationIgnoresOwnership == scenario.destinationIgnoresOwnership)
            #expect(contract.projectedSourceOwner == (scenario.sourceIgnoresOwnership ? .init(uid: geteuid(), gid: getegid()) : nil))
            let persisted = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: PropertyListEncoder().encode(baseline))
            #expect(persisted == baseline)
            try TreeCopySession.verifyUnchanged(at: source, against: persisted)
            try TreeCopySession.verifyCopy(at: destination, against: persisted)
            try TreeCopySession.applyRootMetadata(at: destination, from: persisted, ownershipRole: .destination)
            #expect(try info(destination).st_mode & 0o7777 == 0o700)
            #expect(try info(destination.appendingPathComponent("nested/payload")).st_mode & 0o7777 == 0o440)
            #expect(try info(destination.appendingPathComponent("nested/payload")).st_ino
                    == info(destination.appendingPathComponent("second")).st_ino)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link").path) == "nested/payload")

            let restored = image.root.appendingPathComponent("restored")
            let restore = try await TreeCopySession().copy(from: destination, to: restored)
            try TreeCopySession.applyRootMetadata(at: restored, from: restore, ownershipRole: .destination)
            try TreeCopySession.verifyCopy(at: restored, against: restore)
            #expect(try info(restored).st_uid == geteuid())
            #expect(try info(restored).st_gid == getegid())
            #expect(try Data(contentsOf: restored.appendingPathComponent("nested/payload")) == Data("verified data".utf8))

            try TreeCopySession.removeVerifiedCopy(at: source, against: baseline)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
            try TreeCopySession.removeVerifiedCopy(at: destination, against: restore)
            try TreeCopySession.verifyCopy(at: restored, against: restore)
            try TreeCopySession.removeVerifiedCopy(at: restored, against: restore, ownershipRole: .destination)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(!FileManager.default.fileExists(atPath: restored.path))
        }
    }

    @Test("A noowners destination never weakens the real source ownership baseline")
    func sourceOwnershipStaysStrict() async throws {
        try await withImage { image in
            let source = image.root.appendingPathComponent("source")
            let destination = image.mountPoint.appendingPathComponent("copy")
            try await makeTree(at: source)
            // BSD group inheritance under /private/tmp can produce wheel (0),
            // which is not necessarily the test process's effective group.
            try #require(chown(source.path, geteuid(), getegid()) == 0)
            let baseline = try await TreeCopySession().copy(from: source, to: destination)
            let alternate = try alternateGroup()
            try #require(chown(source.path, geteuid(), alternate) == 0)
            #expect(throws: TreeCopyError.self) { try TreeCopySession.verifyUnchanged(at: source, against: baseline) }
            #expect(throws: TreeCopyError.self) { try TreeCopySession.removeVerifiedCopy(at: source, against: baseline) }
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
            try #require(chown(source.path, geteuid(), getegid()) == 0)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)

            // Historical manifests did not opt in to projected ownership.
            var raw = try #require(PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(baseline), format: nil) as? [String: Any])
            raw.removeValue(forKey: "ownershipCompatibility")
            let historical = try PropertyListDecoder().decode(TreeCopySnapshot.self,
                from: PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0))
            #expect(historical.ownershipCompatibility == nil)
            #expect(throws: TreeCopyError.self) { try TreeCopySession.verifyCopy(at: destination, against: historical) }
            #expect(throws: TreeCopyError.self) { try TreeCopySession.removeVerifiedCopy(at: destination, against: historical, ownershipRole: .destination) }

            // Reattaching with owners does not invent a strict baseline for a
            // destination whose stored ownership was never observable.
            try await image.remount(ignoringOwnership: false)
            try #require(chown(destination.path, geteuid(), alternate) == 0)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
            try TreeCopySession.removeVerifiedCopy(at: destination, against: baseline, ownershipRole: .destination)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try TreeCopySession.removeVerifiedCopy(at: source, against: baseline)
        }
    }

    @Test("A projected source restores as the user and never rewrites its hidden physical owner")
    func sourceRemountPreservesPhysicalOwnership() async throws {
        try await withImage { image in
            try await image.remount(ignoringOwnership: false)
            let source = image.mountPoint.appendingPathComponent("source")
            try await makeTree(at: source)
            let alternate = try alternateGroup()
            try #require(chown(source.path, geteuid(), alternate) == 0)
            let strict = try TreeCopySession.snapshot(at: source)
            let uuid = try #require(source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            #expect(strict.ownershipCompatibility == nil)
            try await image.remount(ignoringOwnership: true)
            #expect(throws: TreeCopyError.self) {
                try TreeCopySession.verifyUnchanged(at: source, against: strict, expectedVolumeUUID: uuid)
            }
            let restored = image.root.appendingPathComponent("restored")
            let baseline = try await TreeCopySession().copy(from: source, to: restored)
            #expect(baseline.ownershipCompatibility?.sourceIgnoresOwnership == true)
            #expect(baseline.ownershipCompatibility?.destinationIgnoresOwnership == false)
            #expect(try info(restored).st_gid == getegid())

            try await image.remount(ignoringOwnership: false)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline, expectedVolumeUUID: uuid)
            try TreeCopySession.applyRootMetadata(at: source, from: baseline)
            #expect(try info(source).st_gid == alternate)
            try TreeCopySession.verifyCopy(at: restored, against: baseline)
            try #require(chown(restored.path, geteuid(), alternate) == 0)
            #expect(throws: TreeCopyError.self) { try TreeCopySession.verifyCopy(at: restored, against: baseline) }
            try #require(chown(restored.path, geteuid(), getegid()) == 0)
            try TreeCopySession.removeVerifiedCopy(at: source, against: baseline)
            try TreeCopySession.removeVerifiedCopy(at: restored, against: baseline, ownershipRole: .destination)
        }
    }

    @Test("Relinking existing noowners data keeps its physical root ownership")
    func relinkingKeepsPhysicalOwnership() async throws {
        try await withImage { image in
            try await image.remount(ignoringOwnership: false)
            let external = image.mountPoint.appendingPathComponent("Existing Data")
            try await makeTree(at: external)
            let alternate = try alternateGroup()
            try #require(chown(external.path, geteuid(), alternate) == 0)
            let home = image.root.appendingPathComponent("home")
            let local = home.appendingPathComponent("Library/Application Support/Existing Data")
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let store = ContainerMountStore(fileURL: image.root.appendingPathComponent("transfers.plist"))
            let mover = DataDirMover(homeDir: home, store: store, runner: OwnershipTestIdleRunner())

            try await image.remount(ignoringOwnership: true)
            try await mover.createLink(localPath: local, externalPath: external)
            #expect(try info(local).st_mode & S_IFMT == S_IFLNK)
            #expect(local.resolvingSymlinksInPath() == external.resolvingSymlinksInPath())
            try await image.remount(ignoringOwnership: false)
            #expect(try info(external).st_gid == alternate)
            #expect(try info(external).st_uid == geteuid())
            #expect(try Data(contentsOf: external.appendingPathComponent("nested/payload")) == Data("verified data".utf8))
        }
    }

    @Test("Normal noowners migration and restore finish cleanup and can repeat at the same destination")
    func completedMigrationServiceCanRepeat() async throws {
        try await withImage { image in
            let home = image.root.appendingPathComponent("home")
            let local = home.appendingPathComponent("Library/Application Support/Repeat Data")
            try await makeTree(at: local)
            let external = image.mountPoint.appendingPathComponent(local.lastPathComponent)
            let store = ContainerMountStore(fileURL: image.root.appendingPathComponent("completed-transfers.plist"))
            let mover = DataDirMover(homeDir: home, store: store, runner: OwnershipTestIdleRunner())
            let item = DataDirItem(name: "Repeat Data", path: local, type: .applicationSupport,
                                   priority: .critical, description: "Isolated completed noowners migration")
            for _ in 0..<2 {
                let migration = try await mover.migrateAndComplete(item: item, to: image.mountPoint, progressHandler: nil)
                #expect(migration.cleanupWarning == nil)
                #expect(try store.transfers().isEmpty)
                #expect(try store.managedLinks().count == 1)
                #expect(try info(local).st_mode & S_IFMT == S_IFLNK)
                #expect(try FileManager.default.contentsOfDirectory(atPath: local.deletingLastPathComponent().path)
                    .allSatisfy { !$0.hasPrefix(".appports-migration-backup-") })

                let restoration = try await mover.restoreAndComplete(item: item, progressHandler: nil)
                #expect(restoration.cleanupWarning == nil)
                #expect(try store.transfers().isEmpty)
                #expect(try store.managedLinks().isEmpty)
                #expect(!FileManager.default.fileExists(atPath: external.path))
                #expect(try info(local).st_mode & S_IFMT == S_IFDIR)
                #expect(try info(local).st_uid == geteuid())
                #expect(try info(local).st_gid == getegid())
                #expect(try Data(contentsOf: local.appendingPathComponent("nested/payload")) == Data("verified data".utf8))
                #expect(try info(local.appendingPathComponent("nested/payload")).st_ino
                    == info(local.appendingPathComponent("second")).st_ino)
            }
        }
    }

    @Test("Partial retained cleanup waits for the same real noowners volume and resumes after reconnection")
    func partialCleanupAfterReconnect() async throws {
        try await withImage { image in
            let home = image.root.appendingPathComponent("Home")
            let source = home.appendingPathComponent("Payload")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("latest data".utf8).write(to: source.appendingPathComponent("keep.txt"))
            try Data("second file".utf8).write(to: source.appendingPathComponent("other.txt"))
            let store = ContainerMountStore(fileURL: image.root.appendingPathComponent("cleanup-ledger.plist"))
            let mover = DataDirMover(homeDir: home, store: store, runner: OwnershipTestIdleRunner())
            let item = DataDirItem(name: "Payload", path: source, type: .custom, priority: .optional, description: "")
            let result = try await mover.migrateAndComplete(item: item, to: image.mountPoint, progressHandler: nil)
            #expect(result.cleanupWarning == nil)
            try await mover.restore(item: item, progressHandler: nil)
            let transfer = try #require(try store.transfers().first)
            let backup = URL(fileURLWithPath: try #require(transfer.backupPath))
            try store.requestCleanup(operationID: transfer.operationID)
            try store.beginCleanupDeletion(operationID: transfer.operationID,
                parentIdentity: DataPathIdentity.capture(backup.deletingLastPathComponent()))
            try FileManager.default.removeItem(at: backup.appendingPathComponent("other.txt"))
            let current = try TreeCopySession.snapshot(at: source)
            try await image.detach()
            await #expect(throws: (any Error).self) { try await mover.cleanupRetainedTransfer(operationID: transfer.operationID) }
            #expect(try store.transfers().count == 1)
            try await image.remount(ignoringOwnership: true)
            try await mover.cleanupRetainedTransfer(operationID: transfer.operationID)
            #expect(try store.transfers().isEmpty)
            #expect(try TreeCopySession.snapshot(at: source) == current)
            #expect(!FileManager.default.fileExists(atPath: backup.path))
        }
    }

    @Test("An unstarted restore from a real volume root releases its failed intent")
    func unstartedVolumeRootRestoreCanRetry() async throws {
        try await withImage { image in
            let home = image.root.appendingPathComponent("Home")
            let local = home.appendingPathComponent("Volume Data")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data("volume-root payload".utf8).write(to: image.mountPoint.appendingPathComponent("payload.txt"))
            try FileManager.default.createSymbolicLink(at: local, withDestinationURL: image.mountPoint)
            let ledger = image.root.appendingPathComponent("root-restore.plist")
            let store = ContainerMountStore(fileURL: ledger, writeData: { data, url in
                let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                let transfers = document?["transfers"] as? [[String: Any]] ?? []
                if transfers.contains(where: { $0["phase"] as? String == "copying" }) { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            let mover = DataDirMover(homeDir: home, store: store, runner: OwnershipTestIdleRunner())
            let item = DataDirItem(name: "Volume Data", path: local, type: .custom, priority: .optional, description: "")
            // This intentional write failure happens before the volume root is copied.
            for _ in 0..<2 {
                await #expect(throws: (any Error).self) { try await mover.restore(item: item, progressHandler: nil) }
                #expect(try store.transfers().isEmpty)
                #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == ["Volume Data"])
                #expect(local.resolvingSymlinksInPath() == image.mountPoint.resolvingSymlinksInPath())
                #expect(try String(contentsOf: image.mountPoint.appendingPathComponent("payload.txt"), encoding: .utf8) == "volume-root payload")
            }
        }
    }

    @Test("A restored directory can move to another target while its real noowners source image is detached")
    func remigrationWithOfflineRestoreCopy() async throws {
        try await withImage { image in
            let home = image.root.appendingPathComponent("home")
            let local = home.appendingPathComponent("Payload")
            let nextRoot = image.root.appendingPathComponent("next-target")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
            try await makeTree(at: local)
            let item = DataDirItem(name: "Payload", path: local, type: .custom, priority: .optional, description: "")
            let ledger = image.root.appendingPathComponent("remigration.plist")
            let store = ContainerMountStore(fileURL: ledger)
            let mover = DataDirMover(homeDir: home, store: store, runner: OwnershipTestIdleRunner())
            #expect(try await mover.migrateAndComplete(item: item, to: image.mountPoint, progressHandler: nil).cleanupWarning == nil)
            try await mover.restore(item: item, progressHandler: nil)
            let restore = try #require(try store.transfers().first)
            let oldRoot = URL(fileURLWithPath: try #require(restore.backupPath))
            let oldIdentity = try DataPathIdentity.capture(oldRoot)
            try await image.detach()
            try #require(!FileManager.default.fileExists(atPath: oldRoot.path))
            try Data("new local content".utf8).write(to: local.appendingPathComponent("after-restore.txt"))
            let result = try await mover.migrateAndComplete(item: item, to: nextRoot, progressHandler: nil)
            #expect(result.cleanupWarning != nil)
            let next = try #require(try store.transfers().first { $0.priorOperationID == restore.operationID })
            #expect(next.isDataSwitchComplete)
            #expect(try String(contentsOf: local.appendingPathComponent("after-restore.txt"), encoding: .utf8) == "new local content")
            let activeIdentity = try DataPathIdentity.capture(local.resolvingSymlinksInPath())
            try await image.remount(ignoringOwnership: true)
            #expect(try DataPathIdentity.capture(oldRoot).matchesFilesystemObject(oldIdentity))
            let cold = DataDirMover(homeDir: home, store: ContainerMountStore(fileURL: ledger), runner: OwnershipTestIdleRunner())
            try await cold.cleanupRetainedLineage(operationID: next.operationID)
            #expect(try store.transfers().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: oldRoot.path))
            #expect(try DataPathIdentity.capture(local.resolvingSymlinksInPath()) == activeIdentity)
            #expect(try String(contentsOf: local.appendingPathComponent("after-restore.txt"), encoding: .utf8) == "new local content")
            #expect(try await cold.restoreAndComplete(item: item, progressHandler: nil).cleanupWarning == nil)
            #expect(try store.transfers().isEmpty)
            #expect(try store.managedLinks().isEmpty)
        }
    }

    @Test("A preserved material record can be dismissed after real noowners disconnect and reconnect without deleting data")
    func preservedMaterialRecordLifecycleAfterReconnect() async throws {
        try await withImage { image in
            let source = image.root.appendingPathComponent("LocalSource")
            let candidate = image.mountPoint.appendingPathComponent("UserKeptMaterial")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            try Data("authoritative source".utf8).write(to: source.appendingPathComponent("payload"))
            try Data("unique material".utf8).write(to: candidate.appendingPathComponent("payload"))
            let store = ContainerMountStore(fileURL: image.root.appendingPathComponent("materials.plist"))
            var transfer = DataTransferRecord(mode: .symlink, direction: .migrate, appName: "Material Fixture",
                dataDirType: "custom", originalPath: source.path, activePath: source.path,
                destinationPath: image.mountPoint.appendingPathComponent("Unpublished").path,
                sourceIdentity: try DataPathIdentity.capture(source))
            transfer.preparationPath = candidate.path
            try store.beginTransfer(transfer)
            try store.endUnswitchedTransfer(transfer, preserving: "material deliberately kept") { }
            let material = try #require(try store.preservedMaterials().first)
            let bytes = try Data(contentsOf: image.root.appendingPathComponent("materials.plist"))
            let service = DataTransferMaterialService(store: store)
            try await image.detach()
            #expect(try await service.recheckPreservedMaterial(id: material.id) == .absenceUnverified)
            #expect(try Data(contentsOf: image.root.appendingPathComponent("materials.plist")) == bytes)
            try await image.remount(ignoringOwnership: true)
            #expect(try await service.recheckPreservedMaterial(id: material.id) == .listedPathsStillExist([candidate.path]))
            #expect(try await service.removePreservedMaterialRecord(id: material.id,
                confirmation: .keepAllFilesAndVolumes) == .recordRemoved)
            #expect(try store.preservedMaterials().isEmpty)
            #expect(DiskUtility.isMountPoint(image.mountPoint))
            #expect(try String(contentsOf: candidate.appendingPathComponent("payload"), encoding: .utf8) == "unique material")
            #expect(try String(contentsOf: source.appendingPathComponent("payload"), encoding: .utf8) == "authoritative source")
        }
    }

    @Test("DataDirMover migrates, restores and cleans its retained lineage on noowners")
    func migrationServiceRoundTrip() async throws {
        try await withImage { image in
            let home = image.root.appendingPathComponent("home")
            let local = home.appendingPathComponent("Library/Application Support/Example Data")
            try await makeTree(at: local)
            let external = image.mountPoint.appendingPathComponent(local.lastPathComponent)
            let ledger = image.root.appendingPathComponent("transfers.plist")
            let store = ContainerMountStore(fileURL: ledger)
            let mover = DataDirMover(homeDir: home, store: store, runner: OwnershipTestIdleRunner())
            let item = DataDirItem(name: "Example Data", path: local, type: .applicationSupport,
                                   priority: .critical, description: "Isolated noowners migration")
            try await mover.migrate(item: item, to: image.mountPoint, progressHandler: nil)
            let migration = try #require(try store.transfers().first)
            #expect(migration.phase == .awaitingUserVerification)
            let backup = URL(fileURLWithPath: try #require(migration.backupPath))
            #expect(try info(local).st_mode & S_IFMT == S_IFLNK)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local.path) == external.path)
            #expect(try Data(contentsOf: backup.appendingPathComponent("nested/payload")) == Data("verified data".utf8))
            #expect(try Data(contentsOf: external.appendingPathComponent("nested/payload")) == Data("verified data".utf8))
            let document = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: ledger), format: nil) as? [String: Any])
            #expect(document["schemaVersion"] as? Int == 7)

            try await mover.restore(item: item, progressHandler: nil)
            let restoration = try #require(try store.transfers().first { $0.direction == .restore })
            #expect(restoration.phase == .awaitingUserVerification)
            #expect(restoration.priorOperationID == migration.operationID)
            #expect(try info(local).st_mode & S_IFMT == S_IFDIR)
            #expect(try info(local).st_uid == geteuid())
            #expect(try info(local).st_gid == getegid())
            #expect(try store.managedLinks().isEmpty)
            #expect(FileManager.default.fileExists(atPath: backup.path))
            #expect(FileManager.default.fileExists(atPath: external.path))

            try await mover.cleanupRetainedTransfer(operationID: migration.operationID)
            #expect(!FileManager.default.fileExists(atPath: backup.path))
            #expect(FileManager.default.fileExists(atPath: external.path))
            try await mover.cleanupRetainedTransfer(operationID: restoration.operationID)
            #expect(!FileManager.default.fileExists(atPath: external.path))
            #expect(try store.transfers().isEmpty)
            #expect(try Data(contentsOf: local.appendingPathComponent("nested/payload")) == Data("verified data".utf8))
            #expect(try info(local.appendingPathComponent("nested/payload")).st_ino
                    == info(local.appendingPathComponent("second")).st_ino)
        }
    }

    @Test("Compatibility still rejects changed bytes, permissions, ACLs and application metadata",
          arguments: ["bytes", "mode", "acl", "xattr", "identity"])
    func compatibilityKeepsOtherChecks(_ changed: String) async throws {
        try await withImage { image in
            let source = image.mountPoint.appendingPathComponent("source")
            try await makeTree(at: source)
            let baseline = try TreeCopySession.snapshot(at: source)
            let file = source.appendingPathComponent("nested/payload")
            switch changed {
            case "bytes":
                try #require(chmod(file.path, 0o640) == 0)
                try Data("changed bytes".utf8).write(to: file)
                try #require(chmod(file.path, 0o440) == 0)
                let timestamp = try #require(baseline.entries.first { $0.path == "nested/payload" }).modificationTime
                var attributes = attrlist()
                attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attributes.commonattr = attrgroup_t(ATTR_CMN_MODTIME)
                var time = timespec(tv_sec: Int(timestamp.seconds), tv_nsec: Int(timestamp.nanoseconds))
                try #require(setattrlist(file.path, &attributes, &time, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0)
            case "mode": try #require(chmod(file.path, 0o640) == 0)
            case "acl": _ = try await image.run("/bin/chmod", ["+a", "everyone allow execute", source.path])
            case "xattr": try setXattr(Data("changed metadata".utf8), at: source)
            default:
                let preserved = image.mountPoint.appendingPathComponent("preserved")
                try FileManager.default.moveItem(at: source, to: preserved)
                _ = try await TreeCopySession().copy(from: preserved, to: source)
            }
            #expect(throws: TreeCopyError.self) { try TreeCopySession.verifyUnchanged(at: source, against: baseline) }
            if changed != "identity" {
                #expect(throws: TreeCopyError.self) { try TreeCopySession.removeVerifiedCopy(at: source, against: baseline) }
            }
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("Ownership image cleanup still detaches after its volume was unmounted")
    func cleanupAfterVolumeUnmount() async throws {
        try await withImage { image in
            _ = try await image.run("/usr/sbin/diskutil", ["unmount", image.mountPoint.path])
            #expect(!DiskUtility.isMountPoint(image.mountPoint))
        }
    }

    private func makeTree(at source: URL) async throws {
        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("payload")
        try Data("verified data".utf8).write(to: file)
        try #require(link(file.path, source.appendingPathComponent("second").path) == 0)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "nested/payload")
        try setXattr(Data([0, 255, 1, 128]), at: source)
        // The ACL is fixture setup; the deadline is only a guard against a hung
        // command, so a loaded CI runner does not fail the ownership assertions.
        let result = try await ProcessCommandRunner().run(executable: "/bin/chmod",
            arguments: ["+a", "everyone allow readattr,readextattr,readsecurity", source.path], timeout: 60)
        try #require(result.status == 0 && !result.timedOut, "\(result.combinedText)")
        try #require(chmod(source.path, 0o700) == 0)
        try #require(chmod(nested.path, 0o550) == 0)
        try #require(chmod(file.path, 0o440) == 0)
    }

    private func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return value
    }

    private func setXattr(_ data: Data, at url: URL) throws {
        let status = data.withUnsafeBytes { setxattr(url.path, "org.appports.ownership-test", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        try #require(status == 0)
    }

    private func alternateGroup() throws -> gid_t {
        let count = getgroups(0, nil)
        try #require(count > 0)
        var groups = [gid_t](repeating: 0, count: Int(count))
        try #require(getgroups(count, &groups) == count)
        return try #require(groups.first { $0 != getegid() })
    }

    private func withImage(_ operation: (OwnershipTestImage) async throws -> Void) async throws {
        let image = try OwnershipTestImage()
        do {
            try await image.prepare()
            try await operation(image)
        } catch {
            try await image.cleanup()
            throw error
        }
        try await image.cleanup()
    }
}

private struct OwnershipTestIdleRunner: ShellCommandRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        try #require(executable == "/usr/sbin/lsof")
        return .init(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
    }
}

/// Every command is confined to a newly created private disk image. No test
/// changes ownership settings on the user's external volumes or system disk.
private actor OwnershipTestImage {
    nonisolated let root: URL
    nonisolated let mountPoint: URL
    private let imageURL: URL
    private var attached = false
    private var deviceURL: URL?

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/appports-ownership-test-\(UUID().uuidString)")
        mountPoint = root.appendingPathComponent("volume")
        imageURL = root.appendingPathComponent("volume.dmg")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    }

    func prepare() async throws {
        _ = try await run("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "APFS", "-volname", "AppPortsOwnershipTest", imageURL.path])
        try await attach(ignoringOwnership: true)
    }

    func remount(ignoringOwnership: Bool) async throws {
        if attached { try await detach() }
        try await attach(ignoringOwnership: ignoringOwnership)
    }

    func detach() async throws {
        let target = deviceURL ?? mountPoint
        let result = try await detachOwnershipImage(at: target)
        if result.status != 0 || result.timedOut {
            let owners = try? await ProcessCommandRunner(captureLimit: 16_384).run(
                executable: "/usr/sbin/lsof", arguments: ["-nP", "+f", "--", mountPoint.path], timeout: 5)
            try #require(result.status == 0 && !result.timedOut,
                "hdiutil detach \(target.path): \(result.combinedText); status=\(result.status), timedOut=\(result.timedOut); lsof: \(owners?.combinedText ?? "unavailable")")
        }
        attached = false
        deviceURL = nil
    }

    private func attach(ignoringOwnership: Bool) async throws {
        let result = try await run("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-owners", ignoringOwnership ? "off" : "on", "-mountpoint", mountPoint.path, imageURL.path])
        attached = true
        deviceURL = try attachedDevice(in: result.standardOutput)
        var flags = statfs()
        try #require(statfs(mountPoint.path, &flags) == 0)
        try #require((flags.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0) == ignoringOwnership)
    }

    private func attachedDevice(in output: Data) throws -> URL {
        let plist = try PropertyListSerialization.propertyList(from: output, options: [], format: nil)
        let entities = try #require((plist as? [String: Any])?["system-entities"] as? [[String: Any]])
        let path = try #require(entities.compactMap { $0["dev-entry"] as? String }
            .first { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil })
        return URL(fileURLWithPath: path)
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> ShellCommandResult {
        let result = try await ProcessCommandRunner().run(executable: executable, arguments: arguments, timeout: 45)
        try #require(result.status == 0 && !result.timedOut, "\(executable) \(arguments): \(result.combinedText)")
        return result
    }

    func cleanup() async throws {
        if attached || DiskUtility.isMountPoint(mountPoint) { try await detach() }
        try removeTemporaryFiles()
    }

    private func removeTemporaryFiles() throws {
        // Make only this test's native temporary directories writable. The
        // image has already been detached, so traversal cannot reach a volume.
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                var value = stat()
                if lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR { _ = chmod(url.path, 0o700) }
            }
        }
        try FileManager.default.removeItem(at: root)
    }
}

/// Retry only a transient busy volume, never force it off or hide a timeout.
private func detachOwnershipImage(
    at mountPoint: URL,
    runner: any ShellCommandRunning = ProcessCommandRunner(),
    sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
) async throws -> ShellCommandResult {
    var retry = 0
    while true {
        try Task.checkCancellation()
        let result = try await runner.run(executable: "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint.path], timeout: 45)
        guard result.status == EBUSY, !result.timedOut, retry < 4 else { return result }
        try await sleep(250_000_000 << retry)
        retry += 1
    }
}

@Suite("Ownership image detach retry boundaries")
struct OwnershipImageDetachTests {
    @Test("Busy detach retries, while success, persistent errors and timeouts retain their result",
        arguments: ["success", "transient", "persistent", "other-error", "timeout"])
    func retryBoundaries(scenario: String) async throws {
        let statuses: [Int32]
        switch scenario {
        case "success": statuses = [0]
        case "transient": statuses = [EBUSY, EBUSY, 0]
        case "persistent": statuses = Array(repeating: EBUSY, count: 5)
        case "other-error": statuses = [EACCES]
        default: statuses = [EBUSY]
        }
        let runner = DetachTestRunner(statuses: statuses, timedOut: scenario == "timeout")
        let mountPoint = URL(fileURLWithPath: "/private/tmp/detach-test/volume")
        let result = try await detachOwnershipImage(at: mountPoint, runner: runner,
            sleep: { await runner.recordSleep($0) })
        #expect(result.status == statuses.last)
        #expect(result.timedOut == (scenario == "timeout"))
        #expect(await runner.calls == statuses.count)
        let expectedDelays: [UInt64] = Array([250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000].prefix(statuses.count - 1))
        #expect(await runner.delays == expectedDelays)
    }

    @Test("Cancellation during retry wait does not issue another detach")
    func cancellationStopsRetry() async throws {
        let runner = DetachTestRunner(statuses: [EBUSY], timedOut: false)
        await #expect(throws: CancellationError.self) {
            try await detachOwnershipImage(at: URL(fileURLWithPath: "/private/tmp/detach-test/volume"),
                runner: runner, sleep: { _ in throw CancellationError() })
        }
        #expect(await runner.calls == 1)
    }
}

private actor DetachTestRunner: ShellCommandRunning {
    let statuses: [Int32]
    let timedOut: Bool
    var calls = 0
    var delays: [UInt64] = []

    init(statuses: [Int32], timedOut: Bool) {
        self.statuses = statuses
        self.timedOut = timedOut
    }

    func recordSleep(_ delay: UInt64) { delays.append(delay) }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        #expect(executable == "/usr/bin/hdiutil")
        #expect(arguments == ["detach", "/private/tmp/detach-test/volume"])
        #expect(timeout == 45)
        try #require(calls < statuses.count)
        let status = statuses[calls]
        calls += 1
        return .init(status: status, standardOutput: Data(), standardError: Data(), timedOut: timedOut)
    }
}
