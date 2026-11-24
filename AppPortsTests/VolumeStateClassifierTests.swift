import Darwin
import Foundation
import Testing
@testable import AppPorts

struct VolumeStateClassifierTests {
    private let identity = DataPathIdentity(device: 1, inode: 42, volumeUUID: "LOCAL")

    @Test("Mounted restore sources are available, while a foreign occupant is always unknown")
    func mountedRestoreAndForeignVolume() {
        var record = transfer(.restore)
        let identity = identity
        let classifier = VolumeStateClassifier(observe: { _ in .directory(identity) })
        let mounted = VolumeStateClassifier.Snapshot(volumes: ["LOCAL": .init(uuid: "LOCAL", name: "AppPorts-test", mountPoint: record.originalPath, locked: false)])
        #expect(classifier.classify(record, snapshot: mounted).residue == .entryAvailable)
        record.rollbackCompletedAt = Date()
        #expect(classifier.classify(record, snapshot: mounted).state == .rolledBack)
        let foreign = VolumeStateClassifier.Snapshot(volumes: [
            "LOCAL": .init(uuid: "LOCAL", name: "AppPorts-test", mountPoint: nil, locked: true),
            "FOREIGN": .init(uuid: "FOREIGN", name: "Other", mountPoint: record.originalPath, locked: false)
        ])
        #expect(classifier.classify(record, snapshot: foreign).state == .unreadable)
        let mount = ContainerMountRecord(appName: "Fixture", bundleIdentifier: nil, dataDirType: "fixture",
            mountPointPath: record.originalPath, volumeUUID: "LOCAL", volumeName: "AppPorts-test", externalRootPath: "/external")
        let records = ContainerMountStore.Inspection(mounts: [mount], cleanups: [], transfers: [], managedLinks: [],
            remountInterventions: [:], preservedMaterials: [], validationError: nil)
        #expect(classifier.inventory(records, snapshot: foreign).findings.first?.state == .unreadable)
    }

    @Test("Failed diagnostic queries expose no raw disk names and run once with a short timeout")
    func diagnosticQueryIsBounded() async throws {
        let runner = PrivateInventoryRunner()
        do {
            _ = try await DiskUtility(runner: runner).volumeStateSnapshot()
            Issue.record("Expected query failure")
        } catch {
            #expect(!String(describing: error).contains("PrivateVolumeName"))
            #expect(!error.localizedDescription.contains("PrivateVolumeName"))
        }
        #expect(await runner.calls == 1)
    }

