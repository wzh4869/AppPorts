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
}
