import Darwin
import Foundation
import XCTest
@testable import AppPorts

/// The coordinator creates the image. Ordinary regression runs skip this test.
/// All disk commands are real, but their mutation authority is restricted to
/// freshly created volumes in that exact private image's APFS container.
final class AppPortsRealMountValidationTests: XCTestCase {
    func testPrivateAPFSMountMigrationAndRestore() async throws {
        let fixture = try RealMountFixture()
        let runner = PrivateImageDiskRunner(fixture: fixture)
        do {
            let initial = try await runner.inventory()
            try requireRealMount(Set(initial.volumes.map(\.uuid)) == [fixture.record.initialVolumeUUID.uppercased()],
                                 "The private image must start with exactly its coordinator-created volume")
            try requireRealMount(DiskUtility.isMountPoint(fixture.external), "The coordinator volume is not mounted")
            let initialFlags = try XCTUnwrap(DiskUtility.mountFlags(at: fixture.external))
            try requireRealMount(initialFlags & UInt32(MNT_IGNORE_OWNERSHIP) != 0, "The selected private APFS volume must use noowners")
            let sentinel = fixture.external.appendingPathComponent("coordinator-sentinel.txt")
            try requireRealMount(try String(contentsOf: sentinel, encoding: .utf8) == fixture.record.nonce,
                                 "The coordinator's volume sentinel changed")
            let source = fixture.home.appendingPathComponent("Library/Containers/org.appports.synthetic.mount/Data/Library/Application Support/Business")
            let nested = source.appendingPathComponent("nested")
            let payload = nested.appendingPathComponent("payload")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data(repeating: 0x53, count: 64 * 1024).write(to: payload)
            try requireRealMount(link(payload.path, source.appendingPathComponent("second").path) == 0, "Cannot create fixture hard link")
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path,
                                                       withDestinationPath: "nested/payload")
            let attribute = Data([0, 255, 12, 128])
            let attributeStatus = attribute.withUnsafeBytes {
                setxattr(source.path, "org.appports.real-mount-fixture", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            try requireRealMount(attributeStatus == 0 && chmod(source.path, 0o750) == 0 && chmod(payload.path, 0o640) == 0,
                                 "Cannot establish the fixture's native metadata")
            var original = try TreeCopySession.snapshot(at: source, excludingRootEntries: Self.volumeArtifacts)
            original.ownershipCompatibility = .init(sourceIgnoresOwnership: false, destinationIgnoresOwnership: true, projectedSourceOwner: nil)
            let store = ContainerMountStore(fileURL: fixture.root.appendingPathComponent("data-records.plist"))
            let disk = DiskUtility(runner: runner, commandTimeout: 90, administratorRunner: nil)
            let migrator = ContainerVolumeMigrator(disk: disk, store: store,
                stagingMountRootURL: fixture.privateMounts, synchronizeAgent: { _ in }, homeDirectory: fixture.home)
            let item = DataDirItem(name: "Business", path: source, type: .containers, priority: .recommended,
                                   description: "Private APFS mount validation")
            let moved = try await migrator.migrateAndComplete(item: item, externalRootURL: fixture.external,
                appName: "Synthetic Mount", bundleIdentifier: "org.appports.synthetic.mount", progressHandler: nil)
            try requireRealMount(moved.cleanupWarning == nil, moved.cleanupWarning?.message ?? "Migration cleanup failed")
            try requireRealMount(DiskUtility.isMountPoint(source), "The production migration did not establish a real kernel mount")
            let mounted = try await disk.volumeInfo(for: source.path)
            try requireRealMount(mounted.volumeUUID?.uppercased() == moved.record.volumeUUID.uppercased(), "Mounted UUID does not match the committed record")
            try requireRealMount(mounted.apfsContainerReference == fixture.record.containerReference,
                                 "The data volume escaped the private image container")
            let mountedFlags = try XCTUnwrap(DiskUtility.mountFlags(at: source))
            try requireRealMount(mountedFlags & UInt32(MNT_IGNORE_OWNERSHIP) != 0, "Application data must retain the 1.9.0 noowners policy")
            try TreeCopySession.verifyCopy(at: source, against: original)
            try requireRealMount(try store.recordsStrict() == [moved.record] && store.transfers().isEmpty,
                                 "Migration did not finish its record and retained-source cleanup")
            let liveInventory = try await runner.inventory()
            try requireRealMount(Set(liveInventory.volumes.map(\.uuid)) ==
                [fixture.record.initialVolumeUUID.uppercased(), moved.record.volumeUUID.uppercased()],
                "Migration must create exactly one dedicated volume")

            // A real manual unmount leaves a readable, non-writable guard.
            // Discovery must retain unknown size instead of reporting empty data.
            let app = fixture.root.appendingPathComponent("Synthetic.app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "org.appports.synthetic.mount", "CFBundleName": "Synthetic",
                "CFBundlePackageType": "APPL"
            ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            let scanner = DataDirScanner(homeDir: fixture.home, mountStore: store)
            let scannedApp = AppItem(name: "Synthetic.app", path: app, status: AppStatus.local)
            try await migrator.unmount(record: moved.record)
            try requireRealMount(!DiskUtility.isMountPoint(source), "Manual pause did not detach the volume")
            var guardInfo = stat()
            try requireRealMount(lstat(source.path, &guardInfo) == 0 && guardInfo.st_mode & 0o7777 == 0o500,
                                 "Manual pause did not leave the production protection directory")
            try requireRealMount(try FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty,
                                 "The offline guard is not readable and empty")
            let offlineWrite = open(source.appendingPathComponent("must-not-create").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            let writeError = errno
            if offlineWrite >= 0 { close(offlineWrite) }
            try requireRealMount(offlineWrite == -1 && writeError == EACCES,
                                 "The offline guard accepted a local write")
            let pausedScan = await scanner.scanLibraryDirsWithDiagnostics(for: scannedApp)
            let pausedItem = try XCTUnwrap(pausedScan.items.first { $0.path.path == source.path })
            try requireRealMount(pausedItem.autoMountPaused && pausedItem.status == DataDirStatus.pendingMount
                && pausedItem.canRestore, "Pause lost the mount or recovery actions")
            let pausedSize = measureDataDirectorySize(for: pausedItem, pausedMountDirectories: pausedScan.pausedMountDirectories)
            let ancestorSize = measureDirectorySize(at: source.deletingLastPathComponent(),
                pausedMountDirectories: pausedScan.pausedMountDirectories)
            try requireRealMount(!pausedSize.isComplete && pausedSize.formattedSize == "—"
                && !pausedSize.readIssues.isEmpty && pausedSize.readIssues.allSatisfy(\.isExpectedMountPause),
                "A real paused guard was treated as a permission problem or complete empty data")
            try requireRealMount(!ancestorSize.isComplete && !ancestorSize.readIssues.contains(where: \.requiresAttention)
                && !pausedScan.readIssues.contains(where: \.requiresAttention),
                "The paused guard still triggers the page's read-error guidance")
            try await migrator.mount(record: moved.record, resumingManualPause: true)
            let resumedScan = await scanner.scanLibraryDirsWithDiagnostics(for: scannedApp)
            let resumedItem = try XCTUnwrap(resumedScan.items.first { $0.path.path == source.path })
            let resumedSize = measureDataDirectorySize(for: resumedItem, useCache: true,
                pausedMountDirectories: resumedScan.pausedMountDirectories)
            try requireRealMount(DiskUtility.isMountPoint(source) && !resumedItem.autoMountPaused
                && resumedSize.isComplete && resumedSize.bytes > 0, "Explicit mount did not resume size measurement")
            try TreeCopySession.verifyCopy(at: source, against: original)

            // Reproduce a readable external root over an inaccessible local
            // parent, using only this private image and synthetic container.
            // A metadata/TCC-style access failure must precede any unmount.
            let parent = source.deletingLastPathComponent()
            var parentInfo = stat()
            try requireRealMount(lstat(parent.path, &parentInfo) == 0, "Cannot inspect the fixture parent")
            // Simulate the obsolete owners state only inside this private fixture.
            // diskutil creates a root-owned volume root. Make this fixture's
            // root traversable before the deliberate owners remount, so the
            // injected failure is its local parent access, not hidden ownership.
            var rootInfo = stat()
            try requireRealMount(lstat(source.path, &rootInfo) == 0, "Cannot inspect the fixture volume root")
            try requireRealMount(chmod(source.path, 0o755) == 0, "Cannot prepare the legacy ownership fixture")
            try await disk.unmount(mountPoint: source)
            try await disk.mount(volume: moved.record.volumeUUID, at: source, requireOwnership: true)
            let unmountsBeforeDenial = await runner.unmountCount()
            do {
                try requireRealMount(chmod(parent.path, 0o100) == 0, "Cannot establish the private permission boundary")
                defer { _ = chmod(parent.path, parentInfo.st_mode & 0o7777) }
                try requireRealMount(try Data(contentsOf: payload).count == 64 * 1024, "Mounted data must remain readable")
                do {
                    try await migrator.restoreOriginalMountOptions(mountPoint: source,
                        volumeUUID: moved.record.volumeUUID, originalFlags: mountedFlags | UInt32(MNT_IGNORE_OWNERSHIP))
                    try requireRealMount(false, "Ownership recovery ignored the inaccessible local parent")
                } catch {
                    try requireRealMount(DataOperationIssue.needsAccessPermission(error), "Expected an access failure before unmount: \(error)")
                }
                try requireRealMount(DiskUtility.isMountPoint(source), "Denied recovery detached the usable source")
                let unmountsAfterDenial = await runner.unmountCount()
                try requireRealMount(unmountsBeforeDenial == unmountsAfterDenial, "Denied recovery issued an unmount command")
                try requireRealMount(try Data(contentsOf: payload).count == 64 * 1024, "Denied recovery changed the mounted data")
            }
            try await migrator.restoreOriginalMountOptions(mountPoint: source,
                volumeUUID: moved.record.volumeUUID, originalFlags: mountedFlags | UInt32(MNT_IGNORE_OWNERSHIP))
            try requireRealMount(DiskUtility.mountFlags(at: source).map { $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 } == true,
                                 "Ownership correction did not resume after parent access returned")
            try requireRealMount(chmod(source.path, rootInfo.st_mode & 0o7777) == 0, "Cannot restore the fixture root mode")
            try TreeCopySession.verifyCopy(at: source, against: original)

            // These are real writes through the newly mounted original path.
            try Data("written after activation".utf8).write(to: source.appendingPathComponent("new-file"))
            let handle = try FileHandle(forWritingTo: payload)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("updated active hard-linked payload".utf8))
            try handle.synchronize()
            try handle.close()
            let current = try TreeCopySession.snapshot(at: source, excludingRootEntries: Self.volumeArtifacts)
            // Reconnect through the normal recorded mount path, preserving
            // writes produced by the application before restoration.
            try await disk.unmount(mountPoint: source)
            try await migrator.mount(record: moved.record)
            try TreeCopySession.verifyCopy(at: source, against: current)
            try DurableFileIO.write(try JSONSerialization.data(withJSONObject: ["nonce": fixture.record.nonce,
                "createdVolumeUUID": moved.record.volumeUUID, "stage": "active-write-verified"]),
                to: fixture.root.appendingPathComponent("real-mount-progress.json"))
            let unmountsBeforeLateDenial = await runner.unmountCount()
            do {
                defer { _ = chmod(parent.path, parentInfo.st_mode & 0o7777) }
                do {
                    _ = try await migrator.restore(record: moved.record, estimatedTotalBytes: current.logicalBytes) { progress in
                        if progress.currentFile == "正在切换本地入口...".localized { _ = chmod(parent.path, 0o100) }
                    }
                    try requireRealMount(false, "Restore detached the source despite lost local parent access")
                } catch {
                    try requireRealMount(DataOperationIssue.needsAccessPermission(error), "Expected a late parent access failure: \(error)")
                }
                try requireRealMount(DiskUtility.isMountPoint(source), "Late permission denial removed the active entry")
                let unmountsAfterLateDenial = await runner.unmountCount()
                try requireRealMount(unmountsAfterLateDenial == unmountsBeforeLateDenial, "Late permission denial issued an unmount")
                var deniedParent = stat()
                try requireRealMount(lstat(parent.path, &deniedParent) == 0 && deniedParent.st_mode & 0o7777 == 0o100,
                                     "The restore did not reach the injected switch-time access failure")
                try requireRealMount(try String(contentsOf: payload, encoding: .utf8) == "updated active hard-linked payload",
                                     "Late permission denial changed the application's latest data")
            }
            // Full verification opens the parent while validating the path;
            // run it after the fixture's injected permission denial is lifted.
            try TreeCopySession.verifyCopy(at: source, against: current)
            let warning = try await migrator.restoreAndComplete(record: moved.record,
                estimatedTotalBytes: current.logicalBytes, progressHandler: nil)
            try requireRealMount(warning == nil, warning?.message ?? "Restore cleanup failed")
            try requireRealMount(!DiskUtility.isMountPoint(source), "The restored original path is still a mount")
            try requireRealMount(try RealMountFileIdentity.capture(source).kind == UInt32(S_IFDIR), "The restored root is not a real directory")
            try TreeCopySession.verifyCopy(at: source, against: current)
            try requireRealMount(try String(contentsOf: source.appendingPathComponent("new-file"), encoding: .utf8) == "written after activation",
                                 "The activation-time write was not restored")
            try requireRealMount(try store.recordsStrict().isEmpty && store.transfers().isEmpty && store.managedLinks().isEmpty
                && store.pendingCleanups().isEmpty && store.preservedMaterials().isEmpty, "Production cleanup left records or materials")
            try requireRealMount(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path) == ["Business"],
                                 "The source parent still contains staging or retained originals")
            if FileManager.default.fileExists(atPath: fixture.privateMounts.path) {
                try requireRealMount(try FileManager.default.contentsOfDirectory(atPath: fixture.privateMounts.path).isEmpty,
                                     "Private mount staging was not cleaned up")
            }
            try Self.requireNoImmutableNodes(at: source)
            let finished = try await runner.inventory()
            try requireRealMount(Set(finished.volumes.map(\.uuid)) == [fixture.record.initialVolumeUUID.uppercased()],
                                 "The dedicated data volume remains after restore cleanup")
            try requireRealMount(try String(contentsOf: sentinel, encoding: .utf8) == fixture.record.nonce,
                                 "The coordinator's original volume was changed")
            let finalFlags = try XCTUnwrap(DiskUtility.mountFlags(at: fixture.external))
            try requireRealMount(finalFlags & UInt32(MNT_IGNORE_OWNERSHIP) != 0, "The coordinator's noowners option was changed")
            for scenario in ["online", "offline", "failed-intent", "partial-cancel", "partial-resume", "verified-resume",
                             "verified-resume-offline", "strict-verified-resume", "strict-verified-resume-offline",
                             "strict-copying-resume", "strict-copying-resume-offline", "strict-copying-rollback-offline",
                             "automatic-rollback", "automatic-rollback-offline"] {
                try await validateLegacyRestore(scenario, fixture: fixture, runner: runner, disk: disk,
                                                migrator: migrator, store: store, item: item)
            }
            let report: [String: Any] = ["status": "passed", "nonce": fixture.record.nonce, "pid": getpid(),
                "containerUUID": fixture.record.containerUUID, "createdVolumeUUID": moved.record.volumeUUID,
                "realKernelMountVerified": true, "manualPauseReadDiagnosticsVerified": true, "offlineGuardReadableAndWriteDenied": true, "activeWritesRestored": true, "dedicatedVolumeDeleted": true,
                "reconnectedCurrentData": true,
                "permissionDenialPreservesUsableMountAndCanRetry": true,
                "permissionLossAfterCopyPreservesLatestData": true,
                "legacyNoownersRestoreAndRecoveryWithoutOwnershipUpdates": true,
                "recordsAndMaterialsCleaned": true, "immutableAbsent": true, "baseVolumeRemainsNoowners": true]
            try DurableFileIO.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                                    to: fixture.root.appendingPathComponent("real-mount-result.json"))
        } catch {
            // Preserve the fixture and its attachment for the coordinator to inspect.
            let report = ["status": "failed", "nonce": fixture.record.nonce, "error": String(describing: error)]
            try? DurableFileIO.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                                    to: fixture.root.appendingPathComponent("real-mount-result.json"))
            throw error
        }
    }

    private func validateLegacyRestore(_ scenario: String, fixture: RealMountFixture, runner: PrivateImageDiskRunner,
                                       disk: DiskUtility, migrator: ContainerVolumeMigrator,
                                       store: ContainerMountStore, item: DataDirItem) async throws {
        AppLogger.shared.logContext("Private APFS legacy scenario", details: [("scenario", scenario)])
        let source = item.path
        let moved = try await migrator.migrateAndComplete(item: item, externalRootURL: fixture.external,
            appName: "Synthetic Mount", bundleIdentifier: "org.appports.synthetic.mount", progressHandler: nil)
        try requireRealMount(moved.cleanupWarning == nil && store.transfers().isEmpty, "Legacy fixture migration did not finish")
        // Simulate a 1.9.0 record on a real noowners APFS mount. The runner has
        // no administrator facility and authorizes only this private image.
        var legacy = moved.record
        legacy.ownershipPolicy = nil
        try store.remove(mountPointPath: legacy.mountPointPath)
        try store.upsert(legacy)
        try requireRealMount(try store.recordsStrict() == [legacy], "The fixture did not persist a legacy mount record")
        try await disk.unmount(mountPoint: source)
        try await disk.mount(volume: legacy.volumeUUID, at: source, requireOwnership: false)
        try requireRealMount(DiskUtility.mountFlags(at: source).map { $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 } == true,
                             "Legacy fixture did not mount with noowners")
        let baseline = try TreeCopySession.snapshot(at: source, excludingRootEntries: Self.volumeArtifacts)
        let updatesBefore = await runner.ownershipUpdateCount()
        if scenario == "offline" { try await disk.unmount(mountPoint: source) }
        if scenario == "failed-intent" {
            let id = UUID()
            var intent = DataTransferRecord(operationID: id, mode: .mount, direction: .restore,
                appName: legacy.appName, bundleIdentifier: legacy.bundleIdentifier, dataDirType: legacy.dataDirType,
                originalPath: source.path, activePath: source.path, destinationPath: source.path,
                backupPath: fixture.privateMounts.appendingPathComponent("recovery-\(id.uuidString)").path,
                stagingPath: source.deletingLastPathComponent().appendingPathComponent(".appports-restore-staging-\(id.uuidString)").path,
                sourceIdentity: DataPathIdentity(volumeUUID: legacy.volumeUUID))
            intent.legacyRootOwnership = .init(uid: geteuid(), gid: getegid())
            intent.legacyMountFlags = DiskUtility.mountFlags(at: source)
            try store.beginTransfer(intent)
            intent.phase = .needsRecovery
            intent.recoverableReason = "Synthetic previous ownership update failure"
            try store.updateTransfer(intent)
            _ = try await migrator.restore(record: legacy, estimatedTotalBytes: 0, progressHandler: nil)
            let restored = try XCTUnwrap(try store.transfer(operationID: id))
            let saved = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: XCTUnwrap(restored.baseline))
            try requireRealMount(restored.legacyRootOwnership == nil && restored.legacyMountFlags == nil
                && restored.originalSourceMountFlags == intent.legacyMountFlags
                && saved.ownershipCompatibility?.sourceIgnoresOwnership == true,
                "The old failed intent was not safely converted to projected ownership")
            let warning = try await migrator.resumeVerifiedTransfer(operationID: id, progressHandler: nil)
            try requireRealMount(warning == nil, warning ?? "Failed-intent cleanup failed")
        }
        if scenario.hasPrefix("partial-") || scenario.hasPrefix("automatic-rollback") {
            let record = legacy
            if scenario == "automatic-rollback-offline" { await runner.cancelAfterNextUnmount(at: source) }
            let operation = Task {
                let progress: FileCopier.ProgressHandler = { progress in
                    if scenario != "automatic-rollback-offline", progress.currentFile == "new-file" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                if scenario.hasPrefix("automatic-rollback") {
                    _ = try await migrator.restoreAndComplete(record: record, estimatedTotalBytes: 0, progressHandler: progress)
                } else {
                    _ = try await migrator.restore(record: record, estimatedTotalBytes: 0, progressHandler: progress)
                }
            }
            do { try await operation.value; XCTFail("The synthetic cancellation was not observed: \(scenario)") }
            catch { }
            try requireRealMount(DiskUtility.isMountPoint(source), "Cancellation lost the legacy mount")
            try TreeCopySession.verifyUnchanged(at: source, against: baseline, expectedVolumeUUID: legacy.volumeUUID)
            if scenario.hasPrefix("automatic-rollback") {
                try requireRealMount(try store.transfers().isEmpty && store.preservedMaterials().isEmpty,
                                     "Automatic rollback retained an unnecessary copy or record")
            } else {
                let pending = try XCTUnwrap(try store.transfers().first)
                let saved = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: XCTUnwrap(pending.sourceBaseline))
                try requireRealMount(saved.ownershipCompatibility?.sourceIgnoresOwnership == true,
                                     "The partial restore lost its projected source contract")
                if scenario == "partial-resume" {
                    let warning = try await migrator.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
                    try requireRealMount(warning == nil, warning ?? "Partial resume failed")
                } else { try await migrator.cancelPreparation(operationID: pending.operationID) }
            }
        }
        if scenario.contains("verified-resume") || scenario.hasPrefix("strict-copying-") {
            if scenario.hasPrefix("strict-copying-") {
                let record = legacy
                let operation = Task {
                    try await migrator.restore(record: record, estimatedTotalBytes: 0) { progress in
                        if progress.currentFile == "new-file" { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
                do { _ = try await operation.value; XCTFail("Copy was not interrupted") } catch { }
            } else {
                await runner.failNextUnmount(at: source)
                do {
                    _ = try await migrator.restore(record: legacy, estimatedTotalBytes: 0, progressHandler: nil)
                    XCTFail("The synthetic unmount failure was not observed")
                } catch { }
            }
            var pending = try XCTUnwrap(try store.transfers().first)
            if scenario.hasPrefix("strict-copying-") {
                try requireRealMount(pending.sourceBaseline != nil && pending.baseline == nil && pending.destinationIdentity != nil,
                                     "The historical copying checkpoint was not reproduced")
            } else {
                try requireRealMount(pending.baseline != nil, "The restore was not interrupted after verification")
            }
            if scenario.hasPrefix("strict-") {
                // Match the historical 1.9.1 journal shape: a strict source
                // snapshot with UID 0 at the root and a user-owned destination.
                // No physical fixture owner or host permission is changed.
                let url = fixture.root.appendingPathComponent("data-records.plist")
                var document = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
                var transfers = try XCTUnwrap(document["transfers"] as? [[String: Any]])
                let index = try XCTUnwrap(transfers.firstIndex { $0["operationID"] as? String == pending.operationID.uuidString })
                for key in ["sourceBaseline", "baseline"] {
                    guard let encoded = transfers[index][key] as? Data else { continue }
                    var snapshot = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
                    snapshot.removeValue(forKey: "ownershipCompatibility")
                    snapshot["restoredRootOwnership"] = ["uid": geteuid(), "gid": getegid()]
                    var entries = try XCTUnwrap(snapshot["entries"] as? [[String: Any]])
                    let root = try XCTUnwrap(entries.firstIndex { $0["path"] as? String == "" })
                    entries[root]["uid"] = 0
                    entries[root]["gid"] = 0
                    snapshot["entries"] = entries
                    transfers[index][key] = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
                }
                transfers[index]["legacyRootOwnership"] = ["uid": geteuid(), "gid": getegid()]
                transfers[index]["legacyMountFlags"] = DiskUtility.mountFlags(at: source)
                if scenario.hasPrefix("strict-copying-") { transfers[index]["phase"] = "copying" }
                document["transfers"] = transfers
                try DurableFileIO.write(PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0), to: url)
                pending = try XCTUnwrap(try store.transfer(operationID: pending.operationID))
                let strict = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: XCTUnwrap(pending.sourceBaseline))
                try requireRealMount(strict.ownershipCompatibility == nil && strict.entries.first?.uid == 0, "Historical strict journal was not reproduced")
            }
            if scenario.hasSuffix("-offline") { try await disk.unmount(mountPoint: source) }
            let reopened = ContainerVolumeMigrator(disk: disk,
                store: ContainerMountStore(fileURL: fixture.root.appendingPathComponent("data-records.plist")),
                stagingMountRootURL: fixture.privateMounts, synchronizeAgent: { _ in }, homeDirectory: fixture.home)
            if scenario.contains("copying-rollback") {
                let warnings = await reopened.performAutomaticMaintenance()
                try requireRealMount(warnings.isEmpty, warnings.joined(separator: "\n"))
                try requireRealMount(DiskUtility.isMountPoint(source), "Automatic rollback did not reconnect current data")
                try TreeCopySession.verifyUnchanged(at: source, against: baseline, expectedVolumeUUID: legacy.volumeUUID)
                let warning = try await reopened.restoreAndComplete(record: legacy, estimatedTotalBytes: 0, progressHandler: nil)
                try requireRealMount(warning == nil, warning?.message ?? "Restore after automatic rollback failed")
            } else {
                let warning = try await reopened.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
                try requireRealMount(warning == nil, warning ?? "Verified resume failed")
            }
        } else if scenario != "partial-resume", scenario != "failed-intent" {
            let warning = try await migrator.restoreAndComplete(record: legacy, estimatedTotalBytes: 0, progressHandler: nil)
            try requireRealMount(warning == nil, warning?.message ?? "Legacy restore failed")
        }
        try requireRealMount(!DiskUtility.isMountPoint(source), "Legacy restoration did not reconnect local data")
        try requireRealMount(try RealMountFileIdentity.capture(source).uid == geteuid(), "Restored data is not user-owned")
        try TreeCopySession.verifyCopy(at: source, against: baseline)
        try requireRealMount(await runner.ownershipUpdateCount() == updatesBefore, "Legacy restore changed ownership mode: \(scenario)")
        try requireRealMount(try store.recordsStrict().isEmpty && store.transfers().isEmpty && store.preservedMaterials().isEmpty,
                             "Legacy restore retained records or materials: \(scenario)")
        try requireRealMount(try await runner.inventory().volumes.count == 1, "Legacy data volume cleanup did not finish")
    }

    private static let volumeArtifacts: Set<String> = [ContainerVolumeMigrator.volumeMarkerFileName,
        ContainerVolumeMigrator.neverIndexFileName, ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware"]

    private static func requireNoImmutableNodes(at root: URL) throws {
        let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var urls = [root]
        while let url = entries?.nextObject() as? URL { urls.append(url) }
        for url in urls {
            var info = stat()
            try requireRealMount(lstat(url.path, &info) == 0, "Cannot inspect restored fixture flags")
            try requireRealMount(info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0, "An immutable flag remained on restored fixture data")
        }
    }
}

