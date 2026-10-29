import Foundation
import Testing
@testable import AppPorts

private actor ImageCreationRunner: ShellCommandRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }
    let modern: Bool
    let creationFails: Bool
    private(set) var calls: [Call] = []

    init(modern: Bool, creationFails: Bool = false) {
        self.modern = modern
        self.creationFails = creationFails
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        calls.append(Call(executable: executable, arguments: arguments))
        let help = arguments.last == "--help"
        let failed = help ? !modern : creationFails
        return ShellCommandResult(status: failed ? 1 : 0,
            standardOutput: Data((help && modern ? "--format UDSB --size --volumeName" : "").utf8),
            standardError: Data((!help && creationFails ? "create failed - RPC version mismatch" : "").utf8),
            timedOut: false)
    }
}

private struct MountedImageRunner: ShellCommandRunning {
    let image: URL
    let uuid: String
    let writable: Bool?
    let point = "/Volumes/AppPorts-Fixture"

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        let value: [String: Any]
        if executable == "/usr/bin/hdiutil", arguments == ["info", "-plist"] {
            value = ["images": [["image-path": image.path, "system-entities": [
                ["dev-entry": "/dev/disk99s1", "mount-point": point]]]]]
        } else if executable == "/usr/sbin/diskutil", arguments == ["info", "-plist", "/dev/disk99s1"] {
            var info: [String: Any] = ["FilesystemType": "apfs", "MountPoint": point, "VolumeUUID": uuid]
            if let writable { info["WritableVolume"] = writable }
            value = info
        } else {
            Issue.record("An already attached image must not be attached again")
            throw CocoaError(.featureUnsupported)
        }
        return ShellCommandResult(status: 0,
            standardOutput: try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0),
            standardError: Data(), timedOut: false)
    }
}

struct AppLibraryImageTests {
    @Test(arguments: [true, false, nil] as [Bool?])
    func verifiesMountedImageUsingActualDiskutilWritabilityField(writable: Bool?) async throws {
        let image = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString + ".sparsebundle")
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: image) }
        let uuid = UUID().uuidString
        let runner = MountedImageRunner(image: image, uuid: uuid, writable: writable)
        let service = AppLibraryImageService(runner: runner, mountedUUID: { _ in uuid })
        let record = AppLibraryImageService.Record(imageURL: image)
        do {
            let result = try await service.mount(record)
            #expect(writable == true)
            #expect(result.record.volumeUUID == uuid)
            #expect(result.libraryURL.path == runner.point)
        } catch {
            #expect(writable != true)
        }
    }

    @Test func writableImageStillRejectsAReplacedVolume() async throws {
        let image = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString + ".sparsebundle")
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: image) }
        let uuid = UUID().uuidString
        let runner = MountedImageRunner(image: image, uuid: uuid, writable: true)
        let service = AppLibraryImageService(runner: runner, mountedUUID: { _ in uuid })
        var record = AppLibraryImageService.Record(imageURL: image)
        record.volumeUUID = UUID().uuidString
        await #expect(throws: (any Error).self) { try await service.mount(record) }
    }

    @Test func createsSparsebundleThroughModernBackendWithExactByteCapacity() async throws {
        let runner = ImageCreationRunner(modern: true)
        let service = AppLibraryImageService(runner: runner)
        try await service.createImage(at: URL(fileURLWithPath: "/fixture/NAS/My Disk.sparsebundle"),
            name: "My Disk", capacityGiB: 10)
        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls.last?.executable == "/usr/sbin/diskutil")
        #expect(calls.last?.arguments == ["image", "create", "blank", "--plist", "--format", "UDSB",
            "--size", "10737418240", "--fs", "APFS", "--volumeName", "My Disk", "/fixture/NAS/My Disk.sparsebundle"])
    }

    @Test func oldSystemsUseLegacyCreationWithoutOverwrite() async throws {
        let runner = ImageCreationRunner(modern: false)
        let service = AppLibraryImageService(runner: runner)
        try await service.createImage(at: URL(fileURLWithPath: "/fixture/NAS/Apps.sparsebundle"),
            name: "Apps", capacityGiB: 10)
        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls.last?.executable == "/usr/bin/hdiutil")
        #expect(calls.last?.arguments.contains("-ov") == false)
    }

    @Test func failedModernCreationDoesNotRetryAnotherBackendAndPreservesActualError() async {
        let runner = ImageCreationRunner(modern: true, creationFails: true)
        let service = AppLibraryImageService(runner: runner)
        do {
            try await service.createImage(at: URL(fileURLWithPath: "/fixture/NAS/Apps.sparsebundle"),
                name: "Apps", capacityGiB: 10)
            Issue.record("Creation should fail")
        } catch {
            #expect(error.localizedDescription.contains("RPC version mismatch"))
        }
        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.executable == "/usr/sbin/diskutil" })
    }

    private func inventory(_ images: [[String: Any]]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .binary, options: 0)
    }

    @Test func detachedImageDoesNotAdoptAnotherImageWithTheSameName() throws {
        let data = try inventory([["image-path": "/Volumes/Other/AppPorts.sparsebundle",
            "system-entities": [["dev-entry": "/dev/disk9s1", "mount-point": "/Volumes/AppPorts"]]]])
        #expect(try AppLibraryImageService.attachedVolumes(data: data,
            image: URL(fileURLWithPath: "/Volumes/NAS/AppPorts.sparsebundle")) == nil)
    }

    @Test func ambiguousAttachmentsAreRejected() throws {
        let path = "/Volumes/NAS/AppPorts.sparsebundle"
        let data = try inventory([["image-path": path], ["image-path": path]])
        #expect(throws: (any Error).self) {
            try AppLibraryImageService.attachedVolumes(data: data, image: URL(fileURLWithPath: path))
        }
    }

    @Test func unmountedAttachmentIsNotTreatedAsDetached() throws {
        let path = "/Volumes/NAS/AppPorts.sparsebundle"
        let data = try inventory([["image-path": path,
            "system-entities": [["dev-entry": "/dev/disk9"]]]])
        let entries = try AppLibraryImageService.attachedVolumes(data: data, image: URL(fileURLWithPath: path))
        #expect(entries != nil)
        #expect(entries?.isEmpty == true)
    }

    @Test func onlyTheSelectedImagesMountedDevicesAreReturned() throws {
        let path = "/Volumes/NAS/AppPorts.sparsebundle"
        let data = try inventory([
            ["image-path": "/Volumes/NAS/Other.sparsebundle", "system-entities": [
                ["dev-entry": "/dev/disk8s1", "mount-point": "/Volumes/Other"]]],
            ["image-path": path, "system-entities": [
                ["dev-entry": "/dev/disk9"],
                ["dev-entry": "/dev/disk10s1", "mount-point": "/Volumes/AppPorts"]]],
        ])
        #expect(try AppLibraryImageService.attachedVolumes(data: data, image: URL(fileURLWithPath: path))
            == [["device": "/dev/disk10s1", "mount": "/Volumes/AppPorts"]])
    }

    @Test(arguments: ["", ".", "..", "../Apps", "Apps/Other", "Apps:Other", " Apps", "Apps\nOther", "Apps\0Other"])
    func rejectsNamesThatCannotIdentifyOneImage(name: String) {
        #expect(throws: (any Error).self) { try AppLibraryImageService.validate(name: name, capacityGiB: 256) }
    }

    @Test(arguments: [0, -1, 65537, Int.max])
    func rejectsInvalidCapacity(size: Int) {
        #expect(throws: (any Error).self) { try AppLibraryImageService.validate(name: "AppPorts", capacityGiB: size) }
    }
}
