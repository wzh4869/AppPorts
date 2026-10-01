import Foundation
import Testing
@testable import AppPorts

struct DataTransferReentryTests {
    enum SourceState: Sendable { case directory, absent, link }
    enum CopyState: Sendable { case absent, partial, complete }

    struct PhaseCase: Sendable {
        let phase: DataTransferRecord.Phase
        let source: SourceState
        let copy: CopyState
        let backup: Bool
        let indexed: Bool
        let status: String
    }

    // Hand-defined persisted interruption states, not process-kill injection.
    static let cases: [PhaseCase] = [
        .init(phase: .preparing, source: .directory, copy: .absent, backup: false, indexed: false, status: DataDirStatus.local),
        .init(phase: .copying, source: .directory, copy: .partial, backup: false, indexed: false, status: DataDirStatus.local),
        .init(phase: .verified, source: .directory, copy: .complete, backup: false, indexed: false, status: DataDirStatus.local),
        .init(phase: .switching, source: .absent, copy: .complete, backup: true, indexed: false, status: DataDirStatus.missing),
        .init(phase: .awaitingUserVerification, source: .link, copy: .complete, backup: true, indexed: true, status: DataDirStatus.linked),
        .init(phase: .cleanupRequested, source: .link, copy: .complete, backup: true, indexed: true, status: DataDirStatus.linked),
        .init(phase: .needsRecovery, source: .link, copy: .complete, backup: true, indexed: true, status: DataDirStatus.linked)
    ]

