import XCTest
@testable import AppPorts

final class AppPortalMaintenanceTests: XCTestCase {
    func testTransferRecordsSurviveDeletionAndOnlyExplicitRelinkingRestoresExpectation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Local.app")
        let external = root.appendingPathComponent("External.app")
        try makePortal(local, target: external)
        let store = AppSearchRecordStore(fileURL: root.appendingPathComponent("records.json"))
        let app = AppItem(name: "Local.app", path: local, status: AppStatus.local)
        try AppPortalMaintenance.recordCompletedTransfer(.movedOut(app, destination: external, isMASExternal: false), store: store)
        XCTAssertEqual(try store.records().first?.expectsLocalEntry, true)
        try FileManager.default.removeItem(at: local)
        try AppPortalMaintenance.recordDeletion(at: local, store: store)
        try AppPortalMaintenance.rememberEntries(at: local, store: store)
        XCTAssertEqual(try store.records().first?.expectsLocalEntry, false)
        XCTAssertEqual(try store.records().first?.externalPath, external.path)
        try makePortal(local, target: external)
        try AppPortalMaintenance.recordCompletedTransfer(.linkedIn(app, localDestination: local), store: store)
        XCTAssertEqual(try store.records().first?.expectsLocalEntry, true)
    }

    func testRestoringWithoutPriorEntryRecordsRealLocalApplicationAndExternalRemainder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Restored.app")
        let external = root.appendingPathComponent("External.app")
        try write(["CFBundleIdentifier": "org.example.app"], at: local)
        let store = AppSearchRecordStore(fileURL: root.appendingPathComponent("records.json"))
        let app = AppItem(name: "External.app", path: external, status: AppStatus.unlinked)
        try AppPortalMaintenance.recordCompletedTransfer(.movedBack(app, localDestination: local,
            externalSourceRemains: true), store: store)
        let record = try XCTUnwrap(store.records().first)
        XCTAssertTrue(record.isRestored)
        XCTAssertTrue(record.expectsLocalEntry)
        XCTAssertEqual(record.remainingExternal, true)
        XCTAssertEqual(record.externalPath, external.path)
        XCTAssertTrue(AppPortalMaintenance.entries(at: local).isEmpty, "A restored real app must never be repaired as a portal")
    }

    func testDiscoveryUsesRecordedTargetAndDoesNotRecreateMissingEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Renamed.app")
        let external = root.appendingPathComponent("Elsewhere/Original.app")
        try makePortal(local, target: external)
        let entries = AppPortalMaintenance.entries(at: local)
        XCTAssertEqual(entries.map(\.externalURL), [external]) // Even while the target is offline.
        try FileManager.default.removeItem(at: local)
        XCTAssertTrue(AppPortalMaintenance.entries(at: local).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
    }

    func testSuiteDiscoveryIncludesOnlySurvivingManagedChildren() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Suite")
        let external = root.appendingPathComponent("ExternalSuite")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["externalPath": external.path], format: .xml, options: 0)
            .write(to: local.appendingPathComponent(AppMigrationService.folderPortalMarkerName))
        let portal = local.appendingPathComponent("Existing.app")
        try makePortal(portal, target: external.appendingPathComponent("Existing.app"))
        try write(["CFBundleIdentifier": "org.user.real"], at: local.appendingPathComponent("Real.app"))
        XCTAssertEqual(AppPortalMaintenance.entries(at: local).map { $0.localURL.path }, [portal.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("Missing.app").path))
    }

    func testLegacyPortalAdoptsOnlyItsOriginalBundleIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Local.app")
        let external = root.appendingPathComponent("Actual.app")
        try write(["CFBundleIdentifier": "org.example.app.appports.stub"], at: local)
        try write(["CFBundleIdentifier": "org.example.app"], at: external)
        XCTAssertTrue(AppPortalMaintenance.targetIdentityMatches(localURL: local, externalURL: external))
        try write(["CFBundleIdentifier": "org.other.app"], at: external)
        XCTAssertFalse(AppPortalMaintenance.targetIdentityMatches(localURL: local, externalURL: external))
    }

    func testWrongVolumeAtSamePathCannotBeAdopted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Local.app")
        let external = root.appendingPathComponent("Actual.app")
        try write(["CFBundleIdentifier": "org.example.app", "CFBundleVersion": "1"], at: external)
        try write(["CFBundleIdentifier": "org.example.app.appports.stub",
                   "AppPortsTargetBundleIdentifier": "org.example.app",
                   "AppPortsTargetVolumeUUID": "another-volume"], at: local)
        XCTAssertFalse(AppPortalMaintenance.targetIdentityMatches(localURL: local, externalURL: external))
        let uuid = try XCTUnwrap(external.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        try write(["CFBundleIdentifier": "org.example.app.appports.stub",
                   "AppPortsTargetBundleIdentifier": "org.example.app",
                   "AppPortsTargetVolumeUUID": uuid], at: local)
        XCTAssertTrue(AppPortalMaintenance.targetIdentityMatches(localURL: local, externalURL: external))
    }

    private func write(_ values: [String: Any], at app: URL) throws {
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func makePortal(_ local: URL, target: URL) throws {
        try write(["CFBundleIdentifier": "org.example.app.appports.stub", "CFBundleExecutable": "launcher"], at: local)
        let resources = local.appendingPathComponent("Contents/Resources")
        let macos = local.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data().write(to: macos.appendingPathComponent("launcher"))
        try target.path.write(to: resources.appendingPathComponent("real_app_path.txt"), atomically: true, encoding: .utf8)
    }
}
