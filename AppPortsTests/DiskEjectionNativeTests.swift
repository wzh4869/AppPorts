import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

/// Opt-in only. The caller creates the disposable volume, records its UUID and
/// nonce, and explicitly authorizes ejection of the containing physical USB.
/// This never writes the user's default migration ledger or installs an agent.
final class DiskEjectionNativeTests: XCTestCase {
    private struct Fixture: Decodable {
        let baseUUID: String
        let dataUUID: String
        let containerUUID: String
        let nonce: String
        let mountPath: String
    }

    private func fixture() throws -> (URL, Fixture) {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_EJECT_NATIVE_FIXTURE"] else {
            throw XCTSkip("Requires an explicitly authorized disposable USB fixture")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().path == temporaryRoot.path,
              root.lastPathComponent.hasPrefix("AppPortsEjectNative-") else { throw DiskEjectionError.unavailable }
        return (root, try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json"))))
    }

    func testAuthorizedPhysicalUSBEjection() async throws {
        let (root, fixture) = try fixture()
        let disk = DiskUtility(administratorRunner: nil)
        let inventory = try await disk.ejectionInventory()
        let target = try inventory.disk(volumeUUID: fixture.baseUUID)
        XCTAssertTrue(target.volumeUUIDs.contains(fixture.dataUUID))
        XCTAssertTrue(target.containerUUIDs.contains(fixture.containerUUID))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fixture.mountPath).appendingPathComponent("sentinel.txt")), fixture.nonce)
        let base = try await disk.volumeInfo(for: fixture.baseUUID)
        let path = try XCTUnwrap(base.mountPoint)
        let records = root.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let store = ContainerMountStore(fileURL: records.appendingPathComponent("container-mounts.plist"))
        let record = ContainerMountRecord(appName: "Eject fixture", bundleIdentifier: nil, dataDirType: DataDirType.containers.rawValue,
            mountPointPath: fixture.mountPath, volumeUUID: fixture.dataUUID, volumeName: "AppPortsEjectFixture",
            externalRootPath: path)
        try store.upsert(record)
        let service = DiskEjectionService(disk: disk, store: store)
        try await service.request(at: URL(fileURLWithPath: path))
        XCTAssertTrue(try service.pauses.snapshot().blocks(volumeUUIDs: [fixture.dataUUID]))
        var offline = false
        for _ in 0..<40 {
            let current = try await disk.ejectionInventory()
            if !current.disks.contains(where: { $0.connectionID == target.connectionID }) { offline = true; break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(offline, "Finder must actually eject the physical device, not merely accept an Apple event")
        let migrator = ContainerVolumeMigrator(disk: disk, store: store, synchronizeAgent: { _ in })
        let outcomes = await migrator.remountAvailableRecords()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.state, .requiresIntervention(DiskEjectionError.paused.localizedDescription))
        try await renderHeader(root: root, service: service, basePath: path)
    }

    func testAuthorizedUSBReconnectResumesPause() async throws {
        let (root, fixture) = try fixture()
        let recordsFile = root.appendingPathComponent("records/container-mounts.plist")
        guard FileManager.default.fileExists(atPath: recordsFile.path) else {
            throw XCTSkip("Run testAuthorizedPhysicalUSBEjection and physically reconnect the USB before running reconnect verification")
        }
        let disk = DiskUtility(administratorRunner: nil)
        guard (try? await disk.volumeInfo(for: fixture.dataUUID))?.mountPoint != nil else {
            throw XCTSkip("Physical USB is still ejected; reconnect it to run the resume verification step")
        }
        let store = ContainerMountStore(fileURL: recordsFile)
        let pause = DiskEjectionPauseStore(store: store)
        XCTAssertEqual(try pause.snapshot().pauses.count, 1)
        let current = try await pause.refreshed(using: disk)
        XCTAssertTrue(current.pauses.isEmpty, "A real new physical connection must resume the same disk")
        let volume = try await disk.volumeInfo(for: fixture.dataUUID)
        let path = try XCTUnwrap(volume.mountPoint)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("sentinel.txt")), fixture.nonce)
    }

    @MainActor
    private func renderHeader(root: URL, service: DiskEjectionService, basePath: String) async throws {
        let controller = DiskEjectionController(service: service)
        await controller.refresh()
        let view = NSHostingView(rootView: ContentView.HeaderView(title: "外部应用库", subtitle: basePath,
            icon: "externaldrive.fill", tint: .teal, actionButtonText: "选择文件夹", onAction: {},
            onRefresh: {}, accessory: AnyView(DiskEjectionControls(externalURL: URL(fileURLWithPath: basePath), controller: controller))))
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 84)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("header.png"))
    }
}
