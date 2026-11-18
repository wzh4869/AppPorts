import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DiskEjectionTests {
    static let main = "EBDC9D56-CE50-4DB8-9013-A41D182DBC11"
    static let data = "9C35A76E-DB4B-47D6-BC7A-27C2FA6A057C"
    static func media(connection: String = "boot:1", device: String = "disk6") -> ExternalDiskInventory.Disk {
        .init(deviceIdentifier: device, connectionID: connection, displayName: "USB",
            volumeUUIDs: [main, data], containerUUIDs: ["CONTAINER"], mountPaths: ["/Volumes/USB", "/tmp/container"], deviceIdentifiers: [device, "disk7"])
    }

    @Test("Pause survives a separate reader and only affects the intended disk")
    func durableScope() throws {
        let f = try Fixture(); defer { f.remove() }
        let saved = try f.pauses.pause(Self.media())
        let read = try DiskEjectionPauseStore(directory: f.root).snapshot()
        #expect(read.pauses == [saved])
        #expect(read.blocks(volumeUUIDs: [Self.data.lowercased()]))
        #expect(read.blocks(paths: ["/Volumes/USB/Apps/Example.app"]))
        #expect(!read.blocks(paths: ["/Volumes/USB2/Apps/Example.app"]))
        #expect(!read.blocks(volumeUUIDs: ["OTHER"], paths: ["/Volumes/Other/Example.app"]))
        #expect(read.blocks(containerUUID: "container"))
    }

    @Test("Missing media, diskN changes and mount notifications do not resume a pause")
    func connectionIdentity() throws {
        let f = try Fixture(); defer { f.remove() }
        let pause = try f.pauses.pause(Self.media())
        #expect(try f.pauses.reconcile(.init(disks: [])).pauses == [pause])
        #expect(try f.pauses.reconcile(.init(disks: [Self.media(device: "disk42")])).pauses == [pause])
        #expect(try f.pauses.reconcile(.init(disks: [Self.media(connection: "boot:2", device: "disk42")])).pauses.isEmpty)
    }

    @Test("Reconnecting one disk removes only its pause")
    func independentReconnection() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.pauses.pause(Self.media())
        let other = ExternalDiskInventory.Disk(deviceIdentifier: "disk8", connectionID: "boot:8", displayName: "Other",
            volumeUUIDs: ["OTHER"], containerUUIDs: [], mountPaths: ["/Volumes/Other"])
        let second = try f.pauses.pause(other)
        _ = try f.pauses.reconcile(.init(disks: [Self.media(connection: "boot:2"), other]))
        #expect(try f.pauses.snapshot().pauses == [second])
    }

    @Test("A contended first UI refresh remains retryable until persisted pause status is loaded")
    @MainActor
    func refreshAfterContention() async throws {
        let f = try Fixture(); defer { f.remove() }
        let pause = try f.pauses.pause(Self.media())
        let controller = DiskEjectionController(service: DiskEjectionService(disk: f.disk, store: f.store))
        let lock = OperationLock(fileURL: f.root.appendingPathComponent("operation.lock"))
        #expect(lock.tryAcquire())
        await controller.refresh()
        #expect(controller.needsRefresh)
        lock.release()
        await controller.refresh()
        #expect(!controller.needsRefresh)
        #expect(controller.pauses == [pause])
    }

    @Test("Saved pause stays visible when disk inventory is unavailable")
    @MainActor
    func refreshWithUnavailableInventory() async throws {
        let f = try Fixture(); defer { f.remove() }
        let pause = try f.pauses.pause(Self.media())
        let service = DiskEjectionService(disk: f.disk, store: f.store,
            inventory: { throw DiskEjectionError.unavailable })
        let controller = DiskEjectionController(service: service)
        await controller.refresh()
        #expect(controller.pauses == [pause])
        #expect(controller.connected.isEmpty)
        #expect(controller.needsRefresh)
        #expect(try f.pauses.snapshot().pauses == [pause])
    }

    @Test("Physical observation distinguishes an online disk, offline media, and an unknown query", arguments: [PhysicalDiskState.online, .offline, .unknown])
    @MainActor
    func independentPhysicalObservation(_ state: PhysicalDiskState) async throws {
        let f = try Fixture(); defer { f.remove() }
        let pause = try f.pauses.pause(Self.media())
        // An absent eligible APFS disk is not proof that physical media vanished.
        let service = DiskEjectionService(disk: f.disk, store: f.store,
            inventory: { .init(disks: []) }, physicalState: { _ in state })
        let controller = DiskEjectionController(service: service)
        await controller.refresh()
        #expect(controller.state(for: pause) == (state == .online ? .unknown : state))
        #expect(controller.needsRefresh == (state != .offline))
        #expect(try f.pauses.snapshot().pauses == [pause])
        #expect(!controller.offersInitialEjection(at: URL(fileURLWithPath: "/Volumes/USB")))
        #expect(controller.offersInitialEjection(at: URL(fileURLWithPath: "/Volumes/Other")))
        #expect(!controller.offersInitialEjection(at: nil))
    }

    @Test("A returned Finder request and a cancelled or pending native dialog do not prove ejection")
    @MainActor
    func acceptedRequestRemainsOnline() async throws {
        let f = try Fixture(); defer { f.remove() }
        let service = DiskEjectionService(disk: f.disk, store: f.store,
            physicalState: { _ in .online }, mountedDevices: { ["/dev/disk7s1"] }, requestFinderEject: { _ in })
        try await service.request(at: URL(fileURLWithPath: "/Volumes/USB"))
        let pause = try #require(try f.pauses.snapshot().pauses.first)
        let controller = DiskEjectionController(service: service)
        await controller.refresh()
        #expect(controller.state(for: pause) == .online)
        #expect(!controller.offersInitialEjection(at: URL(fileURLWithPath: "/Volumes/USB/Apps")))
        #expect(try f.pauses.snapshot().pauses == [pause])
    }

    @Test("Physical state remains observable while another process holds the operation lock")
    @MainActor
    func observationDuringOperation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let pause = try f.pauses.pause(Self.media())
        let service = DiskEjectionService(disk: f.disk, store: f.store,
            inventory: { Issue.record("A busy observation must not query or reconcile inventory"); throw DiskEjectionError.busy },
            physicalState: { _ in .offline })
        let lock = service.makeLock()
        #expect(lock.tryAcquire()); defer { lock.release() }
        let controller = DiskEjectionController(service: service)
        await controller.refresh()
        #expect(controller.state(for: pause) == .offline)
        #expect(controller.needsRefresh)
        #expect(try f.pauses.snapshot().pauses == [pause])
    }

    @Test("An unrelated disk at the old mount path keeps its own initial eject action")
    @MainActor
    func replacementMenuTarget() async throws {
        let f = try Fixture(); defer { f.remove() }
        let pause = try f.pauses.pause(Self.media())
        let replacement = ExternalDiskInventory.Disk(deviceIdentifier: "disk8", connectionID: "boot:8", displayName: "Replacement",
            volumeUUIDs: ["OTHER"], containerUUIDs: ["OTHER-CONTAINER"], mountPaths: ["/Volumes/USB"])
        let service = DiskEjectionService(disk: f.disk, store: f.store,
            inventory: { .init(disks: [replacement]) }, physicalState: { _ in .offline })
        let controller = DiskEjectionController(service: service)
        await controller.refresh()
        #expect(controller.state(for: pause) == .offline)
        #expect(controller.offersInitialEjection(at: URL(fileURLWithPath: "/Volumes/USB")))
        #expect(try f.pauses.snapshot().pauses == [pause])
    }

    @Test("Real reconnection clears the paused menu rather than leaving a stale retry action")
    @MainActor
    func reconnectedMenu() async throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.pauses.pause(Self.media())
        let reconnected = Self.media(connection: "boot:2")
        let service = DiskEjectionService(disk: f.disk, store: f.store,
            inventory: { .init(disks: [reconnected]) }, physicalState: { _ in .offline })
        let controller = DiskEjectionController(service: service)
        await controller.refresh()
        #expect(controller.pauses.isEmpty)
        #expect(controller.offersInitialEjection(at: URL(fileURLWithPath: "/Volumes/USB")))
    }

    @Test("A failed inventory cannot turn an unknown physical state into offline")
    @MainActor
    func failedObservationIsUnknown() async throws {
        let f = try Fixture(); defer { f.remove() }
        let pause = try f.pauses.pause(Self.media())
        let controller = DiskEjectionController(service: DiskEjectionService(disk: f.disk, store: f.store,
            inventory: { throw DiskEjectionError.unavailable }, physicalState: { _ in .unknown }))
        await controller.refresh()
        #expect(controller.state(for: pause) == .unknown)
        #expect(controller.pauses == [pause])
        #expect(controller.needsRefresh)
    }

    @Test("Unmounted volumes on a connected bridge no longer display a failed eject")
    @MainActor
    func unmountedBridge() async throws {
        let f = try Fixture(); defer { f.remove() }
        let pause = try f.pauses.pause(Self.media())
        var bridge = Self.media()
        bridge.mountPaths = []
        let inventory = ExternalDiskInventory(disks: [bridge])
        let service = DiskEjectionService(disk: f.disk, store: f.store,
            inventory: { inventory }, physicalState: { _ in .online }, mountedDevices: { ["/dev/disk3s5"] })
        let controller = DiskEjectionController(service: service)
        await controller.refresh()
        #expect(controller.state(for: pause) == .unmounted)
        #expect(controller.connected.contains(pause.connectionID))
        #expect(!controller.needsRefresh)
        #expect(!controller.offersInitialEjection(at: URL(fileURLWithPath: "/Volumes/USB")))
        #expect(try f.pauses.snapshot().pauses == [pause])
    }

    @Test("Failed kernel mount reads never prove that a connected bridge is unmounted")
    @MainActor
    func failedKernelMountRead() async throws {
        let f = try Fixture(); defer { f.remove() }
        let pause = try f.pauses.pause(Self.media())
        let controller = DiskEjectionController(service: DiskEjectionService(disk: f.disk, store: f.store,
            physicalState: { _ in .online }, mountedDevices: { throw DiskEjectionError.unavailable }))
        await controller.refresh()
        #expect(controller.state(for: pause) == .unknown)
        #expect(controller.needsRefresh)
        #expect(try f.pauses.snapshot().pauses == [pause])
    }

    @Test("New automatic signature backup destinations exclude paused volumes")
    func backupDestinationSelection() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.pauses.pause(Self.media())
        let volumes = [
            SignatureBackupStorage.Volume(url: URL(fileURLWithPath: "/Volumes/USB"), uuid: Self.main,
                availableBytes: 1000, isExternal: true, isLocal: true, isWritable: true),
            SignatureBackupStorage.Volume(url: URL(fileURLWithPath: "/Volumes/Other"), uuid: "OTHER",
                availableBytes: 1000, isExternal: true, isLocal: true, isWritable: true)
        ]
        let candidates = SignatureBackupStorage.candidates(volumes, applicationVolume: Self.main, knownVolume: Self.main,
            requiredBytes: 1, excluding: try f.pauses.snapshot())
        #expect(candidates.map(\.uuid) == ["OTHER"])
    }

    @Test("Malformed and symlinked pause documents fail closed")
    func invalidPauseState() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("corrupt".utf8).write(to: f.pauses.fileURL)
        #expect(throws: DiskEjectionError.self) { try f.pauses.snapshot() }
        try FileManager.default.removeItem(at: f.pauses.fileURL)
        let victim = f.root.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: f.pauses.fileURL, withDestinationURL: victim)
        #expect(throws: DiskEjectionError.self) { try f.pauses.snapshot() }
        #expect(try String(contentsOf: victim) == "keep")
    }

    @Test("Finder is called only after the pause is readable by a separate process-equivalent reader")
    func pauseBeforeDispatch() async throws {
        let f = try Fixture(); defer { f.remove() }
        let calls = Calls()
        let directory = f.root
        let service = DiskEjectionService(disk: f.disk, store: f.store, requestFinderEject: { url async throws in
            let snapshot = try DiskEjectionPauseStore(directory: directory).snapshot()
            #expect(snapshot.blocks(volumeUUIDs: [Self.data]))
            await calls.append(url.path)
        })
        try await service.request(at: URL(fileURLWithPath: "/Volumes/USB/Apps"))
        #expect(await calls.paths == ["/Volumes/USB"])
        #expect(try f.pauses.snapshot().pauses.count == 1)
    }

    @Test("Finder failure retains the pause so a partially unmounted disk is not remounted")
    func dispatchFailure() async throws {
        let f = try Fixture(); defer { f.remove() }
        let service = DiskEjectionService(disk: f.disk, store: f.store, requestFinderEject: { _ in throw DiskEjectionError.finder("denied") })
        await #expect(throws: DiskEjectionError.self) { try await service.request(at: URL(fileURLWithPath: "/Volumes/USB")) }
        #expect(try f.pauses.snapshot().blocks(volumeUUIDs: [Self.data]))
    }

    @Test("A replaced physical connection is rejected before sending Finder an eject event")
    func replacementDuringDispatch() async throws {
        let f = try Fixture(); defer { f.remove() }
        let sequence = Inventories([.init(disks: [Self.media()]), .init(disks: [Self.media(connection: "boot:2")])])
        let calls = Calls()
        let service = DiskEjectionService(disk: f.disk, store: f.store, inventory: { await sequence.next() },
            requestFinderEject: { await calls.append($0.path) })
        await #expect(throws: DiskEjectionError.self) { try await service.request(at: URL(fileURLWithPath: "/Volumes/USB")) }
        #expect(await calls.paths.isEmpty)
    }

    @Test("A held migration lock prevents ejection before a pause is published")
    func operationExclusion() async throws {
        let f = try Fixture(); defer { f.remove() }
        let lock = OperationLock(fileURL: f.root.appendingPathComponent("operation.lock"))
        #expect(lock.tryAcquire()); defer { lock.release() }
        let calls = Calls()
        let service = DiskEjectionService(disk: f.disk, store: f.store, requestFinderEject: { await calls.append($0.path) })
        await #expect(throws: DiskEjectionError.self) { try await service.request(at: URL(fileURLWithPath: "/Volumes/USB")) }
        #expect(try f.pauses.snapshot().pauses.isEmpty)
        #expect(await calls.paths.isEmpty)
    }

    @Test("A corrupt pause document cannot silently permit ejection")
    func noDispatchWithUnreadableState() async throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("bad".utf8).write(to: f.pauses.fileURL)
        let calls = Calls()
        let service = DiskEjectionService(disk: f.disk, store: f.store, requestFinderEject: { await calls.append($0.path) })
        await #expect(throws: DiskEjectionError.self) { try await service.request(at: URL(fileURLWithPath: "/Volumes/USB")) }
        #expect(await calls.paths.isEmpty)
    }

    @Test("Failure to durably publish a pause prevents the Finder request")
    func noDispatchAfterWriteFailure() async throws {
        let f = try Fixture(); defer { f.remove() }
        let lock = OperationLock(fileURL: f.root.appendingPathComponent("operation.lock"))
        #expect(lock.tryAcquire()); lock.release()
        #expect(chmod(f.root.path, 0o500) == 0)
        defer { _ = chmod(f.root.path, 0o700) }
        let calls = Calls()
        let service = DiskEjectionService(disk: f.disk, store: f.store, requestFinderEject: { await calls.append($0.path) })
        await #expect(throws: (any Error).self) { try await service.request(at: URL(fileURLWithPath: "/Volumes/USB")) }
        #expect(await calls.paths.isEmpty)
        #expect(try f.pauses.snapshot().pauses.isEmpty)
    }

    @Test("Production remount and bottom-level mount both honor the same pause")
    func remountGate() async throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.pauses.pause(Self.media())
        let record = ContainerMountRecord(appName: "Fixture", bundleIdentifier: nil, dataDirType: DataDirType.containers.rawValue,
            mountPointPath: f.root.appendingPathComponent("container").path, volumeUUID: Self.data,
            volumeName: "AppPorts-Fixture", externalRootPath: "/Volumes/USB")
        try f.store.upsert(record)
        let migrator = ContainerVolumeMigrator(disk: f.disk, store: f.store, synchronizeAgent: { _ in })
        let result = await migrator.remountAvailableRecords()
        #expect(result.count == 1)
        #expect(result.first?.state == .requiresIntervention(DiskEjectionError.paused.localizedDescription))
        #expect(ContainerRemountLoop.pendingRecords(in: result).isEmpty)
        await #expect(throws: DiskEjectionError.self) {
            try await migrator.mountVolume(Self.data, at: record.mountPointURL, operationID: "fixture")
        }
    }

    @Test("Inventory follows APFS physical stores rather than synthesized disk numbers")
    func apfsMapping() throws {
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk6", "Partitions": [["DeviceIdentifier": "disk6s2"]]],
            ["DeviceIdentifier": "disk99", "APFSPhysicalStores": [["DeviceIdentifier": "disk6s2"]],
             "APFSVolumes": [["VolumeUUID": Self.main, "MountPoint": "/Volumes/USB"]]]
        ]]
        let apfs: [String: Any] = ["Containers": [["APFSContainerUUID": "CONTAINER", "PhysicalStores": [["DeviceIdentifier": "disk6s2"]],
            "Volumes": [["APFSVolumeUUID": Self.main, "Name": "USB"], ["APFSVolumeUUID": Self.data, "Name": "AppPorts-Data"]]]]]
        let inventory = try ExternalDiskInventory.parse(list: list, apfs: apfs, connection: { $0 == "disk6" ? "boot:1" : nil })
        let found = try inventory.disk(volumeUUID: Self.data)
        #expect(found.deviceIdentifier == "disk6")
        #expect(found.volumeUUIDs == [Self.main, Self.data])
        #expect(found.mountPaths == ["/Volumes/USB"])
        #expect(throws: DiskEjectionError.self) { try ExternalDiskInventory(disks: []).disk(volumeUUID: Self.main) }
    }

    @Test("Shared EFI UUIDs on unrelated disks do not prevent physical reconnect recovery")
    func excludesEFIIdentity() throws {
        let f = try Fixture(); defer { f.remove() }
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk6", "Partitions": [
                ["DeviceIdentifier": "disk6s1", "Content": "EFI", "VolumeUUID": "SHARED-EFI"],
                ["DeviceIdentifier": "disk6s2", "Content": "Microsoft Basic Data", "VolumeUUID": Self.main]]],
            ["DeviceIdentifier": "disk8", "Partitions": [
                ["DeviceIdentifier": "disk8s1", "Content": "EFI", "VolumeUUID": "SHARED-EFI"],
                ["DeviceIdentifier": "disk8s2", "Content": "Microsoft Basic Data", "VolumeUUID": "OTHER"]]]
        ]]
        let initial = try ExternalDiskInventory.parse(list: list, apfs: ["Containers": []], connection: { "old:" + $0 })
        _ = try f.pauses.pause(initial.disk(volumeUUID: Self.main))
        #expect(initial.disks.allSatisfy { !$0.volumeUUIDs.contains("SHARED-EFI") })
        let reconnected = try ExternalDiskInventory.parse(list: list, apfs: ["Containers": []],
            connection: { ($0 == "disk6" ? "new:" : "old:") + $0 })
        #expect(try f.pauses.reconcile(reconnected).pauses.isEmpty)
    }

    @Test("Incomplete APFS device mappings remain unknown even when no known node is mounted", arguments: ["complete", "container", "volume", "omitted"])
    func incompleteMountMapping(_ missing: String) throws {
        let list: [String: Any] = ["AllDisksAndPartitions": [["DeviceIdentifier": "disk6", "Partitions": [
            ["DeviceIdentifier": "disk6s2", "Content": "Apple_APFS"],
            ["DeviceIdentifier": "disk6s3", "Content": "Microsoft Basic Data", "VolumeUUID": "BASE"]
        ]]]]
        var volume: [String: Any] = ["DeviceIdentifier": "disk99s1", "APFSVolumeUUID": Self.main]
        var container: [String: Any] = ["ContainerReference": "disk99", "APFSContainerUUID": "CONTAINER",
            "PhysicalStores": [["DeviceIdentifier": "disk6s2"]]]
        if missing == "container" { container.removeValue(forKey: "ContainerReference") }
        if missing == "volume" { volume.removeValue(forKey: "DeviceIdentifier") }
        container["Volumes"] = [volume]
        let apfs: [String: Any] = ["Containers": missing == "omitted" ? [] : [container]]
        let inventory = try ExternalDiskInventory.parse(list: list, apfs: apfs, connection: { _ in "boot:1" })
        let disk = try #require(inventory.disks.first)
        #expect(disk.mountMappingComplete == (missing == "complete"))
        #expect(PhysicalDiskState.observed(physical: .online, disk: disk, mountedDevices: [])
            == (missing == "complete" ? .unmounted : .unknown))
        #expect(PhysicalDiskState.observed(physical: .online, disk: disk, mountedDevices: ["/dev/disk99s1"])
            == (missing == "complete" ? .online : .unknown))
    }

    @Test("Every member of multi-device APFS storage is excluded, including mixed-partition members")
    func excludesMultiDeviceMembers() throws {
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk6", "Partitions": [["DeviceIdentifier": "disk6s1", "VolumeUUID": "BASE"], ["DeviceIdentifier": "disk6s2"]]],
            ["DeviceIdentifier": "disk8", "Partitions": [["DeviceIdentifier": "disk8s2"]]]
        ]]
        let apfs: [String: Any] = ["Containers": [["APFSContainerUUID": "SHARED", "PhysicalStores": [
            ["DeviceIdentifier": "disk6s2"], ["DeviceIdentifier": "disk8s2"]],
            "Volumes": [["APFSVolumeUUID": "SHARED-VOLUME"]]]]]
        let inventory = try ExternalDiskInventory.parse(list: list, apfs: apfs, connection: { "boot:" + $0 })
        #expect(inventory.disks.isEmpty)
    }

    @Test("Signature history and deletion matching uses saved volume identity after path changes")
    func signatureMaterialScope() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.pauses.pause(Self.media())
        let snapshot = try f.pauses.snapshot()
        let identity = DataPathIdentity(device: 1, inode: 2, volumeUUID: Self.data)
        let location = SignatureDirectoryLocation(path: "/Volumes/Renamed/Backups", volumeUUID: Self.data,
            relativePath: "Backups", identity: identity)
        let backup = SignatureBackup(bundleIdentifier: "fixture", signingIdentity: "developer", originalPath: "/Applications/Fixture.app",
            backupDate: Date(), snapshotLocation: location)
        #expect(snapshot.blocks(backup))
        let manifest = SignatureRemovalManifest(rootIdentity: identity, entries: [])
        let deletion = SignatureMaterialDeletion(id: UUID(), targetPath: "/Volumes/Renamed/Backups/Old.app", parentIdentity: identity,
            targetIdentity: identity, manifest: manifest, recordPath: nil, recordDigest: nil, moveToTrash: false)
        #expect(snapshot.blocks(deletion))
    }

    @Test("Subdirectory external library path resolves to mount point before diskutil info")
    func subdirectoryTargetResolvesToMountPoint() async throws {
        let f = try Fixture(); defer { f.remove() }
        let calls = Calls()
        let viaMount = DiskEjectionService(disk: f.disk, store: f.store,
            mountedVolumePath: { _ in "/Volumes/USB" },
            requestFinderEject: { await calls.append($0.path) })
        try await viaMount.request(at: URL(fileURLWithPath: "/Volumes/USB/Apps"))
        #expect(await calls.paths == ["/Volumes/USB"])

        let f2 = try Fixture(); defer { f2.remove() }
        let calls2 = Calls()
        let viaInventory = DiskEjectionService(disk: f2.disk, store: f2.store,
            mountedVolumePath: { _ in nil },
            requestFinderEject: { await calls2.append($0.path) })
        try await viaInventory.request(at: URL(fileURLWithPath: "/Volumes/USB/Apps"))
        #expect(await calls2.paths == ["/Volumes/USB"])

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["Error": true, "ErrorMessage": "Could not find disk: /Volumes/USB/Apps", "ExitCode": 1],
            format: .xml, options: 0
        )
        let failure = DiskUtility.Failure.commandFailed(command: "diskutil info -plist /Volumes/USB/Apps",
                                                        output: String(decoding: plistData, as: UTF8.self))
        let description = try #require(failure.errorDescription)
        #expect(description.contains("Could not find disk: /Volumes/USB/Apps"))
        #expect(!description.contains("<plist"))
    }

    private actor Calls {
        var paths: [String] = []
        func append(_ path: String) { paths.append(path) }
    }
    private actor Inventories {
        var values: [ExternalDiskInventory]
        init(_ values: [ExternalDiskInventory]) { self.values = values }
        func next() -> ExternalDiskInventory { values.removeFirst() }
    }
    private struct Fixture {
        let root: URL
        let store: ContainerMountStore
        var pauses: DiskEjectionPauseStore { .init(directory: root) }
        var disk: DiskUtility {
            DiskUtility(runner: InfoRunner(), ejectionInventory: { .init(disks: [DiskEjectionTests.media()]) }, administratorRunner: nil)
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskEjectionTests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = ContainerMountStore(fileURL: root.appendingPathComponent("container-mounts.plist"))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    private struct InfoRunner: ShellCommandRunning {
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            guard arguments.starts(with: ["info", "-plist"]), let target = arguments.last else {
                throw DiskEjectionError.unavailable
            }
            guard [DiskEjectionTests.main, DiskEjectionTests.data, "/Volumes/USB", "/tmp/container"].contains(target) else {
                let errorPlist: [String: Any] = [
                    "Error": true,
                    "ErrorMessage": "Could not find disk: \(target)",
                    "ExitCode": 1
                ]
                return ShellCommandResult(status: 1,
                    standardOutput: try PropertyListSerialization.data(fromPropertyList: errorPlist, format: .xml, options: 0),
                    standardError: Data(), timedOut: false)
            }
            let isData = target == DiskEjectionTests.data || target == "/tmp/container"
            let info: [String: Any] = ["DeviceIdentifier": isData ? "disk7s2" : "disk7s1",
                "VolumeUUID": isData ? DiskEjectionTests.data : DiskEjectionTests.main,
                "VolumeName": "USB", "FilesystemType": "apfs", "APFSContainerReference": "disk7",
                "MountPoint": isData ? "/tmp/container" : "/Volumes/USB"]
            return ShellCommandResult(status: 0, standardOutput: try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
                standardError: Data(), timedOut: false)
        }
    }
}
