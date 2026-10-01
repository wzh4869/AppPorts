import Foundation
import Testing
@testable import AppPorts

@Suite("Data operation execution safety")
struct DataOperationSafetyTests {
    private static let locked = ["", "Data", "Data/Documents", "Data/Library", "Data/Library/Application Scripts",
        "Data/Library/Application Support", "Data/Library/Caches", "Data/Library/Images", "Data/Library/Logs",
        "Data/Library/Preferences", "Data/Library/Saved Application State", "Data/SystemData", "Data/tmp"]

    @Test("Every structural node is blocked at both mount entrypoints, independently of item flags",
          arguments: locked, ["migrate", "mount"])
    func protectedEntryPoints(path: String, operation: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.home.appendingPathComponent("Library/Containers/test.synthetic").appendingPathComponent(path)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let runner = FakeDiskCommandRunner(onlineVolumes: ["SYNTHETIC"])
        let migrator = ContainerVolumeMigrator(disk: DiskUtility(runner: runner), store: fixture.store,
            stagingMountRootURL: fixture.root.appendingPathComponent("staging"), synchronizeAgent: { _ in },
            homeDirectory: fixture.home, safetyRunner: NoWriters())
        await #expect(throws: DataOperationSafety.Failure.self) {
            if operation == "mount" {
                try await migrator.mount(record: fixture.record(source))
            } else {
                let item = DataDirItem(name: "Synthetic", path: source, type: .containers,
                    priority: .recommended, description: "", isMigratable: true)
                try await migrator.migrate(item: item, externalRootURL: fixture.root.appendingPathComponent("External"),
                    appName: "Synthetic", bundleIdentifier: "test.synthetic", progressHandler: nil)
            }
        }
        #expect(runner.calls.isEmpty)
        #expect(try fixture.store.transfers().isEmpty)
    }

    @Test("Existing child/parent/offline records block a new overlapping migration",
          arguments: ["same", "parent", "child", "alias"])
    func historicalOverlap(relationship: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.home.appendingPathComponent("Library/Containers/test.synthetic/Data/Documents/Business")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let recorded: URL
        switch relationship {
        case "parent": recorded = source.deletingLastPathComponent()
        case "child": recorded = source.appendingPathComponent("Offline")
        case "alias":
            let alias = fixture.root.appendingPathComponent("Alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.deletingLastPathComponent())
            recorded = alias.appendingPathComponent(source.lastPathComponent)
        default: recorded = source
        }
        try fixture.store.upsert(fixture.record(recorded))
        let safety = DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: NoWriters())
        await #expect(throws: DataOperationSafety.Failure.self) { try await safety.requireNewMigration(at: source) }
    }

    @Test("A similarly named sibling is independent and structural children remain eligible")
    func siblingAndStructuralChild() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.home.appendingPathComponent("Library/Containers/test.synthetic/Data/tmp/Business")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try fixture.store.upsert(fixture.record(source.appendingPathExtension("old")))
        try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: NoWriters())
            .requireNewMigration(at: source)
    }

    @Test("Corrupt history cannot authorize new filesystem work")
    func corruptStoreFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("not a plist".utf8).write(to: fixture.root.appendingPathComponent("records.plist"))
        await #expect(throws: (any Error).self) {
            try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: NoWriters())
                .requireNewMigration(at: fixture.home.appendingPathComponent("Business"))
        }
    }

    @Test("A legacy managed symlink descendant blocks moving its parent")
    func managedChildLink() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.home.appendingPathComponent("Business")
        let external = fixture.root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: external.appendingPathComponent(".appports-link-metadata.plist"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("child"), withDestinationURL: external)
        await #expect(throws: DataOperationSafety.Failure.self) {
            try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: NoWriters())
                .requireNewMigration(at: source)
        }
    }

    @Test("An identifiable process holding a selected file blocks the operation")
    @MainActor // Keep Process launch and deferred wait on the same thread across await.
    func realHeldWriterIsDetected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.home.appendingPathComponent("Business")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("data")
        try Data("unchanged".utf8).write(to: file)
        let child = Process()
        let input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "exec 9<> \"$1\"; printf READY; read response", "writer", file.path]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? input.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        #expect(output.fileHandleForReading.readData(ofLength: 5) == Data("READY".utf8))
        await #expect(throws: DataOperationSafety.Failure.self) {
            try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store)
                .requireNoKnownWriters(at: source)
        }
        #expect(try Data(contentsOf: file) == Data("unchanged".utf8))
    }

    private struct NoWriters: ShellCommandRunning {
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            #expect(executable == "/usr/sbin/lsof")
            return ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
        }
    }
    private final class Fixture {
        let root: URL
        let home: URL
        let store: ContainerMountStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsExecutionSafety-\(UUID())")
                .resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"))
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        func record(_ path: URL) -> ContainerMountRecord {
            .init(appName: "Synthetic", bundleIdentifier: "test.synthetic", dataDirType: DataDirType.containers.rawValue,
                  mountPointPath: path.path, volumeUUID: "SYNTHETIC", volumeName: "Synthetic", externalRootPath: root.path)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
