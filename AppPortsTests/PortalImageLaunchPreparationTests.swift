import Foundation
import Testing
@testable import AppPorts

private actor LaunchPreparationEvents {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

struct PortalImageLaunchPreparationTests {
    private let identifier = "org.example.video"

    private func image() -> AppLibraryImageService.Record {
        var record = AppLibraryImageService.Record(imageURL: URL(fileURLWithPath: "/Volumes/Share/Apps.sparsebundle"))
        record.libraryPath = "/Volumes/Apps"
        record.volumeUUID = UUID().uuidString
        return record
    }

    private func mount(root: String = "/Volumes/Apps", identifier: String = "org.example.video") -> ContainerMountRecord {
        ContainerMountRecord(appName: "Video", bundleIdentifier: identifier, dataDirType: "documents",
            mountPointPath: "/fixture/Containers/Video/Data", volumeUUID: UUID().uuidString,
            volumeName: "Video Data", externalRootPath: root, createdAt: Date())
    }

    @Test func ordinaryPortalDropsHelperEvenWhenAnotherApplicationUsesAnImage() throws {
        let metadata = try PortalImageLaunchPreparation.metadata(targetPath: "/Volumes/Physical/Video.app",
            identifier: identifier, previous: [PortalImageLaunchPreparation.helperKey: "/old/AppPorts"],
            current: image(), mounts: [mount(identifier: "org.example.other")], links: [],
            helperURL: URL(fileURLWithPath: "/temporary/AppPorts"))
        #expect(metadata == .init())
        var info: [String: Any] = [PortalImageLaunchPreparation.helperKey: "/old/AppPorts"]
        #expect(!metadata.matches(info))
        try metadata.apply(to: &info)
        #expect(info[PortalImageLaunchPreparation.helperKey] == nil)
        #expect(metadata.matches(info))
    }

    @Test func dataMigrationAddsPreparationAndRestoreRemovesIt() throws {
        let record = image()
        let helper = URL(fileURLWithPath: "/Applications/AppPorts.app/Contents/MacOS/AppPorts")
        let prepared = try PortalImageLaunchPreparation.metadata(targetPath: "/Volumes/Physical/Video.app",
            identifier: identifier, previous: [:], current: record, mounts: [mount()], links: [], helperURL: helper)
        #expect(prepared.helperPath == helper.path)
        #expect(prepared.image == nil)
        var info: [String: Any] = [:]
        #expect(!prepared.matches(info))
        try prepared.apply(to: &info)
        #expect(prepared.matches(info))
        let restored = try PortalImageLaunchPreparation.metadata(targetPath: "/Volumes/Physical/Video.app",
            identifier: identifier, previous: info, current: record, mounts: [], links: [], helperURL: helper)
        #expect(restored == .init())
        #expect(!restored.matches(info))
    }

    @Test func existingApplicationImageSurvivesSelectionChanges() throws {
        let oldImage = image()
        var previous: [String: Any] = [:]
        try PortalImageLaunchPreparation.Metadata(helperPath: "/Applications/AppPorts.app/Contents/MacOS/AppPorts",
            image: oldImage).apply(to: &previous)
        let metadata = try PortalImageLaunchPreparation.metadata(targetPath: "/Volumes/Apps/Video.app",
            identifier: identifier, previous: previous, current: nil, mounts: [], links: [],
            helperURL: URL(fileURLWithPath: "/Applications/AppPorts.app/Contents/MacOS/AppPorts"))
        #expect(metadata.image == oldImage)
        #expect(metadata.matches(previous))
    }

    @Test func temporaryBuildCannotPublishAnImageHelperPath() {
        #expect(throws: AppInstallationLocation.Failure.self) {
            try PortalImageLaunchPreparation.metadata(targetPath: "/Volumes/Apps/Video.app", identifier: identifier,
                previous: [:], current: image(), mounts: [], links: [], helperURL: URL(fileURLWithPath: "/tmp/AppPorts"))
        }
    }

    @Test func physicalStorageAndUnrelatedApplicationsDoNotProduceMountPlans() {
        let record = image()
        let request = PortalImageLaunchPreparation.Request(identifier: identifier,
            targetPath: "/Volumes/Physical/Video.app", image: nil)
        let plans = PortalImageLaunchPreparation.plans(for: request, current: record,
            mounts: [mount(root: "/Volumes/Physical"), mount(identifier: "org.example.other")], links: [])
        #expect(plans.isEmpty)
        #expect(!PortalImageLaunchPreparation.contains("/Volumes/Apps-other/Video.app", in: "/Volumes/Apps"))
    }

    @Test func applicationAndDataCanUseTheSameImageWithoutDuplicatingAttachment() {
        let record = image()
        let data = mount()
        let request = PortalImageLaunchPreparation.Request(identifier: identifier,
            targetPath: "/Volumes/Apps/Video.app", image: record)
        let plans = PortalImageLaunchPreparation.plans(for: request, current: record,
            mounts: [data, mount(identifier: "org.example.other")], links: [])
        #expect(plans.count == 1)
        #expect(plans.first?.mounts == [data])
    }

    @Test func dataImageIsPreparedEvenWhenTheApplicationLivesElsewhere() {
        let record = image()
        let request = PortalImageLaunchPreparation.Request(identifier: identifier,
            targetPath: "/Volumes/Physical/Video.app", image: nil)
        let plans = PortalImageLaunchPreparation.plans(for: request, current: record, mounts: [mount()], links: [])
        #expect(plans.count == 1)
    }

    @Test(arguments: [true, false])
    func mountsOnlyImageBackedDataAndOnlyAfterImagePreparation(belongsToImage: Bool) async throws {
        let record = image()
        let data = mount()
        let events = LaunchPreparationEvents()
        let operations = PortalImageLaunchPreparation.Operations(
            restoreImage: { image in await events.add("image"); return image },
            volumeUUIDs: { _ in
                await events.add("inventory")
                return belongsToImage ? [data.volumeUUID.uppercased()] : []
            },
            mountData: { _ in await events.add("data") },
            verifyLink: { _ in Issue.record("No links belong to this fixture") })
        let plan = PortalImageLaunchPreparation.Plan(image: record, mounts: [data], links: [])
        if belongsToImage {
            try await PortalImageLaunchPreparation.execute([plan], operations: operations)
            #expect(await events.values == ["image", "inventory", "data"])
        } else {
            await #expect(throws: (any Error).self) {
                try await PortalImageLaunchPreparation.execute([plan], operations: operations)
            }
            #expect(await events.values == ["image", "inventory"])
        }
    }

    @Test func failedImagePreparationNeverMountsDataOrContinuesLaunch() async {
        let events = LaunchPreparationEvents()
        let operations = PortalImageLaunchPreparation.Operations(
            restoreImage: { _ in throw CocoaError(.fileReadUnknown) },
            volumeUUIDs: { _ in await events.add("inventory"); return [] },
            mountData: { _ in await events.add("data") },
            verifyLink: { _ in await events.add("link") })
        let plan = PortalImageLaunchPreparation.Plan(image: image(), mounts: [mount()], links: [])
        await #expect(throws: (any Error).self) {
            try await PortalImageLaunchPreparation.execute([plan], operations: operations)
        }
        #expect(await events.values.isEmpty)
    }

    private func link() -> ManagedDataLinkRecord {
        ManagedDataLinkRecord(operationID: UUID(), originalPath: "/fixture/Library/Video",
            destinationPath: "/Volumes/Apps/Data/Video", destinationIdentity: DataPathIdentity(device: 1, inode: 2),
            appName: "Video", bundleIdentifier: identifier, dataDirType: DataDirType.dotFolder.rawValue)
    }

    private func readiness(failing step: String? = nil, events: LaunchPreparationEvents,
                           uuids: Set<String>) -> PortalImageLaunchPreparation.Readiness {
        PortalImageLaunchPreparation.Readiness(
            imageMounted: { _ in await events.add("image"); return step != "image" },
            volumeUUIDs: { _ in
                await events.add("inventory")
                if step == "inventory" { throw CocoaError(.fileReadUnknown) }
                return step == "foreign" ? [] : uuids
            },
            dataMounted: { _ in await events.add("data"); return step != "data" },
            verifyLink: { _ in
                await events.add("link")
                if step == "link" { throw CocoaError(.fileReadUnknown) }
            })
    }

    @Test func storageAlreadyInPlaceSkipsTheLockedPath() async {
        let data = mount()
        let events = LaunchPreparationEvents()
        let plan = PortalImageLaunchPreparation.Plan(image: image(), mounts: [data], links: [link()])
        let ready = await PortalImageLaunchPreparation.isPrepared([plan],
            readiness: readiness(events: events, uuids: [data.volumeUUID.uppercased()]))
        #expect(ready)
        #expect(await events.values == ["image", "inventory", "data", "link"])
    }

    @Test(arguments: ["image", "inventory", "foreign", "data", "link"])
    func anyDoubtLeavesPreparationToTheLockedPath(step: String) async {
        let data = mount()
        let events = LaunchPreparationEvents()
        let plan = PortalImageLaunchPreparation.Plan(image: image(), mounts: [data], links: [link()])
        let ready = await PortalImageLaunchPreparation.isPrepared([plan],
            readiness: readiness(failing: step, events: events, uuids: [data.volumeUUID.uppercased()]))
        #expect(!ready)
        // Later checks never run after the first doubt.
        let expected: [String: [String]] = ["image": ["image"], "inventory": ["image", "inventory"],
            "foreign": ["image", "inventory"], "data": ["image", "inventory", "data"],
            "link": ["image", "inventory", "data", "link"]]
        #expect(await events.values == expected[step])
    }

    @Test func imagesWithoutDataSkipTheVolumeInventory() async {
        let events = LaunchPreparationEvents()
        let plan = PortalImageLaunchPreparation.Plan(image: image(), mounts: [], links: [])
        #expect(await PortalImageLaunchPreparation.isPrepared([plan], readiness: readiness(events: events, uuids: [])))
        #expect(await events.values == ["image"])
    }
}
