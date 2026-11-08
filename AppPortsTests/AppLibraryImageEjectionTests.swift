import Foundation
import Testing
@testable import AppPorts

private actor ImageEjectionRunner: ShellCommandRunning {
    let imagePath: String
    let uuid: String
    let pauses: DiskEjectionPauseStore
    let busy: Bool
    var attached = true
    private(set) var detached = false

    init(record: AppLibraryImageService.Record, pauses: DiskEjectionPauseStore, busy: Bool = false) {
        imagePath = record.imagePath
        uuid = record.volumeUUID!
        self.pauses = pauses
        self.busy = busy
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        let value: [String: Any]
        if executable == "/usr/bin/hdiutil", arguments == ["info", "-plist"] {
            value = ["images": attached ? [["image-path": imagePath, "system-entities": [
                ["dev-entry": "/dev/disk90"],
                ["dev-entry": "/dev/disk91s1", "mount-point": "/Volumes/Library"],
                ["dev-entry": "/dev/disk91s2", "mount-point": "/fixture/AppData"]
            ]]] : []]
        } else if executable == "/usr/sbin/diskutil", arguments.starts(with: ["info", "-plist"]) {
            if arguments.last == "/dev/disk90" {
                value = ["DeviceIdentifier": "disk90"]
            } else {
                value = ["FilesystemType": "apfs", "WritableVolume": true,
                    "VolumeUUID": arguments.last == "/dev/disk91s1" ? uuid : "F047582E-E7B1-4D37-9709-2B0FC083AA26",
                    "MountPoint": arguments.last == "/dev/disk91s1" ? "/Volumes/Library" : "/fixture/AppData"]
            }
        } else if executable == "/usr/bin/hdiutil", arguments == ["detach", "/dev/disk90"] {
            #expect(try pauses.snapshot().blocks(volumeUUIDs: [uuid]))
            #expect(try pauses.snapshot().blocks(paths: ["/fixture/AppData/database"]))
            if busy {
                return ShellCommandResult(status: 1, standardOutput: Data(),
                    standardError: Data("Resource busy".utf8), timedOut: false)
            }
            attached = false
            detached = true
            value = [:]
        } else {
            Issue.record("Unexpected command: \(executable) \(arguments)")
            throw CocoaError(.featureUnsupported)
        }
        return ShellCommandResult(status: 0,
            standardOutput: try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0),
            standardError: Data(), timedOut: false)
    }
}

struct AppLibraryImageEjectionTests {
    @Test(arguments: ["/fixture/NAS/Apps.sparsebundle", "/fixture/USB/Apps.sparsebundle"])
    func imageEjectionBypassesPhysicalDiskInventory(_ path: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("container-mounts.plist"))
        let pauses = DiskEjectionPauseStore(store: store)
        let record = image(path)
        let runner = ImageEjectionRunner(record: record, pauses: pauses)
        let service = DiskEjectionService(store: store,
            inventory: { Issue.record("Images must not require a physical disk"); throw DiskEjectionError.unavailable },
            requestFinderEject: { _ in Issue.record("Backing disk/share must not be ejected") },
            selectedImage: { record }, imageService: AppLibraryImageService(runner: runner))
        try await service.request(at: URL(fileURLWithPath: "/Volumes/Library"))
        #expect(await runner.detached)
        let saved = try pauses.snapshot()
        #expect(saved.pauses.isEmpty)
        #expect(saved.blocksImage(record))
        #expect(!saved.blocks(paths: ["/fixture/NAS/Other.sparsebundle", "/fixture/USB/Other.app"]))
    }

    @Test func busyImageRetainsPauseAndNeverForcesDetach() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pauses = DiskEjectionPauseStore(directory: root)
        let record = image("/fixture/NAS/Apps.sparsebundle")
        let runner = ImageEjectionRunner(record: record, pauses: pauses, busy: true)
        do {
            try await AppLibraryImageService(runner: runner).unmount(record, pauses: pauses)
            Issue.record("A busy image must report failure")
        } catch {
            #expect(error.localizedDescription.contains("Resource busy"))
        }
        #expect(await runner.attached)
        #expect(try pauses.snapshot().blocksImage(record))
    }

    @Test func hostReconnectDoesNotResumeImageAndPhysicalPauseIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pauses = DiskEjectionPauseStore(directory: root)
        let record = image("/fixture/USB/Apps.sparsebundle")
        try pauses.pauseImage(record, volumeUUIDs: [], mountPaths: [])
        let disk = DiskEjectionTests.media()
        _ = try pauses.pause(disk)
        let saved = try pauses.reconcile(.init(disks: [DiskEjectionTests.media(connection: "boot:2")]))
        #expect(saved.pauses.isEmpty)
        #expect(saved.blocksImage(record))
        _ = try pauses.pause(disk)
        try pauses.resumeImage(record)
        #expect(try pauses.snapshot().images.isEmpty)
        #expect(try pauses.snapshot().pauses.count == 1)
    }

    @Test func pausedImageSkipsBackgroundAndPortalRecovery() async throws {
        let suite = "ImageEjection-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pauses = DiskEjectionPauseStore(directory: root)
        let record = image("/fixture/NAS/Apps.sparsebundle")
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        defaults.set(record.mountPath, forKey: "ExternalDrivePath")
        try pauses.pauseImage(record, volumeUUIDs: [], mountPaths: [])
        let service = AppLibraryImageService(files: AppLibraryImageFileAccess(inspect: { _ in
            Issue.record("Paused image must not probe or reconnect backing storage")
            throw CocoaError(.featureUnsupported)
        }))
        let snapshot = try pauses.snapshot()
        #expect(try await !AppLibraryImageRecovery.isMountedForLaunch(record, service: service, ejection: snapshot))
        await AppLibraryImageRecovery.recoverSelected(defaults: defaults, service: service, ejection: snapshot)
        do {
            _ = try await AppLibraryImageRecovery.restoreForLaunch(record, service: service, ejection: snapshot)
            Issue.record("Launching a portal must respect manual unmount")
        } catch ManualMountPauseError.retryPaused { }
    }

    private func image(_ path: String) -> AppLibraryImageService.Record {
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: path))
        record.volumeUUID = "EA5A45C7-E35A-458D-830F-090D74C68888"
        record.mountPath = "/Volumes/Library"
        record.libraryPath = record.mountPath
        return record
    }
}
