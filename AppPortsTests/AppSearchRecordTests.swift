import XCTest
@testable import AppPorts

final class AppSearchRecordTests: XCTestCase {
    private func fixture() -> AppSearchRecord {
        AppSearchRecord(name: "Example", localPath: "/Applications/Example.app",
                        externalPath: "/Volumes/External/Example.app", expectsLocalEntry: true)
    }

    func testDeletionPersistsAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("records.json")
        let store = AppSearchRecordStore(fileURL: url)
        let value = fixture()
        try store.record(name: value.name, localURL: URL(fileURLWithPath: value.localPath),
                         externalURL: URL(fileURLWithPath: value.externalPath), expectsLocalEntry: true)
        try store.setExpectedPresence(localURL: URL(fileURLWithPath: value.localPath), present: false)
        let after = try XCTUnwrap(AppSearchRecordStore(fileURL: url).records().first)
        XCTAssertFalse(after.expectsLocalEntry)
    }

    func testCorruptRecordsAreNotSilentlyOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("records.json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        let store = AppSearchRecordStore(fileURL: url)
        XCTAssertThrowsError(try store.setExpectedPresence(localURL: URL(fileURLWithPath: "/Applications/A.app"), present: false))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}

extension AppSearchRecordTests {
    func testRestoredLifecycleAndCleanupStateSurviveReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("records.json")
        let store = AppSearchRecordStore(fileURL: file)
        let local = URL(fileURLWithPath: "/Applications/Example.app")
        try store.record(name: "Example", localURL: local,
                         externalURL: directory.appendingPathComponent("missing.app"), expectsLocalEntry: true)
        try store.markRestored(localURL: local, remainingExternal: false)
        let record = try XCTUnwrap(AppSearchRecordStore(fileURL: file).records().first)
        XCTAssertTrue(record.isRestored)
        XCTAssertEqual(record.remainingExternal, false)
        XCTAssertTrue(record.expectsLocalEntry)
        try store.markRestored(localURL: local, remainingExternal: true)
        XCTAssertEqual(try store.records().first?.remainingExternal, true)
    }

    func testReconcileDeletedSuiteAndRestoreBrokenLinkWithoutCreatingEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSearchRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        let local = directory.appendingPathComponent("Suite/Example.app")
        try store.record(name: "Example", localURL: local,
                         externalURL: directory.appendingPathComponent("external.app"), expectsLocalEntry: true)
        try store.reconcileLocalPresence()
        XCTAssertFalse(try XCTUnwrap(store.records().first).expectsLocalEntry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: local.path, withDestinationPath: "/nonexistent-appports-test-target")
        try store.reconcileLocalPresence()
        XCTAssertTrue(try XCTUnwrap(store.records().first).expectsLocalEntry)
        XCTAssertNil(AppSearchRecordStore.observedLocalPresence(at: URL(fileURLWithPath: "/Volumes/Disconnected-\(UUID())/Example.app")))
    }

    func testUnavailableParentDoesNotMeanDeletedEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("NotADirectory")
        try Data().write(to: file)
        XCTAssertNil(AppSearchRecordStore.observedLocalPresence(at: file.appendingPathComponent("Example.app")))
    }

    func testPassiveScanCannotReplaceRememberedVolumeOrTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("records.json")
        var record = fixture()
        record.externalPath = directory.path
        record.volumeUUID = "previous-disk-uuid"
        try JSONEncoder().encode([record]).write(to: file)
        let store = AppSearchRecordStore(fileURL: file)
        let local = URL(fileURLWithPath: record.localPath)
        try store.record(name: record.name, localURL: local, externalURL: directory, expectsLocalEntry: false)
        XCTAssertEqual(try store.records().first?.volumeUUID, "previous-disk-uuid")
        XCTAssertTrue(try XCTUnwrap(store.records().first).expectsLocalEntry)
        let changed = directory.appendingPathComponent("different.app")
        try store.record(name: record.name, localURL: local, externalURL: changed, expectsLocalEntry: true)
        XCTAssertEqual(try store.records().first?.externalPath, directory.path)
        try store.record(name: record.name, localURL: local, externalURL: directory,
                         expectsLocalEntry: true, explicitOperation: true)
        XCTAssertNotEqual(try store.records().first?.volumeUUID, "previous-disk-uuid")
    }

    func testLegacyRecordDecodesAsMigrated() throws {
        let data = Data("""
        [{"name":"Example","localPath":"/Applications/Example.app","externalPath":"/Volumes/External/Example.app","expectsLocalEntry":true}]
        """.utf8)
        let record = try XCTUnwrap(JSONDecoder().decode([AppSearchRecord].self, from: data).first)
        XCTAssertFalse(record.isRestored)
    }
}

extension AppSearchRecordTests {
    func testRecordRemembersPortalBundleIdentityAfterPortalDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: local.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.original.appports.stub",
            "AppPortsTargetBundleIdentifier": "com.example.original"
        ], format: .xml, options: 0).write(to: local.appendingPathComponent("Contents/Info.plist"))
        let store = AppSearchRecordStore(fileURL: directory.appendingPathComponent("records.json"))
        let external = directory.appendingPathComponent("External.app")
        try store.record(name: "Example", localURL: local, externalURL: external, expectsLocalEntry: true)
        try FileManager.default.removeItem(at: local)
        try store.record(name: "Example", localURL: local, externalURL: external, expectsLocalEntry: false)
        XCTAssertEqual(try store.records().first?.targetBundleIdentifier, "com.example.original")
    }
}
