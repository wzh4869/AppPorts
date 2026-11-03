import Foundation
import Testing
@testable import AppPorts

private actor RecoveryInspectionRunner: ShellCommandRunning {
    let attachedImage: String?
    private(set) var calls = 0

    init(attachedImage: String? = nil) { self.attachedImage = attachedImage }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        calls += 1
        #expect(executable == "/usr/bin/hdiutil")
        #expect(arguments == ["info", "-plist"])
        let images: [[String: Any]] = attachedImage.map { [["image-path": $0, "system-entities": []]] } ?? []
        return ShellCommandResult(status: 0,
            standardOutput: try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .binary, options: 0),
            standardError: Data(), timedOut: false)
    }
}

struct AppLibraryImageRecoveryTests {
    @Test func localImageFollowsVolumeUUIDAfterUSBMountPathChanges() throws {
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/Volumes/USB/Apps/Library.sparsebundle"))
        record.backingVolumeUUID = "VOLUME-USB"
        record.imageRelativePath = "Apps/Library.sparsebundle"
        let old = URL(fileURLWithPath: "/Volumes/USB")
        let new = URL(fileURLWithPath: "/Volumes/USB 1")
        let rebound = try AppLibraryImageRecovery.resolveLocalImage(record, mountedVolumes: [old, new],
            volumeUUID: { $0 == new ? "volume-usb" : "OTHER-DISK" })
        #expect(rebound.imagePath == "/Volumes/USB 1/Apps/Library.sparsebundle")
        #expect(rebound.mountPath == record.mountPath)
        #expect(rebound.backingVolumeUUID == record.backingVolumeUUID)
    }