func requireRealMount(_ condition: Bool, _ message: String) throws {
    guard condition else { throw NSError(domain: "AppPorts.PrivateAPFSValidation", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}

struct RealMountFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let uid: UInt32
    let kind: UInt32

    static func capture(_ url: URL) throws -> Self {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino),
                     uid: value.st_uid, kind: UInt32(value.st_mode & S_IFMT))
    }
}

struct RealMountFixture: Sendable {
    struct Record: Codable, Sendable {
        let nonce: String
        let rootPath: String
        let imagePath: String
        let externalPath: String
        let rootIdentity: RealMountFileIdentity
        let imageIdentity: RealMountFileIdentity
        let containerReference: String
        let containerUUID: String
        let initialVolumeUUID: String
        let initialVolumeDevice: String
    }
    let record: Record
    let root: URL
    let image: URL
    let external: URL
    let home: URL
    let privateMounts: URL
    private let recordBytes: Data

    init() throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_REAL_MOUNT_ROOT"], !path.isEmpty else {
            throw XCTSkip("Use the private APFS coordinator and APPPORTS_REAL_MOUNT_ROOT to enable real mount validation")
        }
        root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        try requireRealMount(root.deletingLastPathComponent().path == temporary.path && root.lastPathComponent.hasPrefix("AppPortsRealMount-"),
                             "The fixture root must be a dedicated directory under this host's NSTemporaryDirectory")
        recordBytes = try Self.readRecord(at: root.appendingPathComponent("coordinator-owner.json"))
        record = try JSONDecoder().decode(Record.self, from: recordBytes)
        image = root.appendingPathComponent("fixture.sparseimage")
        external = root.appendingPathComponent("External")
        home = root.appendingPathComponent("Home")
        privateMounts = root.appendingPathComponent("PrivateMounts")
        try requireRealMount(root.lastPathComponent == "AppPortsRealMount-" + record.nonce && UUID(uuidString: record.nonce) != nil,
                             "The fixture name and creation nonce do not match")
        // pathlib preserves /private/var while Foundation may use /var for the
        // same directory. Compare resolved paths, then verify the recorded
        // filesystem identities before allowing any private-image command.
        try requireRealMount(URL(fileURLWithPath: record.rootPath).standardizedFileURL.resolvingSymlinksInPath() == root
            && URL(fileURLWithPath: record.imagePath).standardizedFileURL.resolvingSymlinksInPath() == image
            && URL(fileURLWithPath: record.externalPath).standardizedFileURL.resolvingSymlinksInPath() == external,
                             "The manifest points outside its private fixture")
        try requireRealMount(record.containerReference.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
            && UUID(uuidString: record.containerUUID) != nil && UUID(uuidString: record.initialVolumeUUID) != nil,
            "The coordinator did not record an APFS container and volume identity")
        try requireOwnedFiles()
        try requireRealMount(!FileManager.default.fileExists(atPath: home.path)
            && !FileManager.default.fileExists(atPath: root.appendingPathComponent("data-records.plist").path),
            "A real mount test cannot reuse prior data or a prior ledger")
    }

    func requireOwnedFiles() throws {
        try requireRealMount(try RealMountFileIdentity.capture(root) == record.rootIdentity
            && record.rootIdentity.uid == geteuid() && record.rootIdentity.kind == UInt32(S_IFDIR), "The private fixture root changed")
        try requireRealMount(try RealMountFileIdentity.capture(image) == record.imageIdentity
            && record.imageIdentity.uid == geteuid() && record.imageIdentity.kind == UInt32(S_IFREG), "The private image file changed")
        try requireRealMount(try Self.readRecord(at: root.appendingPathComponent("coordinator-owner.json")) == recordBytes,
                             "The coordinator's ownership manifest changed")
    }

    private static func readRecord(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        try requireRealMount(fstat(descriptor, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
            && value.st_uid == geteuid() && value.st_size <= 65536, "The coordinator manifest is not a small user-owned regular file")
        return try handle.readToEnd() ?? Data()
    }
}

