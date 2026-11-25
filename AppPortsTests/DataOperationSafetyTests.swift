import Foundation
import Testing
@testable import AppPorts

@Suite("Data operation execution safety")
struct DataOperationSafetyTests {
    @Test("Large directory inspections have a longer budget; individual files keep the short budget",
          arguments: [true, false])
    func inspectionBudget(directory: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.home.appendingPathComponent("Business")
        if directory {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        } else {
            try Data("unchanged".utf8).write(to: source)
        }
        let runner = InspectionRunner(expectedPath: source.path, directory: directory,
            result: .init(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false))
        try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: runner)
            .requireNoKnownWriters(at: source)
    }

    @Test("Incomplete inspections fail closed with distinct timeout and permission errors",
          arguments: ["timeout", "timeoutWithPartialOutput", "permission", "status", "diagnostic", "writer"])
    func inspectionFailures(scenario: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.home.appendingPathComponent("Business")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("data")
        try Data("unchanged".utf8).write(to: file)
        let timedOut = scenario.hasPrefix("timeout")
        let output = scenario == "timeoutWithPartialOutput" ? "p987\ncReader\nf3\nar\n"
            : scenario == "writer" ? "p987\ncWriter\nf3\naw\n" : ""
        let diagnostic = scenario == "permission" ? "lsof: Operation not permitted\n"
            : scenario == "diagnostic" ? "lsof: incomplete inspection\n" : ""
        let runner = InspectionRunner(expectedPath: source.path, directory: true,
            result: .init(status: scenario == "status" ? 2 : 0,
                standardOutput: Data(output.utf8), standardError: Data(diagnostic.utf8), timedOut: timedOut))
        do {
            try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: runner)
                .requireNoKnownWriters(at: source)
            Issue.record("An incomplete inspection or known writer must block the operation")
        } catch let failure as DataOperationSafety.Failure {
            switch failure {
            case .inspectionTimedOut(let path):
                #expect(timedOut)
                #expect(path == source.path)
                #expect(failure.localizedDescription != DataOperationSafety.Failure.inspection(path).localizedDescription)
            case .accessDenied(let path):
                #expect(scenario == "permission")
                #expect(path == source.path)
            case .inspection(let path):
                #expect(["status", "diagnostic"].contains(scenario))
                #expect(path == source.path)
            case .writers(let path, let processes):
                #expect(scenario == "writer")
                #expect(path == source.path)
                #expect(processes == ["Writer (987)"])
            default: Issue.record("Unexpected inspection failure: \(failure)")
            }
        }
        #expect(try Data(contentsOf: file) == Data("unchanged".utf8))
    }

    @Test("Excluded volume system artifacts allow writer inspection while non-excluded or traversed warnings still fail")
    func excludedVolumeArtifactDiagnostics() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.home.appendingPathComponent("Mounted(App)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL.path
        let safeWarnings = [
            "lsof: WARNING: can't opendir(\(canonical)/.TemporaryItems): Permission denied",
            "lsof: WARNING: can't opendir(\(canonical)/.Trashes/501): Operation not permitted"
        ].joined(separator: "\n") + "\n"
        let safeRunner = InspectionRunner(expectedPath: source.path, directory: true,
            result: .init(status: 1, standardOutput: Data(), standardError: Data(safeWarnings.utf8), timedOut: false))
        // Excluded entries on a mounted root are ignored, while empty exclusions still fail closed.
        try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: safeRunner)
            .requireNoKnownWriters(at: source, excludingRootEntries: ContainerVolumeMigrator.volumeSystemArtifacts)
        await #expect(throws: DataOperationSafety.Failure.self) {
            try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: safeRunner)
                .requireNoKnownWriters(at: source)
        }

        // Non-excluded child warnings must report the failing child path rather than the root.
        let childPath = "\(canonical)/Business/private"
        let childWarning = "lsof: WARNING: can't opendir(\(childPath)): Permission denied\n"
        let childRunner = InspectionRunner(expectedPath: source.path, directory: true,
            result: .init(status: 1, standardOutput: Data(), standardError: Data(childWarning.utf8), timedOut: false))
        do {
            try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: childRunner)
                .requireNoKnownWriters(at: source, excludingRootEntries: ContainerVolumeMigrator.volumeSystemArtifacts)
            Issue.record("A non-excluded child permission warning must fail")
        } catch DataOperationSafety.Failure.accessDenied(let path) {
            #expect(path == childPath)
        }

        // Path traversal out of an excluded root entry must never be ignored.
        let traversalWarning = "lsof: WARNING: can't opendir(\(canonical)/.TemporaryItems/../secret): Permission denied\n"
        let traversalRunner = InspectionRunner(expectedPath: source.path, directory: true,
            result: .init(status: 1, standardOutput: Data(), standardError: Data(traversalWarning.utf8), timedOut: false))
        do {
            try await DataOperationSafety(homeDirectory: fixture.home, store: fixture.store, runner: traversalRunner)
                .requireNoKnownWriters(at: source, excludingRootEntries: ContainerVolumeMigrator.volumeSystemArtifacts)
            Issue.record("Path traversal must not match excluded root entries")
        } catch DataOperationSafety.Failure.accessDenied(let path) {
            #expect(path == "\(canonical)/.TemporaryItems/../secret")
        }
    }

    @Test("Real lsof still catches a live writer when a 0311 .TemporaryItems sibling exists")
    @MainActor
    func realLsofWithProtectedTemporaryItems() async throws {
        guard geteuid() != 0 else { return }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.home.appendingPathComponent("MountedVolume")
        let tempItems = source.appendingPathComponent(".TemporaryItems")
        try FileManager.default.createDirectory(at: tempItems, withIntermediateDirectories: true)
        defer { _ = chmod(tempItems.path, 0o700) }
        let file = source.appendingPathComponent("data")
        try Data("unchanged".utf8).write(to: file)
        #expect(chmod(tempItems.path, 0o311) == 0)

        let safety = DataOperationSafety(homeDirectory: fixture.home, store: fixture.store)
        await #expect(throws: DataOperationSafety.Failure.self) {
            try await safety.requireNoKnownWriters(at: source)
        }

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
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        #expect(output.fileHandleForReading.readData(ofLength: 5) == Data("READY".utf8))
        do {
            try await safety.requireNoKnownWriters(at: source,
                excludingRootEntries: ContainerVolumeMigrator.volumeSystemArtifacts)
            Issue.record("Live writer must still be blocked when .TemporaryItems is excluded")
        } catch DataOperationSafety.Failure.writers(let path, let processes) {
            #expect(path == source.path)
            #expect(!processes.isEmpty)
        }
        try? input.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
        try? input.fileHandleForWriting.close()
        child.waitUntilExit()

        try await safety.requireNoKnownWriters(at: source,
            excludingRootEntries: ContainerVolumeMigrator.volumeSystemArtifacts)
    }

    private struct InspectionRunner: ShellCommandRunning {
        let expectedPath: String
        let directory: Bool
        let result: ShellCommandResult

        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            #expect(executable == "/usr/sbin/lsof")
            #expect(arguments == ["-nP", "-F", "pcfa", directory ? "+D" : "--", expectedPath])
            #expect(timeout == (directory ? 1800 : 30))
            return result
        }
    }

    @Test("Read-only descriptors do not count as writers; writable and unknown descriptors do", arguments: [
        ("p987\ncIndexer\nf3\nar\n", false),
        ("p987\ncReader\nfcwd\na \nf3\nar\n", false),
        ("p987\ncWriter\nf3\nar\nf4\nau\n", true),
        ("p987\ncWriter\nf3\naw\n", true),
        ("p987\ncUnknown\nf3\n", true),
        ("p987\n", true)
    ])
    func descriptorAccess(value: (String, Bool)) {
        #expect(!DataOperationSafety.writingProcesses(in: value.0, ownPID: 123).isEmpty == value.1)
        #expect(DataOperationSafety.writingProcesses(in: value.0, ownPID: 987).isEmpty)
    }

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