    @Test("Every durable phase survives two cold store/scanner opens without resuming work", arguments: cases)
    func persistedPhaseIsReadOnly(state: PhaseCase) async throws {
        #expect(Set(Self.cases.map(\.phase)) == Set(DataTransferRecord.Phase.allCases))
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = try await fixture.persist(state)
        let ledger = try Data(contentsOf: fixture.file)
        let sourceIdentity = state.source == .absent ? nil : try DataPathIdentity.capture(fixture.source)
        let trees = [fixture.source, fixture.destination, fixture.backup].filter {
            FileManager.default.fileExists(atPath: $0.path) && (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) == nil
        }
        let before = try trees.map { try TreeCopySession.snapshot(at: $0) }
        let runner = FakeDiskCommandRunner()

        for _ in 0..<2 {
            let store = ContainerMountStore(fileURL: fixture.file)
            let scanner = DataDirScanner(homeDir: fixture.home, mountStore: store,
                isMountPoint: { _ in false }, isVolumeOnline: { _ in false }, isSandboxedApplication: { _ in false })
            let migrator = ContainerVolumeMigrator(disk: DiskUtility(runner: runner), store: store,
                stagingMountRootURL: fixture.root.appendingPathComponent("mounts"),
                isMountPoint: { _ in false }, mountedVolumePath: { _ in nil }, mountedVolumeUUID: { _ in nil },
                volumeUUIDMarker: { _ in nil }, synchronizeAgent: { _ in Issue.record("Reentry must not install an agent") },
                availableCapacity: { _ in nil }, mountFlags: { _ in nil }, homeDirectory: fixture.home, safetyRunner: runner)
            let rows = await scanner.scanLibraryDirs(for: fixture.app, externalRootURL: fixture.external)
            let row = try #require(rows.first { $0.path.standardizedFileURL.path == fixture.source.path })
            #expect(row.recoveryOperationID == expected.operationID)
            #expect(!row.isMigratable)
            #expect(row.status == state.status)
            #expect(row.hasManagedLinkRecord == state.indexed)
            #expect(await migrator.remountAvailableRecords().isEmpty)
            let inspection = try store.recordsForInspection()
            #expect(inspection.validationError == nil)
            #expect(inspection.mounts.isEmpty)
            #expect(inspection.cleanups.isEmpty)
            #expect(inspection.remountInterventions.isEmpty)
            #expect(inspection.transfers == [expected])
            #expect(try store.unfinishedTransfers() == [expected])
            #expect(try store.transfer(operationID: expected.operationID) == expected)
            #expect(inspection.managedLinks.count == (state.indexed ? 1 : 0))
            if state.indexed {
                let link = try #require(inspection.managedLinks.first)
                #expect(link.operationID == expected.operationID)
                #expect(link.originalPath == fixture.source.path)
                #expect(link.destinationPath == fixture.destination.path)
                #expect(link.destinationIdentity == expected.destinationIdentity)
            }
            #expect(expected.phase == state.phase)
            #expect(expected.originalPath == fixture.source.path)
            #expect(expected.destinationPath == fixture.destination.path)
            #expect(expected.backupPath == fixture.backup.path)
            #expect(expected.stagingPath == fixture.staging.path)
            #expect(expected.activePath == (state.source == .link ? fixture.destination.path : fixture.source.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
            #expect(FileManager.default.fileExists(atPath: fixture.backup.path) == state.backup)
            switch state.source {
            case .absent:
                #expect(throws: (any Error).self) { try DataPathIdentity.capture(fixture.source) }
            case .directory:
                #expect(try String(contentsOf: fixture.source.appendingPathComponent("payload.txt"), encoding: .utf8) == "complete original")
                #expect(try DataPathIdentity.capture(fixture.source) == expected.sourceIdentity)
            case .link:
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.source.path) == fixture.destination.path)
                #expect(try DataPathIdentity.capture(fixture.source) == sourceIdentity)
            }
            switch state.copy {
            case .absent:
                #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
                #expect(expected.baseline == nil)
                #expect(expected.destinationIdentity == nil)
            case .partial:
                #expect(try String(contentsOf: fixture.destination.appendingPathComponent("payload.txt"), encoding: .utf8) == "partial")
                #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("nested/second.txt").path))
                #expect(expected.baseline == nil)
                #expect(expected.destinationIdentity == nil)
            case .complete:
                #expect(try String(contentsOf: fixture.destination.appendingPathComponent("payload.txt"), encoding: .utf8) == "complete original")
                #expect(try String(contentsOf: fixture.destination.appendingPathComponent("nested/second.txt"), encoding: .utf8) == "second original")
                #expect(try DataPathIdentity.capture(fixture.destination) == expected.destinationIdentity)
                let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: #require(expected.baseline))
                #expect(baseline.entries.map(\.path) == ["", "nested", "nested/second.txt", "payload.txt"])
                try TreeCopySession.verifyCopy(at: fixture.destination, against: baseline)
                try TreeCopySession.verifyUnchanged(at: state.backup ? fixture.backup : fixture.source, against: baseline)
            }
            if state.backup {
                #expect(try DataPathIdentity.capture(fixture.backup) == expected.sourceIdentity)
                #expect(expected.backupIdentity == expected.sourceIdentity)
                #expect(try String(contentsOf: fixture.backup.appendingPathComponent("payload.txt"), encoding: .utf8) == "complete original")
            } else {
                #expect(expected.backupIdentity == nil)
            }
            #expect(try trees.map { try TreeCopySession.snapshot(at: $0) } == before)
            #expect(try Data(contentsOf: fixture.file) == ledger)
            #expect(runner.calls.isEmpty)
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let external: URL
        let source: URL
        let destination: URL
        let backup: URL
        let staging: URL
        let file: URL
        let app: AppItem

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DataTransferReentryTests-\(UUID())").resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            external = root.appendingPathComponent("External")
            source = home.appendingPathComponent("Library/Containers/com.example.phase/Data/Documents/Payload")
            destination = external.appendingPathComponent("Containers/com.example.phase/Data/Documents/Payload")
            backup = source.deletingLastPathComponent().appendingPathComponent(".Payload.backup")
            staging = source.deletingLastPathComponent().appendingPathComponent(".Payload.staging")
            file = root.appendingPathComponent("records.plist")
            let appURL = root.appendingPathComponent("Applications/Phase.app")
            let executable = appURL.appendingPathComponent("Contents/MacOS/Phase")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic executable".utf8).write(to: executable)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.phase", "CFBundleName": "Phase"], format: .xml, options: 0)
            try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
            app = AppItem(name: "Phase.app", path: appURL, status: "本地")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("complete original".utf8).write(to: source.appendingPathComponent("payload.txt"))
            try Data("second original".utf8).write(to: source.appendingPathComponent("nested/second.txt"))
        }

        func persist(_ state: PhaseCase) async throws -> DataTransferRecord {
            let store = ContainerMountStore(fileURL: file)
            var transfer = DataTransferRecord(mode: .symlink, direction: .migrate, sourceID: source.path,
                appName: "Phase", bundleIdentifier: "com.example.phase", dataDirType: DataDirType.containers.rawValue,
                originalPath: source.path, activePath: source.path, destinationPath: destination.path,
                backupPath: backup.path, stagingPath: staging.path, sourceIdentity: try DataPathIdentity.capture(source),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try store.beginTransfer(transfer)
            if state.phase == .preparing { return transfer }
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            if state.phase == .copying {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try Data("partial".utf8).write(to: destination.appendingPathComponent("payload.txt"))
                return transfer
            }
            transfer.baseline = try PropertyListEncoder().encode(await TreeCopySession().copy(from: source, to: destination))
            transfer.destinationIdentity = try DataPathIdentity.capture(destination)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            if state.phase == .verified { return transfer }
            transfer.phase = .switching
            try store.updateTransfer(transfer)
            try DataTreeRelocator.move(source, to: backup)
            transfer.backupIdentity = try DataPathIdentity.capture(backup)
            try store.updateTransfer(transfer)
            if state.phase == .switching { return transfer }
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: destination)
            transfer.activePath = destination.path
            try store.commitMigration(record: nil, transfer: transfer)
            transfer.phase = .awaitingUserVerification
            if state.phase == .cleanupRequested {
                try store.requestCleanup(operationID: transfer.operationID)
                transfer.phase = .cleanupRequested
            } else if state.phase == .needsRecovery {
                transfer.phase = .needsRecovery
                transfer.recoverableReason = "Synthetic persisted interruption after switching"
                try store.updateTransfer(transfer)
            }
            return transfer
        }
    }
}
