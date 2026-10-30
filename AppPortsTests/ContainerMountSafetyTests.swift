import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Container mount safety")
struct ContainerMountSafetyTests {
    @Test("Legacy and current guards become readable without allowing writes", arguments: [0, 0o500])
    func reopensLockedMountPoint(mode: Int) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(chmod(fixture.mountPoint.path, mode_t(mode)) == 0)
        for _ in 0..<2 {
            let lease = try MountPointLease(at: fixture.mountPoint)
            try lease.verifyBeforeMount()
            try lease.verifyUnderlyingDirectory()
            #expect(try fixture.mode() == 0o500)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.mountPoint.path).isEmpty)
            let missing = fixture.mountPoint.appendingPathComponent("missing.db")
            var info = stat()
            let lookup = lstat(missing.path, &info)
            let lookupError = errno
            #expect(lookup == -1)
            #expect(lookupError == ENOENT)
            let fd = open(missing.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            let writeError = errno
            if fd >= 0 { close(fd) }
            #expect(fd == -1)
            #expect(writeError == EACCES)
            let created = mkdir(fixture.mountPoint.appendingPathComponent("nested").path, 0o700)
            let directoryError = errno
            #expect(created == -1)
            #expect(directoryError == EACCES)
        }
    }

    @Test("Read-only leases preserve nonempty directories and their original permissions")
    func readOnlyLeaseRejectsContent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.mountPoint.appendingPathComponent("payload")
        let content = Data("preserve".utf8)
        try content.write(to: file)
        #expect(chmod(fixture.mountPoint.path, 0o500) == 0)
        #expect(throws: MountPointLease.Failure.self) {
            _ = try MountPointLease(at: fixture.mountPoint)
        }
        #expect(try fixture.mode() == 0o500)
        #expect(try Data(contentsOf: file) == content)
    }

    @Test("Persisted WeChat identities select read-only media protection with split mode disabled",
          arguments: ["com.tencent.xinWeChat", "com.tencent.xinWeChat.dual"], ["msg", "business"])
    func failedWeChatMountKeepsReadOnlyProtection(identifier: String, member: String) async throws {
        let fixture = try Fixture(weChatIdentifier: identifier, member: member)
        defer { fixture.cleanup() }
        #expect(chmod(fixture.mountPoint.path, 0) == 0)
        fixture.runner.failWhen(prefix: ["mount"])
        await #expect(throws: ContainerVolumeMigrator.MigrationError.self) {
            try await fixture.migrator.mount(record: fixture.record)
        }
        #expect(fixture.runner.commands(prefix: ["mount"]).count == 1)
        #expect(try fixture.mode() == 0o500)
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
        #expect(try fixture.mode() == 0o500)
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
            #expect(chmod(fixture.mountPoint.path, MountPointLease.protectedMode) == 0)
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
        let home: URL
        let identifier: String
        let store: ContainerMountStore
        let runner = FakeDiskCommandRunner(onlineVolumes: ["SAFETY-UUID"])
        lazy var record: ContainerMountRecord = {
            ContainerMountRecord(appName: "Synthetic", bundleIdentifier: identifier,
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
                mountFlags: { _ in UInt32(MNT_DONTBROWSE) }, homeDirectory: home)
        }
        init(weChatIdentifier: String? = nil, member: String = "msg") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsMountSafety-\(UUID())")
                .resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            identifier = weChatIdentifier ?? "test.appports.safety"
            if let weChatIdentifier {
                mountPoint = PartialWeChatMigrationPolicy(homeDirectory: home, containerIdentifier: weChatIdentifier)
                    .accountsRoot.appendingPathComponent("wxid_fixture/" + member)
            } else {
                mountPoint = root.appendingPathComponent("Data")
            }
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
