import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DataTransferRecoveryTests {
    @Test("An untouched migration can release its intent and migrate again", arguments: [
        DataTransferRecord.Phase.preparing, .copying, .needsRecovery
    ])
    func cancelAndRetry(phase: DataTransferRecord.Phase) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transfer = try fixture.persist(phase: phase)
        #expect(transfer.isUnstartedSymlinkMigration)
        // The application may keep using the original after an early failure.
        try Data("updated local data".utf8).write(to: fixture.source.appendingPathComponent("new.txt"))
        let identity = try DataPathIdentity.capture(fixture.source)
        try await fixture.mover.cancelUnstartedMigration(operationID: transfer.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try DataPathIdentity.capture(fixture.source) == identity)
        #expect(try fixture.payload(at: fixture.source) == "original")
        #expect(try String(contentsOf: fixture.source.appendingPathComponent("new.txt"), encoding: .utf8) == "updated local data")
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(transfer.backupPath)))

        try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil)
        #expect(try fixture.payload(at: fixture.destination) == "original")
        let retried = try #require(try fixture.store.transfers().first)
        #expect(retried.operationID != transfer.operationID)
        #expect(retried.phase == .awaitingUserVerification)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.source.path) == fixture.destination.path)
    }

    @Test("An untouched regular file can also release its intent and migrate again")
    func regularFileCanCancelAndRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.source)
        let content = Data("ordinary preference file".utf8)
        try content.write(to: fixture.source)
        let transfer = try fixture.persist()
        let identity = try DataPathIdentity.capture(fixture.source)
        try await fixture.mover.cancelUnstartedMigration(operationID: transfer.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try DataPathIdentity.capture(fixture.source) == identity)
        #expect(try Data(contentsOf: fixture.source) == content)
        try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil)
        #expect(try Data(contentsOf: fixture.destination) == content)
        #expect(try fixture.store.transfers().first?.phase == .awaitingUserVerification)
    }

    @Test("Existing copies, backup entries and migration markers keep their recovery record", arguments: [
        "destination", "destinationLink", "backup", "staging", "sourceMarker", "destinationSidecar"
    ])
    func refusesExistingEntries(entry: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staging = entry == "staging" ? fixture.root.appendingPathComponent("staging").path : nil
        let transfer = try fixture.persist(stagingPath: staging)
        let entryURL: URL
        switch entry {
        case "backup": entryURL = URL(fileURLWithPath: try #require(transfer.backupPath))
        case "staging": entryURL = URL(fileURLWithPath: try #require(staging))
        case "sourceMarker": entryURL = fixture.source.appendingPathComponent(".appports-link-metadata.plist")
        case "destinationSidecar": entryURL = fixture.external.appendingPathComponent(".\(fixture.destination.lastPathComponent).appports-link-metadata.plist")
        default: entryURL = fixture.destination
        }
        if entry == "destinationLink" {
            try FileManager.default.createSymbolicLink(at: entryURL, withDestinationURL: fixture.root.appendingPathComponent("absent"))
        } else if entry == "sourceMarker" || entry == "destinationSidecar" {
            try Data("untouched marker".utf8).write(to: entryURL)
        } else {
            try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: false)
            try Data("partial copy".utf8).write(to: entryURL.appendingPathComponent("payload.txt"))
        }
        let identity = try DataPathIdentity.capture(entryURL)
        let ledger = try Data(contentsOf: fixture.file)
        await #expect(throws: (any Error).self) {
            try await fixture.mover.cancelUnstartedMigration(operationID: transfer.operationID)
        }
        #expect(try Data(contentsOf: fixture.file) == ledger)
        #expect(try DataPathIdentity.capture(entryURL) == identity)
        #expect(try fixture.payload(at: fixture.source) == "original")
        if entry == "destination" || entry == "backup" || entry == "staging" {
            #expect(try fixture.payload(at: entryURL) == "partial copy")
        }
    }

    @Test("A replaced or missing original cannot release the record", arguments: ["directory", "link", "file", "missing"])
    func refusesChangedSource(replacement: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transfer = try fixture.persist()
        let retained = fixture.root.appendingPathComponent("retained-original")
        try FileManager.default.moveItem(at: fixture.source, to: retained)
        switch replacement {
        case "directory": try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: false)
        case "link": try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: retained)
        case "file": try Data("replacement".utf8).write(to: fixture.source)
        default: break
        }
        let ledger = try Data(contentsOf: fixture.file)
        await #expect(throws: (any Error).self) {
            try await fixture.mover.cancelUnstartedMigration(operationID: transfer.operationID)
        }
        #expect(try Data(contentsOf: fixture.file) == ledger)
        #expect(try fixture.payload(at: retained) == "original")
    }

    @Test("A missing destination only counts after its parent can be inspected", arguments: ["missing", "file", "brokenLink"])
    func refusesUnavailableParent(replacement: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transfer = try fixture.persist()
        try FileManager.default.moveItem(at: fixture.external, to: fixture.root.appendingPathComponent("detached"))
        if replacement == "file" { try Data("not a directory".utf8).write(to: fixture.external) }
        if replacement == "brokenLink" {
            try FileManager.default.createSymbolicLink(at: fixture.external, withDestinationURL: fixture.root.appendingPathComponent("offline"))
        }
        let ledger = try Data(contentsOf: fixture.file)
        await #expect(throws: (any Error).self) {
            try await fixture.mover.cancelUnstartedMigration(operationID: transfer.operationID)
        }
        #expect(try Data(contentsOf: fixture.file) == ledger)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("A local mount-point directory cannot stand in for an unproven target volume", arguments: [false, true])
    func refusesMissingOrDifferentTargetVolume(legacy: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transfer = try fixture.persist(recordDestinationVolume: !legacy, destinationVolumeUUID: UUID().uuidString)
        let ledger = try Data(contentsOf: fixture.file)
        #expect(FileManager.default.fileExists(atPath: fixture.external.path))
        await #expect(throws: DataOperationSafety.Failure.self) {
            try await fixture.mover.cancelUnstartedMigration(operationID: transfer.operationID)
        }
        #expect(try Data(contentsOf: fixture.file) == ledger)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("The recorded target volume cannot be erased or replaced", arguments: [false, true])
    func targetVolumeIdentityIsImmutable(erase: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        let ledger = try Data(contentsOf: fixture.file)
        transfer.destinationVolumeUUID = erase ? nil : UUID().uuidString
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(transfer) }
        #expect(try Data(contentsOf: fixture.file) == ledger)
    }

    @Test("Online external intents can be released, but detached partial copies stay recorded", arguments: [false, true])
    func mountedVolumeDistinguishesAbsenceFromOfflineData(recordDestinationVolume: Bool) async throws {
        let fixture = try Fixture()
        let image = RecoveryTestImage(mountPoint: fixture.external, imageURL: fixture.root.appendingPathComponent("recovery.dmg"))
        do {
            try await image.prepare()
            let unstarted = try fixture.persist(recordDestinationVolume: recordDestinationVolume)
            try await fixture.mover.cancelUnstartedMigration(operationID: unstarted.operationID)
            #expect(try fixture.store.transfers().isEmpty)

            let interrupted = try fixture.persist(recordDestinationVolume: recordDestinationVolume)
            try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
            try Data("partial copy on detached volume".utf8).write(to: fixture.destination.appendingPathComponent("payload.txt"))
            let ledger = try Data(contentsOf: fixture.file)
            try await image.detach()
            // The mount-point directory remains reachable after this private
            // image is detached, while its partially copied data is now hidden.
            #expect(FileManager.default.fileExists(atPath: fixture.external.path))
            #expect(try DataPathIdentity.capture(fixture.external).volumeUUID == DataPathIdentity.capture(fixture.source).volumeUUID)
            await #expect(throws: DataOperationSafety.Failure.self) {
                try await fixture.mover.cancelUnstartedMigration(operationID: interrupted.operationID)
            }
            #expect(try Data(contentsOf: fixture.file) == ledger)
            try await image.attach()
            #expect(try fixture.payload(at: fixture.destination) == "partial copy on detached volume")
            #expect(try fixture.payload(at: fixture.source) == "original")
            try await image.detach()
            fixture.remove()
        } catch {
            try await image.detach()
            fixture.remove()
            throw error
        }
    }

    @Test("The full record is compared before filesystem validation or cancellation")
    func staleRecordCannotCancel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = try fixture.persist()
        var changed = stale
        changed.recoverableReason = "A newer failure needs its own inspection"
        try fixture.store.updateTransfer(changed)
        let ledger = try Data(contentsOf: fixture.file)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try fixture.store.cancelUnstartedMigration(stale) {
                Issue.record("A stale record must be rejected before filesystem validation")
            }
        }
        #expect(try Data(contentsOf: fixture.file) == ledger)
        #expect(try fixture.store.transfer(operationID: stale.operationID) == changed)
    }

    @Test("Related links or later transfers prevent forgetting their predecessor", arguments: [false, true])
    func relatedRecordsPreventCancellation(linked: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transfer = try fixture.persist()
        if linked {
            try fixture.store.upsertManagedLink(ManagedDataLinkRecord(operationID: transfer.operationID,
                originalPath: transfer.originalPath, destinationPath: transfer.destinationPath,
                destinationIdentity: transfer.sourceIdentity, appName: transfer.appName, dataDirType: transfer.dataDirType))
        } else {
            let later = DataTransferRecord(mode: .symlink, direction: .restore,
                appName: "Later", dataDirType: DataDirType.custom.rawValue,
                originalPath: fixture.root.appendingPathComponent("later-local").path,
                activePath: fixture.root.appendingPathComponent("later-external").path,
                destinationPath: fixture.root.appendingPathComponent("later-local").path,
                sourceIdentity: transfer.sourceIdentity, priorOperationID: transfer.operationID)
            try fixture.store.beginTransfer(later)
        }
        let ledger = try Data(contentsOf: fixture.file)
        await #expect(throws: (any Error).self) {
            try await fixture.mover.cancelUnstartedMigration(operationID: transfer.operationID)
        }
        #expect(try Data(contentsOf: fixture.file) == ledger)
    }

    @Test("A failed cancellation save leaves the durable intent intact")
    func failedSaveKeepsIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transfer = try fixture.persist()
        let ledger = try Data(contentsOf: fixture.file)
        let refusingStore = ContainerMountStore(fileURL: fixture.file, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let mover = DataDirMover(homeDir: fixture.home, store: refusingStore, runner: NoWriters())
        await #expect(throws: (any Error).self) { try await mover.cancelUnstartedMigration(operationID: transfer.operationID) }
        #expect(try Data(contentsOf: fixture.file) == ledger)
        #expect(try fixture.store.transfer(operationID: transfer.operationID) == transfer)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("An awaited progress callback cannot cancel its still-running migration")
    func activeMigrationCannotCancelItself() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mover = fixture.mover
        try await mover.migrate(item: fixture.item, to: fixture.external) { progress in
            guard progress.copiedBytes == 0, progress.currentFile == fixture.source.lastPathComponent else { return }
            do {
                let transfer = try #require(try fixture.store.transfers().first)
                #expect(transfer.isUnstartedSymlinkMigration)
                await #expect(throws: DataOperationSafety.Failure.self) {
                    try await mover.cancelUnstartedMigration(operationID: transfer.operationID)
                }
            } catch { Issue.record(error) }
        }
        #expect(try fixture.store.transfers().first?.phase == .awaitingUserVerification)
        #expect(try fixture.payload(at: fixture.destination) == "original")
    }

    @Test("Permission failures are checked before creating any intent or destination", .enabled(if: geteuid() != 0), arguments: [false, true])
    func permissionPreflightLeavesNoIntent(missingParent: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(chmod(fixture.external.path, 0o500) == 0)
        let target = missingParent ? fixture.external.appendingPathComponent("new/parent") : fixture.external
        await #expect(throws: DataDirError.self) {
            try await fixture.mover.migrate(item: fixture.item, to: target, progressHandler: nil)
        }
        #expect(try fixture.store.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(fixture.source.lastPathComponent).path))
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("A copy preflight failure releases its untouched intent for retry", .enabled(if: geteuid() != 0))
    func failedCopyPreflightRemainsRetryable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = fixture.source.appendingPathComponent("payload.txt")
        #expect(chmod(payload.path, 0) == 0)
        await #expect(throws: DataDirError.self) {
            try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil)
        }
        #expect(try fixture.store.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(chmod(payload.path, 0o600) == 0)
        try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil)
        #expect(try fixture.payload(at: fixture.destination) == "original")
    }

    private struct NoWriters: ShellCommandRunning {
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let home: URL
        let source: URL
        let external: URL
        let destination: URL
        let file: URL
        let store: ContainerMountStore
        var mover: DataDirMover { DataDirMover(homeDir: home, store: store, runner: NoWriters()) }
        var item: DataDirItem { DataDirItem(name: "Fixture", path: source, type: .custom, priority: .optional, description: "") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DataTransferRecovery-\(UUID())").resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            source = home.appendingPathComponent("Payload")
            external = root.appendingPathComponent("External")
            destination = external.appendingPathComponent(source.lastPathComponent)
            file = root.appendingPathComponent("records.plist")
            store = ContainerMountStore(fileURL: file)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("payload.txt"))
        }

        func persist(phase: DataTransferRecord.Phase = .needsRecovery, stagingPath: String? = nil,
                     recordDestinationVolume: Bool = true, destinationVolumeUUID: String? = nil) throws -> DataTransferRecord {
            let id = UUID()
            let backup = source.deletingLastPathComponent().appendingPathComponent(".appports-migration-backup-\(source.lastPathComponent)-\(id)")
            var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .migrate,
                appName: "Fixture", dataDirType: DataDirType.custom.rawValue,
                originalPath: source.path, activePath: source.path, destinationPath: destination.path,
                backupPath: backup.path, stagingPath: stagingPath, sourceIdentity: try DataPathIdentity.capture(source),
                destinationVolumeUUID: recordDestinationVolume ? try destinationVolumeUUID ?? DataPathIdentity.capture(external).volumeUUID : nil)
            try store.beginTransfer(transfer)
            if phase != .preparing {
                transfer.phase = phase
                transfer.recoverableReason = phase == .needsRecovery ? "Copy failed before creating its destination" : nil
                try store.updateTransfer(transfer)
            }
            return transfer
        }

        func payload(at directory: URL) throws -> String {
            try String(contentsOf: directory.appendingPathComponent("payload.txt"), encoding: .utf8)
        }

        func remove() {
            _ = chmod(external.path, 0o700)
            _ = chmod(source.appendingPathComponent("payload.txt").path, 0o600)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// Private, disposable disk images exercise real mount disappearance without
/// changing any user disk's settings or contents.
private actor RecoveryTestImage {
    private let mountPoint: URL
    private let imageURL: URL
    private var attached = false
    private var devicePath: String?

    init(mountPoint: URL, imageURL: URL) {
        self.mountPoint = mountPoint
        self.imageURL = imageURL
    }

    func prepare() async throws {
        _ = try await run(["create", "-size", "64m", "-fs", "APFS", "-volname", "AppPortsRecoveryTest", imageURL.path])
        try await attach()
    }

    func attach() async throws {
        let result = try await run(["attach", "-plist", "-nobrowse", "-owners", "off", "-mountpoint", mountPoint.path, imageURL.path])
        attached = true
        devicePath = Self.attachedDevicePath(in: result.standardOutput)
    }

    func detach() async throws {
        guard attached else { return }
        _ = try await run(["detach", devicePath ?? mountPoint.path])
        attached = false
        devicePath = nil
    }

    private static func attachedDevicePath(in output: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: output, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            return nil
        }
        return entities.compactMap { $0["dev-entry"] as? String }
            .first { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil }
    }

    private func run(_ arguments: [String]) async throws -> ShellCommandResult {
        let result = try await ProcessCommandRunner().run(executable: "/usr/bin/hdiutil", arguments: arguments, timeout: 45)
        try #require(result.status == 0 && !result.timedOut, "\(arguments): \(result.combinedText)")
        return result
    }
}
