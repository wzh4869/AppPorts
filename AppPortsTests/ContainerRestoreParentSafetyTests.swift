import Foundation
import XCTest
@testable import AppPorts

final class ContainerRestoreParentSafetyTests: XCTestCase {
    func testRestoreRejectsUnmarkedSymlinkAncestorBeforeIntentOrDiskCommand() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let other = fixture.root.appendingPathComponent("Elsewhere")
        try FileManager.default.moveItem(at: fixture.parent, to: other)
        try FileManager.default.createSymbolicLink(at: fixture.parent, withDestinationURL: other)
        do {
            try await fixture.migrator().restore(record: fixture.record, estimatedTotalBytes: 0, progressHandler: nil)
            XCTFail("A linked parent is not a local restore destination")
        } catch DataOperationSafety.Failure.conflict { }
        XCTAssertTrue(try fixture.store.transfers().isEmpty)
        XCTAssertTrue(fixture.disk.calls.isEmpty)
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("Business/payload")), "original")
    }

    func testRestoreRechecksParentBeforeRemovingMountRecordAndUnmounting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let moved = fixture.root.appendingPathComponent("RelocatedParent")
        do {
            try await fixture.migrator().restore(record: fixture.record, estimatedTotalBytes: 0) { progress in
                guard progress.currentFile == "正在切换本地入口...".localized else { return }
                try? FileManager.default.moveItem(at: fixture.parent, to: moved)
                try? FileManager.default.createSymbolicLink(at: fixture.parent, withDestinationURL: moved)
            }
            XCTFail("Parent changes must stop before switching")
        } catch DataOperationSafety.Failure.conflict { }
        XCTAssertEqual(try fixture.store.recordsStrict(), [fixture.record])
        XCTAssertTrue(fixture.disk.calls.isEmpty)
        XCTAssertEqual(try fixture.store.transfers().first?.phase, .needsRecovery)
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("Business/payload")), "original")
    }

    private final class RejectDiskCommands: ShellCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String]] = []
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return values }
        private func record(_ arguments: [String]) { lock.lock(); defer { lock.unlock() }; values.append(arguments) }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            record(arguments)
            throw CocoaError(.featureUnsupported)
        }
    }

    private struct NoWriters: ShellCommandRunning {
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
        }
    }

    private struct Fixture: @unchecked Sendable {
        let root: URL
        let home: URL
        let parent: URL
        let source: URL
        let store: ContainerMountStore
        let record: ContainerMountRecord
        let disk = RejectDiskCommands()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerRestoreParentSafetyTests-\(UUID())")
            home = root.appendingPathComponent("Home")
            parent = home.appendingPathComponent("Library/Containers/com.example.fixture/Data/Library/Application Support")
            source = parent.appendingPathComponent("Business")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("payload"))
            store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"))
            record = ContainerMountRecord(appName: "Fixture", bundleIdentifier: "com.example.fixture", dataDirType: "Containers",
                mountPointPath: source.path, volumeUUID: UUID().uuidString, volumeName: "Fixture", externalRootPath: root.appendingPathComponent("External").path)
            try store.upsert(record)
        }

        func migrator() -> ContainerVolumeMigrator {
            ContainerVolumeMigrator(disk: DiskUtility(runner: disk, administratorRunner: nil), store: store,
                stagingMountRootURL: root.appendingPathComponent("PrivateMounts"), isMountPoint: { $0.path == source.path },
                mountedVolumePath: { _ in nil }, mountedVolumeUUID: { _ in record.volumeUUID }, volumeUUIDMarker: { _ in nil },
                synchronizeAgent: { _ in }, availableCapacity: { _ in nil }, mountFlags: { _ in 0 },
                homeDirectory: home, safetyRunner: NoWriters())
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