    @Test func missingOrAmbiguousLocalVolumeNeverFallsBackToTheOldPath() throws {
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/Volumes/USB/Library.sparsebundle"))
        record.backingVolumeUUID = "VOLUME-USB"
        record.imageRelativePath = "Library.sparsebundle"
        let old = URL(fileURLWithPath: "/Volumes/USB")
        #expect(throws: (any Error).self) {
            try AppLibraryImageRecovery.resolveLocalImage(record, mountedVolumes: [old], volumeUUID: { _ in "OTHER-DISK" })
        }
        #expect(throws: (any Error).self) {
            try AppLibraryImageRecovery.resolveLocalImage(record,
                mountedVolumes: [old, URL(fileURLWithPath: "/Volumes/Clone")], volumeUUID: { _ in "VOLUME-USB" })
        }
    }

    @Test func localIdentityCannotBeOverwrittenByAnotherDiskAtTheSamePath() {
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/USB/Library.sparsebundle"))
        record.backingVolumeUUID = "VOLUME-USB"
        record.imageRelativePath = "Library.sparsebundle"
        #expect(AppLibraryImageRecovery.captureStorageLocation(record) == record)
    }

    @Test func localImageRecoveryRespectsExplicitDiskEjectionPause() async throws {
        let suite = "AppLibraryImageRecoveryTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/USB/Library.sparsebundle"))
        record.backingVolumeUUID = "VOLUME-USB"
        record.imageRelativePath = "Library.sparsebundle"
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        defaults.set(record.mountPath, forKey: "ExternalDrivePath")
        let disk = ExternalDiskInventory.Disk(deviceIdentifier: "disk99", connectionID: "fixture:99", displayName: "USB",
            volumeUUIDs: ["VOLUME-USB"], containerUUIDs: [], mountPaths: ["/fixture/USB"])
        let pause = DiskEjectionPauseStore.Pause(disk: disk)
        let runner = RecoveryInspectionRunner()
        await AppLibraryImageRecovery.recoverSelected(defaults: defaults,
            service: AppLibraryImageService(runner: runner, mountedUUID: { _ in nil }), runner: runner,
            ejection: .init(pauses: [pause]),
            findShare: { _ in Issue.record("USB must not connect to SMB"); return nil },
            connect: { _ in Issue.record("USB must not connect to SMB") })
        #expect(await runner.calls == 0)
        #expect(AppLibraryImageRecovery.selectedRecord(defaults: defaults) == record)
    }

    @Test func missingShareReconnectsEvenWhileImageDeviceStillLooksMounted() async throws {
        let suite = "AppLibraryImageRecoveryTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/Apps.sparsebundle"))
        let uuid = UUID().uuidString
        record.volumeUUID = uuid
        record.networkShareURL = "smb://nas.local/Apps"
        record.imageRelativePath = "Apps.sparsebundle"
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        defaults.set(record.mountPath, forKey: "ExternalDrivePath")
        var connected = false
        var attempts = 0
        let runner = RecoveryInspectionRunner()
        await AppLibraryImageRecovery.recoverSelected(defaults: defaults,
            service: AppLibraryImageService(runner: runner, mountedUUID: { _ in uuid }), runner: runner,
            findShare: { _ in connected ? URL(fileURLWithPath: "/fixture/Share") : nil },
            connect: { _ in attempts += 1; connected = true })
        #expect(attempts == 1)
        #expect(await runner.calls == 0)
        #expect(AppLibraryImageRecovery.selectedRecord(defaults: defaults) == record)
    }

    @Test func mountedVolumeDoesNotReconnectNASOrRunDiskCommands() async throws {
        let suite = "AppLibraryImageRecoveryTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/Apps.sparsebundle"))
        let uuid = UUID().uuidString
        record.volumeUUID = uuid
        record.backingVolumeUUID = "VOLUME-USB"
        record.imageRelativePath = "Apps.sparsebundle"
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        defaults.set(record.mountPath, forKey: "ExternalDrivePath")
        let runner = RecoveryInspectionRunner()
        await AppLibraryImageRecovery.recoverSelected(defaults: defaults,
            service: AppLibraryImageService(runner: runner, mountedUUID: { _ in uuid }), runner: runner,
            findShare: { _ in Issue.record("Mounted images must not reconnect their NAS"); return nil },
            connect: { _ in Issue.record("Mounted images must not connect a share") })
        #expect(await runner.calls == 0)
    }

    @Test func offlineShareRetainsRecordForLaterRetries() async throws {
        let suite = "AppLibraryImageRecoveryTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/Apps.sparsebundle"))
        record.networkShareURL = "smb://nas.local/Apps"
        record.imageRelativePath = "Apps.sparsebundle"
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        defaults.set(record.mountPath, forKey: "ExternalDrivePath")
        var attempts = 0
        let runner = RecoveryInspectionRunner()
        for _ in 0..<2 {
            await AppLibraryImageRecovery.recoverSelected(defaults: defaults,
                service: AppLibraryImageService(runner: runner, mountedUUID: { _ in nil }), runner: runner,
                findShare: { _ in nil }, connect: { _ in attempts += 1; throw CocoaError(.fileReadUnknown) })
        }
        #expect(attempts == 2)
        #expect(AppLibraryImageRecovery.selectedRecord(defaults: defaults) == record)
        #expect(await runner.calls == 0)
    }

    @Test func remappedShareRefusesToDuplicateAnOldUnmountedAttachment() async throws {
        let suite = "AppLibraryImageRecoveryTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/fixture/OldShare/Apps.sparsebundle"))
        record.networkShareURL = "smb://nas.local/Apps"
        record.imageRelativePath = "Apps.sparsebundle"
        try AppLibraryImageRecovery.save(record, defaults: defaults)
        defaults.set(record.mountPath, forKey: "ExternalDrivePath")
        let runner = RecoveryInspectionRunner(attachedImage: record.imagePath)
        await AppLibraryImageRecovery.recoverSelected(defaults: defaults,
            service: AppLibraryImageService(runner: runner, mountedUUID: { _ in nil }), runner: runner,
            findShare: { _ in URL(fileURLWithPath: "/fixture/NewShare") },
            connect: { _ in Issue.record("Share is already connected") })
        #expect(await runner.calls == 1)
        #expect(AppLibraryImageRecovery.selectedRecord(defaults: defaults) == record)
    }

    @Test func shareAddressNeverPersistsPasswordOrURLParameters() throws {
        let source = try #require(URL(string: "smb://alice:secret@NAS.local/Apps?password=secret#secret"))
        let clean = try #require(AppLibraryImageRecovery.sanitizedShareURL(source))
        #expect(clean.absoluteString == "smb://alice@nas.local/Apps")
        #expect(AppLibraryImageRecovery.sanitizedShareURL(URL(string: "https://nas.local/Apps")!) == nil)
        #expect(AppLibraryImageRecovery.sanitizedShareURL(URL(string: "smb://nas.local/")!) == nil)
    }

    @Test func relativeImageLocationSurvivesShareMountNameChanges() {
        let relative = AppLibraryImageRecovery.relativeImagePath(
            image: URL(fileURLWithPath: "/Volumes/Apps/Library/My Apps.sparsebundle"),
            root: URL(fileURLWithPath: "/Volumes/Apps"))
        #expect(relative == "Library/My Apps.sparsebundle")
        #expect(AppLibraryImageRecovery.relativeImagePath(
            image: URL(fileURLWithPath: "/Volumes/Apps-other/Library.sparsebundle"),
            root: URL(fileURLWithPath: "/Volumes/Apps")) == nil)
    }

    @Test(arguments: ["../Other.sparsebundle", "/Other.sparsebundle", "A/../Other.sparsebundle",
                       "A//Other.sparsebundle", "A/./Other.sparsebundle", "Other.dmg", ""])
    func refusesRelativePathEscapes(path: String) {
        #expect(!AppLibraryImageRecovery.validRelativePath(path))
    }

    @Test func onlyCurrentlySelectedImageCanRecover() throws {
        let suite = "AppLibraryImageRecoveryTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/Volumes/NAS/Apps.sparsebundle"))
        record.libraryPath = "/Volumes/Apps"
        defaults.set(try JSONEncoder().encode(record), forKey: AppLibraryImageService.preferenceKey)
        defaults.set("/Volumes/AnotherLibrary", forKey: "ExternalDrivePath")
        #expect(AppLibraryImageRecovery.selectedRecord(defaults: defaults) == nil)
        defaults.set("/Volumes/Apps", forKey: "ExternalDrivePath")
        #expect(AppLibraryImageRecovery.selectedRecord(defaults: defaults) == record)
    }

    @Test func legacyRecordRemainsReadableWithoutNetworkMetadata() throws {
        let data = Data(#"{"imagePath":"/Volumes/NAS/Apps.sparsebundle","mountPath":"/Volumes/Apps"}"#.utf8)
        let record = try JSONDecoder().decode(AppLibraryImageService.Record.self, from: data)
        #expect(record.networkShareURL == nil)
        #expect(record.imageRelativePath == nil)
        #expect(record.backingVolumeUUID == nil)
    }

    @Test func networkTimerIsLimitedToSelectedImageLibraries() {
        let basic = ContainerMountAgentInstaller.launchAgentPayload(executablePath: "/fixture/AppPorts")
        let images = ContainerMountAgentInstaller.launchAgentPayload(executablePath: "/fixture/AppPorts", recoverImages: true)
        #expect(basic["StartInterval"] == nil)
        #expect(images["StartInterval"] as? Int == 60)
    }

    @Test func imageOnlyLibraryKeepsTheAgentWithoutContainerRecords() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAgent-" + UUID().uuidString).appendingPathComponent("mounts.plist")
        let store = ContainerMountStore(fileURL: file)
        #expect(try ContainerMountAgentInstaller.requiresAgent(store: store, imageSelected: true))
        #expect(try !ContainerMountAgentInstaller.requiresAgent(store: store, imageSelected: false))
    }
}
