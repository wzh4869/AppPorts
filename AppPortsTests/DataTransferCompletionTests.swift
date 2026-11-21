import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DataTransferCompletionTests {
    @Test("Reopened task selects its own directories and a targeted retry preserves a sibling task")
    @MainActor
    func scopedRecoveryAfterRelaunch() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let second = f.home.appendingPathComponent("More")
        let sibling = f.home.appendingPathComponent("Other")
        for url in [second, sibling] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try f.writePayload(url.lastPathComponent, at: url)
        }
        let history = MigrationTaskHistoryStore(fileURL: f.root.appendingPathComponent("history.json"))
        func center() -> MigrationTaskCenter {
            MigrationTaskCenter(historyStore: history, operationState: AppOperationState(notificationCenter: NotificationCenter()),
                makeOperationLock: { OperationLock(fileURL: f.root.appendingPathComponent("task.lock"), writerAdmissionCheck: {}) })
        }
        let tasks = center()
        func migrate(_ urls: [URL]) async throws -> UUID {
            let id = tasks.submit(title: "Same app", category: .appData,
                resources: MigrationResources(paths: urls + [f.home], keys: ["application:org.example.shared"], subjectPaths: urls),
                operation: { _ in
                    for url in urls {
                        let item = DataDirItem(name: "Same app", path: url, type: .custom, priority: .optional, description: "")
                        try await f.mover.migrate(item: item, to: f.external, progressHandler: nil)
                    }
                    return "Inspect retained copies"
                })
            let job = try #require(tasks.detail)
            await job.worker?.value
            #expect(job.message == "Inspect retained copies")
            return id
        }
        let a = try await migrate([f.source, second])
        let b = try await migrate([sibling])
        let reloaded = try #require(center().jobs.first { $0.id == a })
        let scope = DataTaskRecoveryScope(jobID: a, resources: reloaded.resources, startedAt: reloaded.startedAt, elapsed: reloaded.elapsed)
        let store = ContainerMountStore(fileURL: f.file)
        let records = try store.transfers()
        let selected = scope.operationIDs(transfers: records, materials: [])
        let owned = records.filter { $0.migrationTaskID == a }
        #expect(owned.count == 2)
        #expect(selected == Set(owned.map(\.id)))
        let other = try #require(records.first { $0.migrationTaskID == b })
        try store.setCleanupDisposition(.deferred, expected: other)
        let untouched = try #require(try store.transfer(operationID: other.id))
        let otherCopy = URL(fileURLWithPath: try #require(other.backupPath))
        let before = try DataPathIdentity.capture(otherCopy)
        let chosen = try #require(owned.first)
        let warnings = await OperationMaintenance.retryDataTransfer(chosen.id, store: store,
            migrator: ContainerVolumeMigrator(store: store), mover: f.mover)
        #expect(warnings.isEmpty)
        #expect(try store.transfer(operationID: chosen.id) == nil)
        #expect(try store.transfer(operationID: other.id) == untouched)
        #expect(try DataPathIdentity.capture(otherCopy) == before)
        #expect(try f.payload(at: otherCopy) == "Other")
        #expect(try f.payload(at: sibling) == "Other")
    }

    @Test("Legacy history requires a unique exact directory during the original task")
    func legacyScopeRejectsReusedPaths() throws {
        let f = try Fixture()
        defer { f.remove() }
        let resources = try JSONDecoder().decode(MigrationResources.self, from: JSONSerialization.data(withJSONObject:
            ["paths": [f.home.path, f.source.path], "subjectPaths": [f.source.path], "keys": ["application:shared"]]))
        let start = Date()
        let scope = DataTaskRecoveryScope(jobID: UUID(), resources: resources, startedAt: start, elapsed: 20)
        let identity = try DataPathIdentity.capture(f.source)
        func record(_ path: String, _ seconds: TimeInterval) -> DataTransferRecord {
            DataTransferRecord(mode: .symlink, direction: .migrate, appName: "Same app", dataDirType: "custom",
                originalPath: path, activePath: path, destinationPath: f.destination.path,
                sourceIdentity: identity, createdAt: start.addingTimeInterval(seconds))
        }
        let one = record(f.source.path, 2), old = record(f.source.path, -100)
        let sibling = record(f.home.appendingPathComponent("Other").path, 2)
        #expect(scope.operationIDs(transfers: [one, sibling], materials: []) == [one.id])
        #expect(scope.operationIDs(transfers: [old, sibling], materials: []).isEmpty)
        #expect(scope.operationIDs(transfers: [one, sibling], materials: [.init(transfer: old, reason: "retained")]).isEmpty)
        let fresh = DataTaskRecoveryScope(jobID: UUID(), resources: MigrationResources(paths: [f.source]), startedAt: start, elapsed: 20)
        #expect(fresh.operationIDs(transfers: [one], materials: []).isEmpty)
    }

    @Test("Restoration preserves the application identity from retained history when the link index is missing")
    func restoreKeepsLaunchIdentityFromHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var item = fixture.item
        item.associatedBundleIdentifier = "org.example.launch-protection"
        try await fixture.mover.migrate(item: item, to: fixture.external, progressHandler: nil)
        var journal = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.file), format: nil) as? [String: Any])
        journal["managedLinks"] = []
        try PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0).write(to: fixture.file)
        try await fixture.mover.restore(item: fixture.item, progressHandler: nil)
        let restored = try #require(try fixture.store.transfers().first(where: { $0.direction == .restore }))
        #expect(restored.bundleIdentifier == item.associatedBundleIdentifier)
        #expect(try fixture.payload(at: fixture.source) == "original")
        let directory = fixture.file.deletingLastPathComponent().appendingPathComponent("launch-locks", isDirectory: true)
        let launch = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.launch-protection", migrating: false, directory: directory)
        defer { withExtendedLifetime(launch) {} }
        await #expect(throws: DataOperationSafety.Failure.self) {
            _ = try await fixture.mover.resumeVerifiedTransfer(operationID: restored.operationID, progressHandler: nil)
        }
    }

    @Test("Ordinary symlink round trips stay within the reduced content-read budget")
    func contentReadBudget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Double(try Data(contentsOf: fixture.source.appendingPathComponent("payload.txt")).count)
        let migration = DataTransferSession()
        let moved = try await DataTransferSession.$current.withValue(migration) {
            try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        }
        #expect(moved.cleanupWarning == nil)
        #expect(try #require(migration.measurements["hashReadBytes"]) <= 6 * bytes)
        let restore = DataTransferSession()
        let restored = try await DataTransferSession.$current.withValue(restore) {
            try await fixture.mover.restoreAndComplete(item: fixture.item, progressHandler: nil)
        }
        #expect(restored.cleanupWarning == nil)
        #expect(try #require(restore.measurements["hashReadBytes"]) <= 5 * bytes)
        #expect(try fixture.payload(at: fixture.source) == "original")
        #expect(try fixture.store.transfers().isEmpty)
    }

    @Test("Deferred readback rejects late source and destination changes before recording verification",
          arguments: [DataTransferRecord.Direction.migrate, .restore], [false, true])
    func lateCopyChanges(direction: DataTransferRecord.Direction, changeDestination: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if direction == .restore {
            _ = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        }
        let source = direction == .migrate ? fixture.source : fixture.destination
        let progress: FileCopier.ProgressHandler = { value in
            guard value.currentFile.isEmpty, value.copiedBytes == value.totalBytes, value.totalBytes > 0 else { return }
            do {
                let pending = try #require(try fixture.store.transfers().first)
                #expect(pending.baseline == nil)
                let changed = changeDestination ? URL(fileURLWithPath: try #require(pending.preparationPath)) : source
                try fixture.writePayload("late data", at: changed)
            } catch { Issue.record(error) }
        }
        await #expect(throws: (any Error).self) {
            if direction == .migrate {
                try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: progress)
            } else {
                try await fixture.mover.restore(item: fixture.item, progressHandler: progress)
            }
        }
        let pending = try #require(try fixture.store.transfers().first)
        #expect(pending.baseline == nil)
        #expect(!pending.isDataSwitchComplete)
        #expect(try fixture.payload(at: source) == (changeDestination ? "original" : "late data"))
        #expect(fixture.isRealDirectory(fixture.source) == (direction == .migrate))
    }

    @Test("Completed user flows can migrate, restore and migrate to the same target again")
    func repeatedRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mover = fixture.mover
        let migration = try await mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        #expect(migration.cleanupWarning == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.store.managedLinks().count == 1)
        #expect(fixture.source.resolvingSymlinksInPath().path == fixture.destination.path)

        let restore = try await mover.restoreAndComplete(item: fixture.item, progressHandler: nil)
        #expect(restore.cleanupWarning == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.store.managedLinks().isEmpty)
        #expect(fixture.isRealDirectory(fixture.source))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try fixture.payload(at: fixture.source) == "original")

        try fixture.writePayload("latest local data", at: fixture.source)
        let next = try await mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        #expect(next.cleanupWarning == nil)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.payload(at: fixture.destination) == "latest local data")
        #expect(fixture.source.resolvingSymlinksInPath().path == fixture.destination.path)
    }

    @Test("A new migration clears same-path predecessor cleanup presentation")
    func migrateAfterRetainedRestoreStartsNewCopyPresentation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.retainedRoundTrip()
        let observer = DataTransferProgress()
        let result = try await observer.track { update in
            try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external) { value in
                await update(value)
                if value.stage == .copying, value.showsByteProgress {
                    #expect(!observer.snapshot().hasEnteredCleanup)
                    #expect(!observer.snapshot().hasEnteredEntrySwitch)
                    #expect(observer.snapshot().directoryStep == 2)
                    #expect(observer.snapshot().unitFraction <= 0.55)
                }
            }
        }
        #expect(result.cleanupWarning == nil)
        #expect(observer.snapshot().directoryStep == 5)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.payload(at: fixture.destination) == "original")
        #expect(fixture.source.resolvingSymlinksInPath().path == fixture.destination.path)
    }

    @Test("Explicit cleanup of a completed restore removes its retained ancestors oldest first")
    func retainedLineageOrder() async throws {
        let writes = LedgerWrites()
        let fixture = try Fixture(writeData: writes.write)
        defer { fixture.remove() }
        let records = try await fixture.retainedRoundTrip()
        #expect(records.count == 2)
        let originalBackup = URL(fileURLWithPath: try #require(records[0].backupPath))
        let restoredIdentity = try DataPathIdentity.capture(fixture.source)

        let observer = DataTransferProgress()
        try await observer.track { _ in
            try await fixture.mover.cleanupRetainedLineage(operationID: records[1].operationID)
        }
        #expect(observer.snapshot().directoryStep == 5)
        #expect(observer.snapshot().hasEnteredCleanup)

        #expect(writes.cleanupOrder == records.map(\.operationID))
        #expect(try fixture.store.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: originalBackup.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try DataPathIdentity.capture(fixture.source) == restoredIdentity)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("A new user migration first completes the old restore chain and reuses its old target")
    func repeatMigrationCompletesHistoricalRestore() async throws {
        let writes = LedgerWrites()
        let fixture = try Fixture(writeData: writes.write)
        defer { fixture.remove() }
        let records = try await fixture.retainedRoundTrip()
        let originalBackup = URL(fileURLWithPath: try #require(records[0].backupPath))

        let result = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)

        #expect(result.cleanupWarning == nil)
        #expect(Array(writes.cleanupOrder.prefix(2)) == records.map(\.operationID))
        #expect(writes.cleanupOrder.count == 3)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: originalBackup.path))
        #expect(fixture.source.resolvingSymlinksInPath().path == fixture.destination.path)
        let link = try #require(try fixture.store.managedLinks().first)
        #expect(!records.contains(where: { $0.operationID == link.operationID }))
        #expect(try fixture.payload(at: fixture.destination) == "original")
    }

    @Test("A cleanup intent write failure is a warning after a successful data switch", arguments: [
        DataTransferRecord.Direction.migrate, .restore
    ])
    func completionFailureIsNotMigrationFailure(direction: DataTransferRecord.Direction) async throws {
        let writes = LedgerWrites()
        let fixture = try Fixture(writeData: writes.write)
        defer { fixture.remove() }
        if direction == .restore {
            try await fixture.mover.migrate(item: fixture.item, to: fixture.external, progressHandler: nil)
        }
        writes.rejectCleanupRequests(true)
        let result: DataDirMover.CompletionResult
        if direction == .restore {
            result = try await fixture.mover.restoreAndComplete(item: fixture.item, progressHandler: nil)
            #expect(fixture.isRealDirectory(fixture.source))
            #expect(try fixture.store.managedLinks().isEmpty)
        } else {
            result = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
            #expect(fixture.source.resolvingSymlinksInPath().path == fixture.destination.path)
            #expect(try fixture.store.managedLinks().count == 1)
        }
        #expect(result.cleanupWarning != nil)
        let records = try fixture.store.transfers()
        #expect(records.count == (direction == .restore ? 2 : 1))
        #expect(records.allSatisfy { $0.phase == .awaitingUserVerification && $0.recoverableReason == nil })
        for record in records {
            #expect(FileManager.default.fileExists(atPath: try #require(record.backupPath)))
        }
        #expect(try fixture.payload(at: fixture.source) == "original")

        writes.rejectCleanupRequests(false)
        let terminal = try #require(records.last)
        try await fixture.mover.cleanupRetainedLineage(operationID: terminal.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("A later cleanup failure keeps the remaining restore retryable without its cleaned ancestor")
    func laterLineageFailureCanRetry() async throws {
        let writes = LedgerWrites()
        let fixture = try Fixture(writeData: writes.write)
        defer { fixture.remove() }
        let records = try await fixture.retainedRoundTrip()
        writes.rejectCleanupRequest(operationID: records[1].operationID)

        await #expect(throws: (any Error).self) {
            try await fixture.mover.cleanupRetainedLineage(operationID: records[1].operationID)
        }

        #expect(try fixture.store.transfer(operationID: records[0].operationID) == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(records[0].backupPath)))
        let remaining = try #require(try fixture.store.transfer(operationID: records[1].operationID))
        #expect(remaining.phase == .awaitingUserVerification)
        #expect(remaining.recoverableReason == nil)
        #expect(try fixture.payload(at: fixture.source) == "original")
        #expect(try fixture.payload(at: fixture.destination) == "original")

        writes.rejectCleanupRequest(operationID: nil)
        try await fixture.mover.cleanupRetainedLineage(operationID: remaining.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("A completed data switch remains successful if the deletion-completion write fails")
    func cleanupCompletionWriteFailurePreservesActiveData() async throws {
        let writes = LedgerWrites()
        writes.rejectCleanupCompletion(true)
        let fixture = try Fixture(writeData: writes.write)
        defer { fixture.remove() }

        let result = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)

        #expect(result.cleanupWarning != nil)
        #expect(fixture.source.resolvingSymlinksInPath().path == fixture.destination.path)
        #expect(try fixture.payload(at: fixture.source) == "original")
        #expect(try fixture.store.managedLinks().count == 1)
        let retained = try #require(try fixture.store.transfers().first)
        #expect(retained.phase == .cleanupRequested)
        #expect(retained.cleanupParentIdentity != nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(retained.backupPath)))
        writes.rejectCleanupCompletion(false)
        try await fixture.mover.cleanupRetainedTransfer(operationID: retained.operationID)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("Legitimate local edits after a historical restore are migrated without extra review")
    func changedRestoredDataCanMigrateAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let records = try await fixture.retainedRoundTrip()
        try fixture.writePayload("updated after restore", at: fixture.source)
        let result = try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        #expect(result.cleanupWarning == nil)
        #expect(try fixture.payload(at: fixture.destination) == "updated after restore")
        #expect(try fixture.store.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(records[0].backupPath)))
    }

    @Test("Automatic repeat migration never removes an unrelated existing destination")
    func arbitraryDestinationIsPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let records = try await fixture.retainedRoundTrip()
        let otherBase = fixture.root.appendingPathComponent("OtherExternal")
        let unrelated = otherBase.appendingPathComponent(fixture.source.lastPathComponent)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try fixture.writePayload("unrelated data", at: unrelated)
        let ledger = try Data(contentsOf: fixture.file)

        await #expect(throws: DataDirError.self) {
            try await fixture.mover.migrateAndComplete(item: fixture.item, to: otherBase, progressHandler: nil)
        }

        #expect(try Data(contentsOf: fixture.file) == ledger)
        #expect(try fixture.payload(at: unrelated) == "unrelated data")
        #expect(try fixture.payload(at: fixture.source) == "original")
        #expect(try fixture.payload(at: fixture.destination) == "original")
        #expect(FileManager.default.fileExists(atPath: try #require(records[0].backupPath)))
    }

    @Test("A replacement at the recorded old target cannot inherit permission for automatic cleanup")
    func replacedRetainedTargetIsPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let records = try await fixture.retainedRoundTrip()
        let preserved = fixture.root.appendingPathComponent("PreservedExternal")
        try FileManager.default.moveItem(at: fixture.destination, to: preserved)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        try fixture.writePayload("different directory", at: fixture.destination)
        let ledger = try Data(contentsOf: fixture.file)

        await #expect(throws: DataDirMover.CompletionError.self) {
            try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        }

        #expect(try Data(contentsOf: fixture.file) == ledger)
        #expect(try fixture.payload(at: fixture.destination) == "different directory")
        #expect(try fixture.payload(at: preserved) == "original")
        #expect(FileManager.default.fileExists(atPath: try #require(records[0].backupPath)))
    }

    @Test("Recovery records still prevent repeat migration without adding another intent")
    func unfinishedRestoreStillBlocks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let records = try await fixture.retainedRoundTrip()
        var terminal = records[1]
        terminal.phase = .needsRecovery
        terminal.recoverableReason = "An unfinished recovery needs inspection"
        try fixture.store.updateTransfer(terminal)
        let ledger = try Data(contentsOf: fixture.file)

        await #expect(throws: (any Error).self) {
            try await fixture.mover.migrateAndComplete(item: fixture.item, to: fixture.external, progressHandler: nil)
        }

        #expect(try Data(contentsOf: fixture.file) == ledger)
        #expect(try fixture.payload(at: fixture.source) == "original")
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

        init(writeData: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DataTransferCompletion-\(UUID())").resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            source = home.appendingPathComponent("Payload")
            external = root.appendingPathComponent("External")
            destination = external.appendingPathComponent(source.lastPathComponent)
            file = root.appendingPathComponent("records.plist")
            store = ContainerMountStore(fileURL: file, writeData: writeData)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("payload.txt"))
        }

        func retainedRoundTrip() async throws -> [DataTransferRecord] {
            let mover = self.mover
            try await mover.migrate(item: item, to: external, progressHandler: nil)
            let migration = try #require(try store.transfers().first)
            try await mover.restore(item: item, progressHandler: nil)
            let restoration = try #require(try store.transfers().first(where: { $0.priorOperationID == migration.operationID }))
            return [migration, restoration]
        }

        func payload(at directory: URL) throws -> String {
            try String(contentsOf: directory.appendingPathComponent("payload.txt"), encoding: .utf8)
        }

        func writePayload(_ value: String, at directory: URL) throws {
            try Data(value.utf8).write(to: directory.appendingPathComponent("payload.txt"))
        }

        func isRealDirectory(_ url: URL) -> Bool {
            var value = stat()
            return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Each fixture has its own writer and lock, including when parameterized
    /// cases execute concurrently. Only fixture ledgers are ever intercepted.
    private final class LedgerWrites: @unchecked Sendable {
        private let lock = NSLock()
        private var rejectedRequests = false
        private var rejectedOperationID: UUID?
        private var rejectedCompletion = false
        private var pendingCleanupIDs: Set<UUID> = []
        private var recordedCleanupOrder: [UUID] = []

        var cleanupOrder: [UUID] {
            lock.lock()
            defer { lock.unlock() }
            return recordedCleanupOrder
        }

        func rejectCleanupRequests(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            rejectedRequests = value
        }

        func rejectCleanupCompletion(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            rejectedCompletion = value
        }

        func rejectCleanupRequest(operationID: UUID?) {
            lock.lock()
            defer { lock.unlock() }
            rejectedOperationID = operationID
        }

        func write(_ data: Data, _ url: URL) throws {
            lock.lock()
            defer { lock.unlock() }
            let document = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let records = document["transfers"] as? [[String: Any]] ?? []
            let currentIDs = Set(records.compactMap { ($0["operationID"] as? String).flatMap(UUID.init(uuidString:)) })
            let requestedIDs = records.compactMap { record -> UUID? in
                guard record["phase"] as? String == DataTransferRecord.Phase.cleanupRequested.rawValue,
                      let value = record["operationID"] as? String else { return nil }
                return UUID(uuidString: value)
            }
            if rejectedRequests && !requestedIDs.isEmpty { throw CocoaError(.fileWriteNoPermission) }
            if let rejectedOperationID, requestedIDs.contains(rejectedOperationID) { throw CocoaError(.fileWriteNoPermission) }
            if rejectedCompletion && !pendingCleanupIDs.isSubset(of: currentIDs) { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
            for id in requestedIDs where !recordedCleanupOrder.contains(id) { recordedCleanupOrder.append(id) }
            pendingCleanupIDs = Set(requestedIDs)
        }
    }
}