    private actor PrivateInventoryRunner: ShellCommandRunning {
        var calls = 0
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            calls += 1
            #expect(arguments == ["apfs", "list", "-plist"])
            #expect(timeout <= 5)
            return .init(status: 1, standardOutput: Data("PrivateVolumeName".utf8), standardError: Data(), timedOut: false)
        }
    }

    private func transfer(_ direction: DataTransferRecord.Direction = .migrate) -> DataTransferRecord {
        DataTransferRecord(mode: .mount, direction: direction, appName: "Fixture", dataDirType: "fixture",
            originalPath: "/Fixture/data", activePath: "/Fixture/data", destinationPath: "/Fixture/stage",
            sourceIdentity: identity, destinationIdentity: DataPathIdentity(device: 2, inode: 99, volumeUUID: "EXTERNAL"),
            createdVolumeUUID: "EXTERNAL")
    }

    @Test("Every unswitched phase requires a proven usable entry for E1", arguments: DataTransferRecord.Phase.allCases)
    func noUnprovenEntryAvailable(_ phase: DataTransferRecord.Phase) {
        var record = transfer()
        record.phase = phase
        guard !record.isDataSwitchComplete else { return }
        let states: [VolumeStateClassifier.PathState] = [.missing, .placeholder, .other, .unreadable,
            .directory(.init(device: 1, inode: 43, volumeUUID: "LOCAL"))]
        for state in states {
            let classifier = VolumeStateClassifier(observe: { _ in state })
            let finding = classifier.classify(record, snapshot: .init(volumes: [:]))
            #expect(finding.residue != .entryAvailable)
            #expect(finding.state == .unreadable || finding.residue == .awaitingRecovery)
        }
        let identity = identity
        let available = VolumeStateClassifier(observe: { _ in .directory(identity) })
        #expect(available.classify(record, snapshot: .init(volumes: [:])).residue == .entryAvailable)
    }

    @Test("Incomplete APFS queries never report a vanished volume", arguments: DataTransferRecord.Phase.allCases)
    func queryFailureIsUnknown(_ phase: DataTransferRecord.Phase) {
        var record = transfer()
        record.phase = phase
        #expect(VolumeStateClassifier().classify(record, snapshot: .init(volumes: [:], complete: false)).state == .unreadable)
    }

    @Test("Encrypted volumes wait for unlock, committed restore requires its destination inode")
    func encryptionAndRestoreIdentity() {
        var record = transfer()
        let locked = VolumeStateClassifier.Snapshot(volumes: ["EXTERNAL": .init(uuid: "EXTERNAL", name: "AppPorts-test", mountPoint: nil, locked: true)])
        #expect(VolumeStateClassifier().classify(record, snapshot: locked).detail == "waiting_for_unlock")
        record = transfer(.restore)
        record.phase = .cleanupRequested
        let identity = identity
        #expect(VolumeStateClassifier(observe: { _ in .directory(identity) }).classify(record, snapshot: .init(volumes: [:])).state == .unreadable)
        let destination = record.destinationIdentity!
        #expect(VolumeStateClassifier(observe: { _ in .directory(destination) }).classify(record, snapshot: .init(volumes: [:])).state == .pendingCleanup)
    }

    @Test("Inventory covers active mounts, legacy cleanups, preserved material and orphans")
    func inventoryCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VolumeInventory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mount = ContainerMountRecord(appName: "Fixture", bundleIdentifier: nil, dataDirType: "fixture",
            mountPointPath: "/Fixture/data", volumeUUID: "EXTERNAL", volumeName: "AppPorts-test", externalRootPath: "/Fixture/external")
        let cleanup = ContainerCleanupRecord(kind: .migrationBackup, mountRecord: mount, localPath: "/Fixture/backup")
        let material = DataTransferMaterial(transfer: transfer(), reason: "preserved")
        let records = ContainerMountStore.Inspection(mounts: [mount], cleanups: [cleanup], transfers: [],
            managedLinks: [], remountInterventions: [:], preservedMaterials: [material], validationError: nil)
        let snapshot = VolumeStateClassifier.Snapshot(volumes: [
            "EXTERNAL": .init(uuid: "EXTERNAL", name: "AppPorts-test", mountPoint: "/Fixture/data", locked: false),
            "ORPHAN": .init(uuid: "ORPHAN", name: "AppPorts-orphan", mountPoint: "/Fixture/orphan", locked: false),
            "UNKNOWN": .init(uuid: "UNKNOWN", name: "AppPorts-unknown", mountPoint: nil, locked: false)
        ])
        let identity = identity
        let classifier = VolumeStateClassifier(observe: { _ in .directory(identity) }, markerMatches: { _, id in id == "ORPHAN" })
        let result = classifier.inventory(records, snapshot: snapshot)
        #expect(result.findings.count == 5)
        #expect(result.counts[.normal] == 1)
        #expect(result.counts[.legacyBackup] == 1)
        #expect(result.counts[.orphanIdentified] == 1)
        #expect(result.counts[.orphanUnidentified] == 1)
        let section = VolumeStateReporting.diagnosticSection(result).joined(separator: "\n")
        #expect(section.contains("total: 5"))
        #expect(!section.contains("/Fixture"))
        #expect(VolumeStateReporting.diagnosticSection(nil).contains("  state: not_scanned"))
    }

    @Test("Diagnostic parser uses kernel mounts and rejects incomplete inventories")
    func parsesOneSnapshot() throws {
        let volume: [String: Any] = ["APFSVolumeUUID": "external", "DeviceIdentifier": "disk7s1", "Name": "AppPorts-test", "MountPoint": "/wrong", "Locked": true]
        let result = try DiskUtility.parseVolumeStateSnapshot(["Containers": [["Volumes": [volume]]]], mounts: ["/dev/disk7s1": "/actual"])
        #expect(result.volumes["EXTERNAL"]?.mountPoint == "/actual")
        #expect(result.volumes["EXTERNAL"]?.locked == true)
        for invalid: [String: Any] in [[:], ["Containers": [[:]]], ["Containers": [["Volumes": [[:]]]]]] {
            #expect(throws: (any Error).self) { try DiskUtility.parseVolumeStateSnapshot(invalid, mounts: [:]) }
        }
    }

    @Test("Duplicate image UUIDs affect only matching UUIDs and mount paths")
    func reportsOnlyAffectedVolumesAsAmbiguous() throws {
        let record = transfer()
        let volumes = [
            ["APFSVolumeUUID": "EXTERNAL", "DeviceIdentifier": "disk7s1", "Name": "AppPorts-test"],
            ["APFSVolumeUUID": "IMAGE", "DeviceIdentifier": "disk11s1", "Name": "MetalToolchainCryptex"],
            ["APFSVolumeUUID": "image", "DeviceIdentifier": "disk13s1", "Name": "MetalToolchainCryptex"]
        ]
        let inventory: [String: Any] = ["Containers": volumes.map { ["Volumes": [$0]] }]
        let snapshot = try DiskUtility.parseVolumeStateSnapshot(inventory, mounts: ["/dev/disk7s1": "/unrelated/volume"])
        #expect(snapshot.complete)
        #expect(snapshot.volumes["EXTERNAL"]?.mountPoint == "/unrelated/volume")
        #expect(snapshot.volumes["IMAGE"] == nil)
        #expect(snapshot.ambiguousVolumes["IMAGE"]?.count == 2)

        let identity = identity
        let classifier = VolumeStateClassifier(observe: { _ in .directory(identity) })
        #expect(classifier.classify(record, snapshot: snapshot).residue == .entryAvailable)
        var ambiguousRecord = record
        ambiguousRecord.createdVolumeUUID = "IMAGE"
        #expect(classifier.classify(ambiguousRecord, snapshot: snapshot).detail == "ambiguous_volume")

        let occupied = try DiskUtility.parseVolumeStateSnapshot(inventory, mounts: ["/dev/disk11s1": record.originalPath])
        #expect(classifier.classify(record, snapshot: occupied).state == .unreadable)
    }

    @Test("Real path probes distinguish missing, unreadable placeholders, and symlinks")
    func pathProbe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VolumeProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        if case .directory = VolumePathProbe.observe(root) {} else { Issue.record("Expected readable directory") }
        let missing = root.appendingPathComponent("missing")
        if case .missing = VolumePathProbe.observe(missing) {} else { Issue.record("Expected missing") }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        if case .other = VolumePathProbe.observe(link) {} else { Issue.record("Link must not be followed") }
        #expect(chmod(root.path, 0) == 0)
        if case .placeholder = VolumePathProbe.observe(root) {} else { Issue.record("Expected placeholder") }
        #expect(!VolumePathProbe.isReadableDirectory(root))
    }
}
