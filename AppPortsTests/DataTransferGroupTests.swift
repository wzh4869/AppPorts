import Foundation
import Testing
@testable import AppPorts

struct DataTransferGroupTests {
    @Test("A completed round trip is one group with current local data and two distinct copies")
    func completedRoundTrip() throws {
        let migration = record(direction: .migrate)
        let restoration = record(direction: .restore, prior: migration.operationID)
        let groups = DataTransferGroup.groups(from: [restoration, migration])
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.state == .restored)
        #expect(group.activePath == restoration.originalPath)
        #expect(group.activePath != migration.activePath)
        #expect(group.retainedCopies.map(\.storage) == [.local, .external])
        #expect(group.retainedCopies.map(\.path) == [migration.backupPath, restoration.backupPath])
        #expect(group.cleanupTransfers.map(\.operationID) == [migration.operationID, restoration.operationID])
    }

    @Test("Chain order takes precedence over recorded timestamps")
    func clockChangesDoNotReverseCleanup() throws {
        let migration = record(direction: .migrate, createdAt: Date(timeIntervalSince1970: 20))
        let restoration = record(direction: .restore, prior: migration.operationID, createdAt: Date(timeIntervalSince1970: 10))
        let group = try #require(DataTransferGroup.groups(from: [restoration, migration]).first)
        #expect(group.currentTransfer.operationID == restoration.operationID)
        #expect(group.cleanupTransfers.map(\.operationID) == [migration.operationID, restoration.operationID])
    }

    @Test("A remaining restore still displays after its retained ancestor was cleaned")
    func missingAncestor() throws {
        let restoration = record(direction: .restore, prior: UUID())
        let group = try #require(DataTransferGroup.groups(from: [restoration]).first)
        #expect(group.state == .restored)
        #expect(group.retainedCopies.count == 1)
        #expect(group.cleanupTransfers.map(\.operationID) == [restoration.operationID])
    }

    @Test("An account's old copies include only unfinished records for its member paths")
    func scopedRetainedTransfers() {
        var video = record(direction: .restore, mode: .mount)
        video.originalPath = "/synthetic/account/msg/./video"
        var file = record(direction: .restore, mode: .mount)
        file.originalPath = "/synthetic/account/msg/file"
        file.retainedCopyRemovedAt = Date()
        var other = record(direction: .restore, mode: .mount)
        other.originalPath = "/synthetic/other-account/msg/video"
        let paths: Set<String> = ["/synthetic/account", "/synthetic/account/msg/video", file.originalPath]

        #expect(DataCleanupResolution.retainedTransfers(in: [file, video, other], at: paths).map(\.id) == [video.id])
        #expect(DataCleanupResolution.retainedTransfers(in: [file, other], at: paths).isEmpty)
    }

    @Test("A physically cleaned current location is shown without inventing another retained copy")
    func removedCurrentCopyOnlyKeepsLocationProof() throws {
        let oldRestore = record(direction: .restore)
        var next = record(direction: .migrate, mode: .mount, prior: oldRestore.operationID)
        next.phase = .cleanupRequested
        next.retainedCopyRemovedAt = Date()
        next.baseline = nil
        next.sourceBaseline = nil
        let group = try #require(DataTransferGroup.groups(from: [next, oldRestore]).first)
        #expect(group.currentTransfer.operationID == next.operationID)
        #expect(group.state == .migrated)
        #expect(group.canCleanup)
        #expect(group.retainedCopies.map(\.id) == [oldRestore.operationID])
        #expect(group.cleanupTransfers.map(\.operationID) == [oldRestore.operationID])
        #expect(next.materialPaths.isEmpty)
    }

    @Test("Independent histories at the same path do not masquerade as a single verified chain")
    func unrelatedSamePath() {
        let migration = record(direction: .migrate)
        let restoration = record(direction: .restore)
        #expect(DataTransferGroup.groups(from: [migration, restoration]).count == 2)
    }

    @Test("A predecessor reference cannot combine different original paths")
    func differentPaths() {
        let migration = record(direction: .migrate)
        var restoration = record(direction: .restore, prior: migration.operationID)
        restoration.originalPath += "-other"
        #expect(DataTransferGroup.groups(from: [migration, restoration]).count == 2)
    }

    @Test("An interrupted restore remains visibly incomplete instead of inheriting earlier success")
    func incompleteDescendant() throws {
        let migration = record(direction: .migrate)
        var restoration = record(direction: .restore, prior: migration.operationID)
        restoration.phase = .needsRecovery
        restoration.activePath = migration.activePath
        restoration.recoverableReason = "Interrupted before switching the local path"
        let group = try #require(DataTransferGroup.groups(from: [migration, restoration]).first)
        #expect(group.state == .needsAttention)
        #expect(group.currentTransfer == restoration)
        #expect(group.retainedCopies.map(\.id) == [migration.operationID])
        #expect(!group.canCleanup)
        #expect(group.cleanupTransfers.isEmpty)
        #expect(group.unlockTransfer == nil)
        #expect(group.resumeTransfer == restoration)
    }

    @Test("Ambiguous branches never offer a bulk cleanup")
    func branchedHistory() throws {
        let migration = record(direction: .migrate)
        let first = record(direction: .restore, prior: migration.operationID)
        let second = record(direction: .restore, prior: migration.operationID)
        let group = try #require(DataTransferGroup.groups(from: [migration, first, second]).first)
        #expect(group.state == .needsAttention)
        #expect(group.cleanupTransfers.isEmpty)
        #expect(group.resumeTransfer == nil)
    }

    @Test("A restored APFS volume is identified by UUID rather than an obsolete private mount point")
    func mountRestoreCopy() {
        let restoration = record(direction: .restore, mode: .mount)
        let copy = DataTransferGroup(transfer: restoration).retainedCopies.first
        #expect(copy?.storage == .external)
        #expect(copy?.path == nil)
        #expect(copy?.volumeUUID == restoration.sourceIdentity.volumeUUID)
    }

    @Test("Normalized external originals remain labeled external")
    func normalizationCopy() {
        var migration = record(direction: .migrate)
        migration.backupPath = "/Volumes/Archive/Previous/Account"
        let group = DataTransferGroup(transfer: migration)
        #expect(group.retainedCopies.first?.storage == .external)
    }

    @Test("An unstarted singleton offers both checked cancellation and continuation")
    func unstartedUnlock() {
        var migration = record(direction: .migrate)
        migration.phase = .needsRecovery
        migration.activePath = migration.originalPath
        migration.destinationIdentity = nil
        migration.backupIdentity = nil
        migration.baseline = nil
        let original = URL(fileURLWithPath: migration.originalPath)
        migration.backupPath = original.deletingLastPathComponent()
            .appendingPathComponent(".appports-migration-backup-\(original.lastPathComponent)-\(migration.operationID)").path
        let group = DataTransferGroup(transfer: migration)
        #expect(group.unlockTransfer == migration)
        #expect(group.state == .needsAttention)
        #expect(group.retainedCopies.isEmpty)
        #expect(group.resumeTransfer == migration)
    }

    @Test("A verified switch can resume only with completed ancestors and its original mount description")
    func resumeEligibility() throws {
        var migration = record(direction: .migrate)
        migration.phase = .needsRecovery
        migration.recoverableReason = "Interrupted"
        #expect(DataTransferGroup(transfer: migration).resumeTransfer == migration)
        var restoration = record(direction: .restore, prior: migration.operationID)
        restoration.phase = .needsRecovery
        restoration.recoverableReason = "Interrupted"
        #expect(try #require(DataTransferGroup.groups(from: [migration, restoration]).first).resumeTransfer == nil)
        var mount = record(direction: .migrate, mode: .mount)
        mount.phase = .needsRecovery
        mount.recoverableReason = "Interrupted"
        #expect(DataTransferGroup(transfer: mount).resumeTransfer == nil)
        mount.recoveryMountRecord = ContainerMountRecord(appName: mount.appName, bundleIdentifier: mount.bundleIdentifier,
            dataDirType: mount.dataDirType, mountPointPath: mount.originalPath,
            volumeUUID: "SYNTHETIC-VOLUME", volumeName: "Synthetic", externalRootPath: "/Volumes/Archive")
        #expect(DataTransferGroup(transfer: mount).resumeTransfer == mount)
    }

    @Test("An external copy after successful restore is not offered as data waiting to relink")
    func customDirectoryRetainedCopy() {
        let migration = record(direction: .migrate)
        let restoration = record(direction: .restore, prior: migration.operationID)
        let config = CustomDirConfig(localPath: restoration.originalPath,
                                     externalBasePath: "/Volumes/Archive/Application Support")
        #expect(CustomDirRecoveryEligibility.isRetainedExternalCopy(config: config,
            groups: DataTransferGroup.groups(from: [migration, restoration])))
        #expect(!CustomDirRecoveryEligibility.isRetainedExternalCopy(config: config,
            groups: DataTransferGroup.groups(from: [migration])))
        var incomplete = restoration
        incomplete.phase = .needsRecovery
        #expect(!CustomDirRecoveryEligibility.isRetainedExternalCopy(config: config,
            groups: DataTransferGroup.groups(from: [migration, incomplete])))
        let other = CustomDirConfig(localPath: restoration.originalPath,
                                    externalBasePath: "/Volumes/Other/Application Support")
        #expect(!CustomDirRecoveryEligibility.isRetainedExternalCopy(config: other,
            groups: DataTransferGroup.groups(from: [migration, restoration])))
    }

    private func record(direction: DataTransferRecord.Direction, mode: DataTransferRecord.Mode = .symlink,
                        prior: UUID? = nil, createdAt: Date = Date()) -> DataTransferRecord {
        let local = "/SyntheticHome/Library/Application Support/Account"
        let external = "/Volumes/Archive/Application Support/Account"
        let identity = DataPathIdentity(device: 1, inode: 2, volumeUUID: "SYNTHETIC-VOLUME")
        return DataTransferRecord(mode: mode, direction: direction, appName: "Synthetic",
            dataDirType: DataDirType.applicationSupport.rawValue,
            originalPath: local, activePath: direction == .restore ? local : external,
            destinationPath: direction == .restore ? local : external,
            backupPath: direction == .restore ? external : "/SyntheticHome/Library/Application Support/.appports-migration-backup-Account",
            sourceIdentity: identity, destinationIdentity: identity, backupIdentity: identity,
            priorOperationID: prior, createdAt: createdAt, phase: .awaitingUserVerification, baseline: Data([1]))
    }
}