actor PrivateImageDiskRunner: ShellCommandRunning {
    struct Volume: Sendable { let uuid: String; let device: String }
    struct Inventory: Sendable { let volumes: [Volume]; let freeBytes: Int64 }
    private struct Command: Codable { let executable: String; let arguments: [String]; let status: Int32; let timedOut: Bool }
    let fixture: RealMountFixture
    private var commands: [Command] = []
    private var failingUnmountPath: String?
    private var cancelledUnmountPath: String?

    init(fixture: RealMountFixture) { self.fixture = fixture }

    func ownershipUpdateCount() -> Int { commands.filter { $0.executable == "/sbin/mount" }.count }
    func unmountCount() -> Int { commands.filter { $0.arguments.first == "unmount" }.count }
    func failNextUnmount(at path: URL) { failingUnmountPath = path.path }
    func cancelAfterNextUnmount(at path: URL) { cancelledUnmountPath = path.path }

    func inventory() async throws -> Inventory {
        try fixture.requireOwnedFiles()
        let attachments = try await plist("/usr/bin/hdiutil", ["info", "-plist"])
        let images = (attachments["images"] as? [[String: Any]] ?? []).filter {
            guard let path = $0["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == fixture.image.path
        }
        try requireRealMount(images.count == 1, "The image has no unique live hdiutil attachment")
        let devices = Set((images[0]["system-entities"] as? [[String: Any]] ?? []).compactMap {
            ($0["dev-entry"] as? String).map { $0.replacingOccurrences(of: "/dev/", with: "") }
        })
        let listing = try await plist("/usr/sbin/diskutil", ["apfs", "list", "-plist", fixture.record.containerReference])
        let containers = listing["Containers"] as? [[String: Any]] ?? []
        try requireRealMount(containers.count == 1, "The private APFS container is unavailable or ambiguous")
        let container = containers[0]
        try requireRealMount(container["ContainerReference"] as? String == fixture.record.containerReference
            && (container["APFSContainerUUID"] as? String)?.uppercased() == fixture.record.containerUUID.uppercased(),
            "The APFS container identity changed")
        let physicalStores = (container["PhysicalStores"] as? [[String: Any]] ?? []).compactMap { $0["DeviceIdentifier"] as? String }
        try requireRealMount(!physicalStores.isEmpty && physicalStores.allSatisfy(devices.contains),
                             "The APFS physical stores are not backed exclusively by the coordinator's image")
        let volumes = try (container["Volumes"] as? [[String: Any]] ?? []).map { entry -> Volume in
            guard let uuid = entry["APFSVolumeUUID"] as? String, let device = entry["DeviceIdentifier"] as? String,
                  device.range(of: "^" + fixture.record.containerReference + #"s[0-9]+$"#, options: .regularExpression) != nil else {
                throw NSError(domain: "AppPorts.PrivateAPFSValidation", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Incomplete private volume inventory"])
            }
            return Volume(uuid: uuid.uppercased(), device: device)
        }
        try requireRealMount(volumes.contains { $0.uuid == fixture.record.initialVolumeUUID.uppercased()
            && $0.device == fixture.record.initialVolumeDevice }, "The coordinator's baseline volume disappeared or changed")
        let freeBytes = try XCTUnwrap((container["CapacityFree"] as? NSNumber)?.int64Value,
                                     "The private APFS container did not report free capacity")
        try requireRealMount(freeBytes >= 0, "The private APFS capacity is invalid")
        try fixture.requireOwnedFiles()
        return Inventory(volumes: volumes, freeBytes: freeBytes)
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        try fixture.requireOwnedFiles()
        let readOnly = executable == "/usr/sbin/diskutil" &&
            ((arguments.count == 3 && Array(arguments.prefix(2)) == ["info", "-plist"])
             || (Array(arguments.prefix(3)) == ["apfs", "list", "-plist"] && [3, 4].contains(arguments.count)))
        if !readOnly {
            let current = try await inventory()
            if executable == "/usr/sbin/diskutil", arguments.count == 6, Array(arguments.prefix(2)) == ["apfs", "addVolume"] {
                try requireRealMount(arguments[2] == fixture.record.containerReference && arguments[3] == "APFS"
                    && arguments[4].hasPrefix("AppPorts-org.appports.synthetic.mount-Business-") && arguments[5] == "-nomount"
                    && current.volumes.count == 1, "Refusing legacy volume creation outside the private image")
            } else if executable == "/usr/sbin/diskutil", arguments.count == 5, Array(arguments.prefix(3)) == ["mount", "nobrowse", "-mountPoint"] {
                try requirePrivateVolume(arguments[4], in: current)
                let destination = URL(fileURLWithPath: arguments[3]).standardizedFileURL
                try requireRealMount(destination.path.hasPrefix(fixture.root.path + "/")
                    && destination.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(fixture.root.path + "/"),
                    "The legacy mount destination escaped the private fixture")
            } else if executable == "/usr/sbin/diskutil", [7, 8].contains(arguments.count), arguments[0] == "mount" {
                let readOnly = arguments.count == 8
                let options = readOnly ? Array(arguments.dropFirst(2)) : Array(arguments.dropFirst())
                try requireRealMount((!readOnly || arguments[1] == "readOnly")
                    && Array(options.prefix(2)) == ["nobrowse", "-mountPoint"]
                    && options[3] == "-mountOptions" && ["owners", "noowners"].contains(options[4])
                    && (!readOnly || options[4] == "noowners"),
                    "Unexpected private mount options")
                try requirePrivateVolume(options[5], in: current)
                let destination = URL(fileURLWithPath: options[2]).standardizedFileURL
                try requireRealMount(destination.path.hasPrefix(fixture.root.path + "/")
                    && destination.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(fixture.root.path + "/"),
                    "The mount destination escaped the private fixture")
            } else if executable == "/usr/sbin/diskutil", arguments.count == 2, arguments[0] == "unmount" {
                try await requirePrivateMountedVolume(at: arguments[1], inventory: current)
                if failingUnmountPath == arguments[1] {
                    failingUnmountPath = nil
                    throw NSError(domain: "AppPorts.PrivateAPFSValidation", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Synthetic one-time unmount failure"])
                }
            } else if executable == "/usr/sbin/diskutil", arguments.count == 3,
                      Array(arguments.prefix(2)) == ["apfs", "deleteVolume"] {
                try requirePrivateVolume(arguments[2], in: current)
            } else if executable == "/sbin/mount", arguments.count == 4,
                      Array(arguments.prefix(2)) == ["-u", "-o"] {
                let allowed: Set<String> = ["nobrowse", "owners", "noowners", "rdonly", "nodev", "nosuid", "noexec"]
                try requireRealMount(Set(arguments[2].split(separator: ",").map(String.init)).isSubset(of: allowed),
                                     "Unexpected mount update options")
                try await requirePrivateMountedVolume(at: arguments[3], inventory: current)
            } else {
                throw NSError(domain: "AppPorts.PrivateAPFSValidation", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Refusing unrecognized disk mutation: " + executable + " " + arguments.joined(separator: " ")])
            }
        }
        let result = try await ProcessCommandRunner().run(executable: executable, arguments: arguments, timeout: timeout)
        commands.append(Command(executable: executable, arguments: arguments, status: result.status, timedOut: result.timedOut))
        try DurableFileIO.write(try JSONEncoder().encode(commands), to: fixture.root.appendingPathComponent("real-disk-commands.json"))
        if executable == "/usr/sbin/diskutil", arguments.first == "unmount", arguments.last == cancelledUnmountPath,
           result.status == 0 {
            cancelledUnmountPath = nil
            throw CancellationError()
        }
        return result
    }

    private func requirePrivateVolume(_ target: String, in inventory: Inventory) throws {
        try requireRealMount(inventory.volumes.contains { $0.uuid != fixture.record.initialVolumeUUID.uppercased()
            && ($0.uuid == target.uppercased() || $0.device == target) }, "Disk mutation did not target the private data volume")
    }

    private func requirePrivateMountedVolume(at path: String, inventory: Inventory) async throws {
        let info = try await plist("/usr/sbin/diskutil", ["info", "-plist", path])
        let reportedMount = try XCTUnwrap(info["MountPoint"] as? String)
        try requireRealMount(URL(fileURLWithPath: reportedMount).standardizedFileURL.resolvingSymlinksInPath()
            == URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath(),
            "The unmount/update target is not the actual volume root")
        try requirePrivateVolume(info["VolumeUUID"] as? String ?? "", in: inventory)
        try requireRealMount(info["APFSContainerReference"] as? String == fixture.record.containerReference,
                             "The mounted volume no longer belongs to the private container")
    }

    private func plist(_ executable: String, _ arguments: [String]) async throws -> [String: Any] {
        let result = try await ProcessCommandRunner().run(executable: executable, arguments: arguments, timeout: 45)
        try requireRealMount(result.status == 0 && !result.timedOut,
                             executable + " " + arguments.joined(separator: " ") + ": " + result.combinedText)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: result.standardOutput, format: nil) as? [String: Any])
    }
}
