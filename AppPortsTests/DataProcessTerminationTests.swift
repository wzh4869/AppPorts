import Darwin
import Foundation
import Testing
@testable import AppPorts

/// Opt-in, two-test-host process probe. The ordinary suite does not terminate
/// itself. The coordinator supplies a unique empty directory under NSTemporaryDirectory
/// and runs crash, then recover, with the same directory and one of four modes.
struct DataProcessTerminationTests {
    private struct Facts: Codable {
        let scenario: String
        let operationID: UUID
        let originalProcessID: Int32
        let sourcePath: String
        let sourceSnapshot: TreeCopySnapshot
    }

    @Test("Opt-in SIGKILL recovery probe uses only temporary data and synthetic volumes")
    func processTerminationProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["APPPORTS_DATA_PROBE_PHASE"] else { return }
        let scenario = try #require(environment["APPPORTS_DATA_PROBE_SCENARIO"])
        let action = environment["APPPORTS_DATA_PROBE_ACTION"] ?? "restart"
        let path = try #require(environment["APPPORTS_DATA_PROBE_ROOT"])
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(temporary.path + "/") && root.lastPathComponent.hasPrefix("AppPortsProcess-"))
        try #require(["symlink-migrate", "symlink-restore", "mount-migrate", "mount-restore"].contains(scenario))
        try #require(["crash", "recover"].contains(phase) && ["restart", "cancel"].contains(action))
        let home = root.appendingPathComponent("Home")
        let mount = scenario.hasPrefix("mount")
        let restore = scenario.hasSuffix("restore")
        let local = home.appendingPathComponent(mount ? "Library/Containers/org.example.process/Data/Documents/Payload" : "Payload")
        let external = root.appendingPathComponent("External")
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"))
        let simulation = root.appendingPathComponent("synthetic-disks.plist")
        let factsURL = root.appendingPathComponent("crash-facts.plist")
        let runner: FakeDiskCommandRunner
        if phase == "crash" {
            if FileManager.default.fileExists(atPath: root.path) {
                try #require(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            } else { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            try Data("first".utf8).write(to: local.appendingPathComponent("a.txt"))
            try Data("second".utf8).write(to: local.appendingPathComponent("b.txt"))
            runner = FakeDiskCommandRunner(createdVolumeUUID: try DataPathIdentity.capture(local).volumeUUID)
        } else { runner = try FakeDiskCommandRunner.reopenSimulationState(from: simulation) }
        let dataMover = DataDirMover(homeDir: home, store: store, runner: SyntheticNoWritersRunner())
        let volumeMover = ContainerVolumeMigrator(disk: DiskUtility(runner: runner, commandTimeout: 5), store: store,
            stagingMountRootURL: root.appendingPathComponent("mounts"), isMountPoint: { runner.isMounted($0) },
            mountedVolumePath: { $0.path.hasPrefix(external.path) ? "/SyntheticExternal" : "/" },
            mountedVolumeUUID: { runner.mountedUUID(at: $0) }, synchronizeAgent: { _ in },
            availableCapacity: { _ in nil }, mountFlags: { _ in UInt32(MNT_DONTBROWSE) },
            homeDirectory: home, safetyRunner: SyntheticNoWritersRunner(), makeMountPointLease: { try runner.makeMountPointLease(at: $0) })
        let item = DataDirItem(name: "Payload", path: local, type: mount ? .containers : .custom,
            priority: .recommended, description: "")
        if phase == "crash" {
            if restore {
                if mount {
                    _ = try await volumeMover.migrateAndComplete(item: item, externalRootURL: external,
                        appName: "Process probe", bundleIdentifier: nil, progressHandler: nil)
                } else { _ = try await dataMover.migrateAndComplete(item: item, to: external, progressHandler: nil) }
            }
            let source = restore && !mount ? external.appendingPathComponent("Payload") : local
            let sourceSnapshot = try TreeCopySession.snapshot(at: source)
            let progress: FileCopier.ProgressHandler = { progress in
                guard progress.currentFile == "a.txt" else { return }
                do {
                    let transfer = try #require(try store.transfers().last)
                    try #require(transfer.phase == .copying && transfer.sourceBaseline != nil && transfer.destinationIdentity != nil)
                    try runner.saveSimulationState(to: simulation)
                    let facts = Facts(scenario: scenario, operationID: transfer.operationID,
                        originalProcessID: getpid(), sourcePath: source.path, sourceSnapshot: sourceSnapshot)
                    try DurableFileIO.write(PropertyListEncoder().encode(facts), to: factsURL)
                    try DurableFileIO.write(Data("SIGKILL after a.txt".utf8), to: root.appendingPathComponent("crash-ready"))
                } catch {
                    Issue.record("Could not persist the process probe: \(error)")
                    return
                }
                _ = kill(getpid(), SIGKILL)
                _exit(87)
            }
            if mount {
                if restore {
                    let record = try #require(try store.recordsStrict().first)
                    try await volumeMover.restore(record: record, estimatedTotalBytes: 0, progressHandler: progress)
                } else {
                    _ = try await volumeMover.migrate(item: item, externalRootURL: external, appName: "Process probe",
                        bundleIdentifier: nil, progressHandler: progress)
                }
            } else if restore { try await dataMover.restore(item: item, progressHandler: progress) }
            else { try await dataMover.migrate(item: item, to: external, progressHandler: progress) }
            Issue.record("The crash phase reached the end without terminating its test host")
            return
        }
        let facts = try PropertyListDecoder().decode(Facts.self, from: Data(contentsOf: factsURL))
        try #require(facts.scenario == scenario && facts.originalProcessID != getpid())
        let transfer = try #require(try store.transfer(operationID: facts.operationID))
        #expect(transfer.phase == .copying)
        #expect(transfer.baseline == nil && transfer.sourceBaseline != nil && transfer.destinationIdentity != nil)
        let source = URL(fileURLWithPath: facts.sourcePath)
        #expect(try TreeCopySession.snapshot(at: source) == facts.sourceSnapshot)
        let candidate = URL(fileURLWithPath: try #require(transfer.preparationPath))
        #expect(try String(contentsOf: candidate.appendingPathComponent("a.txt"), encoding: .utf8) == "first")
        #expect(!FileManager.default.fileExists(atPath: candidate.appendingPathComponent("b.txt").path))
        if action == "cancel" {
            if mount { try await volumeMover.cancelPreparation(operationID: facts.operationID) }
            else { try await dataMover.cancelPreparation(operationID: facts.operationID) }
            #expect(try TreeCopySession.snapshot(at: source) == facts.sourceSnapshot)
        } else {
            let warning: String?
            if mount { warning = try await volumeMover.resumeVerifiedTransfer(operationID: facts.operationID, progressHandler: nil) }
            else { warning = try await dataMover.resumeVerifiedTransfer(operationID: facts.operationID, progressHandler: nil) }
            #expect(warning == nil)
            #expect(try String(contentsOf: local.appendingPathComponent("a.txt"), encoding: .utf8) == "first")
            #expect(try String(contentsOf: local.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
        }
        #expect(try store.transfers().isEmpty)
        let result: [String: String] = ["scenario": scenario, "action": action,
            "operationID": facts.operationID.uuidString, "crashedPID": String(facts.originalProcessID),
            "recoveredPID": String(getpid()), "sourceVerified": "true", "partialVerified": "true"]
        try DurableFileIO.write(PropertyListEncoder().encode(result), to: root.appendingPathComponent("recovery-result.plist"))
    }
}
