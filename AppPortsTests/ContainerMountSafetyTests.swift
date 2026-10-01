import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Container mount safety")
struct ContainerMountSafetyTests {
    @Test("A previously locked 000 mountpoint can be inspected and stays locked")
    func reopensLockedMountPoint() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(chmod(fixture.mountPoint.path, 0) == 0)
        for _ in 0..<2 {
            let lease = try MountPointLease(at: fixture.mountPoint)
            try lease.verifyBeforeMount()
            try lease.verifyUnderlyingDirectory()
            #expect(try fixture.mode() == 0)
        }
    }

    @Test("A failed mount command is not retried with writable local permissions")
    func commandFailureDoesNotOpenMountPoint() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.runner.failWhen(prefix: ["mount"])
        await #expect(throws: ContainerVolumeMigrator.MigrationError.self) {
            try await fixture.migrator.mount(record: fixture.record)
        }
        #expect(fixture.runner.commands(prefix: ["mount"]).count == 1)
        #expect(try fixture.mode() == 0)
    }

    @Test("Even a lone Finder metadata file blocks a mount overlay")
    func finderFileIsLocalContent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let data = Data("must remain visible".utf8)
        let file = fixture.mountPoint.appendingPathComponent(".DS_Store")
        try data.write(to: file)
        let before = try fixture.mode()
        await #expect(throws: ContainerVolumeMigrator.MigrationError.self) {
            try await fixture.migrator.mount(record: fixture.record)
        }
        #expect(fixture.runner.commands(prefix: ["mount"]).isEmpty)
        #expect(try Data(contentsOf: file) == data)
        #expect(try fixture.mode() == before)
    }

    @Test("The held descriptor detects late content, permission changes and path replacement",
          arguments: ["content", "permission", "replacement"])
    func heldDirectoryRejectsMutation(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lease = try MountPointLease(at: fixture.mountPoint)
        try lease.verifyBeforeMount()
        switch kind {
        case "content":
            #expect(chmod(fixture.mountPoint.path, 0o700) == 0)
            try Data("late data".utf8).write(to: fixture.mountPoint.appendingPathComponent("late"))
            #expect(chmod(fixture.mountPoint.path, 0) == 0)
        case "replacement":
            let moved = fixture.root.appendingPathComponent("held-original")
            try FileManager.default.moveItem(at: fixture.mountPoint, to: moved)
            #expect(chmod(moved.path, 0o700) == 0)
            try FileManager.default.createDirectory(at: fixture.mountPoint, withIntermediateDirectories: false)
        default:
            #expect(chmod(fixture.mountPoint.path, 0o700) == 0)
        }
        #expect(throws: MountPointLease.Failure.self) { try lease.verifyUnderlyingDirectory() }
    }

    @Test("A terminal intervention outcome never enters the volume retry loop")
    func terminalOutcomeDoesNotRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outcome = ContainerVolumeMigrator.RemountOutcome(record: fixture.record, state: .requiresIntervention("conflict"))
        let result = await ContainerRemountLoop.run(attempt: { .results([outcome]) }, waitForChange: { _ in
            Issue.record("Terminal conflicts must not wait or retry")
            return nil
        })
        #expect(result.cycles == 1)
        #expect(result.outcomes.first?.state == .requiresIntervention("conflict"))
    }

    private final class Fixture {
        let root: URL
        let mountPoint: URL
        let store: ContainerMountStore
        let runner = FakeDiskCommandRunner(onlineVolumes: ["SAFETY-UUID"])
        lazy var record: ContainerMountRecord = {
            ContainerMountRecord(appName: "Synthetic", bundleIdentifier: "test.appports.safety",
                dataDirType: DataDirType.containers.rawValue, mountPointPath: mountPoint.path,
                volumeUUID: "SAFETY-UUID", volumeName: "AppPorts-synthetic", externalRootPath: root.path)
        }()
        var migrator: ContainerVolumeMigrator {
            let runner = runner
            return ContainerVolumeMigrator(disk: DiskUtility(runner: runner), store: store,
                stagingMountRootURL: root.appendingPathComponent("staging"),
                isMountPoint: { runner.isMounted($0) }, mountedVolumePath: { _ in "/" },
                mountedVolumeUUID: { runner.mountedUUID(at: $0) }, volumeUUIDMarker: { _ in nil },
                synchronizeAgent: { _ in }, availableCapacity: { _ in nil },
                mountFlags: { _ in UInt32(MNT_DONTBROWSE) })
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsMountSafety-\(UUID())")
                .resolvingSymlinksInPath()
            mountPoint = root.appendingPathComponent("Data")
            store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"))
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try store.upsert(record)
        }
        func mode() throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: mountPoint.path)[.posixPermissions] as? NSNumber).intValue
        }
        func cleanup() {
            _ = chmod(mountPoint.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
