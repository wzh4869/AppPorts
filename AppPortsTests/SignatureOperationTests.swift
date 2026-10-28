import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Manual signature operation recovery")
struct SignatureOperationTests {
    @Test("Disposable APFS volumes exercise real cross-volume retention and interrupted remount recovery", .serialized,
          arguments: ["copy", "remount", "protected-remount"])
    func realVolumeRetention(mode: String) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let image = fixture.root.appendingPathComponent("BackupVolume.sparseimage")
        let first = fixture.root.appendingPathComponent("FirstMount")
        let second = fixture.root.appendingPathComponent("SecondMount")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try await diskImage(["create", "-size", "256m", "-fs", "APFS", "-type", "SPARSE", "-volname", "AppPorts Signature Test", image.path])
        try await diskImage(["attach", image.path, "-nobrowse", "-mountpoint", first.path])
        do {
            let location = try SignatureBackupStorage.prepareDirectory(first.appendingPathComponent("AppPorts Backups"))
            var app = fixture.app
            let original = try SignatureSnapshot.fingerprint(of: app)
            if mode != "copy" {
                app = first.appendingPathComponent("Installed.app")
                try SignatureSnapshot.copy(from: fixture.app, to: app)
                if mode == "protected-remount" {
                    let transfers = AppTransferStore(directoryURL: fixture.root.appendingPathComponent("SignatureBackups-app-transfers"))
                    try AppUpdateProtectionStore(transferStore: transfers).protect(app)
                }
            }
            let originalIdentity = try DataPathIdentity.capture(app)
            let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true, synchronizeTree: { url in
                if mode != "copy", url.lastPathComponent.hasPrefix("original-") { throw Injected.failure }
                try DurableFileIO.syncTree(at: url)
            }, backupDestination: { _, _ in location })
            let signed = try await signer.sign(appURL: app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
            #expect(signed.committed)
            #expect((signed.cleanupWarning != nil) == (mode != "copy"))
            if mode != "copy" {
                try await diskImage(["detach", first.path])
                try await diskImage(["attach", image.path, "-nobrowse", "-mountpoint", second.path])
                app = second.appendingPathComponent("Installed.app")
                do {
                    _ = try SignatureFactStore(backupDirectoryURL: fixture.backups).captureRelocation(from: app)
                    Issue.record("Unretained original must block metadata reconciliation")
                } catch let error as OperationBlockage {
                    #expect(error.reason == .originalRetention)
                    #expect(error.blockingOperationID == signed.operationID)
                    #expect(error.blockingPhase == SignatureOperationRecord.Phase.committed.rawValue)
                }
                let warnings = await fixture.signer(officialEvidence: true, captureOfficialOriginal: true).performAutomaticMaintenance()
                #expect(warnings.isEmpty, Comment(rawValue: warnings.joined(separator: "\n")))
            }
            let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
            let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
            let snapshot = try history.verifiedSnapshot(for: backup)
            #expect(try SignatureSnapshot.fingerprint(of: snapshot) == original)
            let retainedIdentity = try DataPathIdentity.capture(snapshot)
            if mode == "copy" { #expect(retainedIdentity.volumeUUID != originalIdentity.volumeUUID) }
            else { #expect(retainedIdentity.matchesFilesystemObject(originalIdentity)) }
            #expect(try fixture.signingMaterialsAreEmpty())
            let restored = try await fixture.signer(officialEvidence: true, captureOfficialOriginal: true)
                .restoreSignature(appURL: app, bundleIdentifier: fixture.identifier)
            #expect(restored.committed && restored.cleanupWarning == nil)
            #expect(try SignatureSnapshot.fingerprint(of: app) == original)
        } catch {
            _ = try? await diskImage(["detach", first.path])
            _ = try? await diskImage(["detach", second.path])
            throw error
        }
        let mount = mode == "copy" ? first : second
        try await diskImage(["detach", mount.path])
    }

    private func diskImage(_ arguments: [String]) async throws {
        let result = try await ProcessCommandRunner().run(executable: "/usr/bin/hdiutil", arguments: arguments, timeout: 45)
        guard result.status == 0, !result.timedOut else {
            throw NSError(domain: "AppPortsSignatureDiskImageTests", code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.combinedText])
        }
    }

    @Test("An original retained on the same volume keeps its inode without a second application copy")
    func sameVolumeRetentionMovesOriginal() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let originalIdentity = try DataPathIdentity.capture(fixture.app)
        let destination = try SignatureBackupStorage.prepareDirectory(fixture.root.appendingPathComponent("AppPorts Backups"))
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true, copy: { source, target in
            #expect(!target.lastPathComponent.hasPrefix("original-"))
            try SignatureSnapshot.copyContents(from: source, into: target)
        }, backupDestination: { _, _ in destination })
        let result = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(result.committed && result.cleanupWarning == nil)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        #expect(backup.schemaVersion == 3 && backup.snapshotLocation == destination)
        #expect(try DataPathIdentity.capture(history.verifiedSnapshot(for: backup)).matchesFilesystemObject(originalIdentity))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path).allSatisfy { !$0.hasSuffix(".app") })
        let restored = try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(restored.committed && restored.cleanupWarning == nil)
    }

    @Test("Unavailable backup storage fails before changing the application", arguments: [false, true])
    func unavailableStoragePreventsExchange(disconnectAfterPreparation: Bool) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let location = try SignatureBackupStorage.prepareDirectory(fixture.root.appendingPathComponent("AppPorts Backups"))
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true, checkpoint: { record in
            if disconnectAfterPreparation, record.phase == .prepared {
                try FileManager.default.moveItem(at: location.displayURL, to: fixture.root.appendingPathComponent("Disconnected"))
            }
        }, backupDestination: { _, _ in
            guard disconnectAfterPreparation else { throw CodeSigner.SigningError.backupStorageUnavailable }
            return location
        })
        await #expect(throws: (any Error).self) {
            try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        }
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("An interrupted rename retention resumes without needing the old workspace source")
    func renameRetentionColdRetry() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let originalIdentity = try DataPathIdentity.capture(fixture.app)
        let location = try SignatureBackupStorage.prepareDirectory(fixture.root.appendingPathComponent("AppPorts Backups"))
        let result = try await fixture.signer(officialEvidence: true, captureOfficialOriginal: true, synchronizeTree: { url in
            if url.lastPathComponent.hasPrefix("original-") { throw Injected.failure }
            try DurableFileIO.syncTree(at: url)
        }, backupDestination: { _, _ in location }).sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(result.committed && result.cleanupWarning != nil)
        let pending = try #require(try SignatureOperationStore(backupDirectoryURL: fixture.backups).records().first)
        #expect(try !SignatureSnapshot.entryExists(pending.candidateURL))
        let warnings = await fixture.signer(officialEvidence: true, captureOfficialOriginal: true).performAutomaticMaintenance()
        #expect(warnings.isEmpty)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        #expect(try DataPathIdentity.capture(history.verifiedSnapshot(for: backup)).matchesFilesystemObject(originalIdentity))
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("An offline retained original prevents another signature from discarding its recovery association")
    func offlineOriginalPreservesLineage() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("AppPorts Backups")
        let location = try SignatureBackupStorage.prepareDirectory(folder)
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true, backupDestination: { _, _ in location })
        _ = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let current = try SignatureSnapshot.fingerprint(of: fixture.app)
        let originalFact = try #require(try SignatureFactStore(backupDirectoryURL: fixture.backups).currentFact(at: fixture.app))
        let disconnected = fixture.root.appendingPathComponent("Disconnected")
        try FileManager.default.moveItem(at: folder, to: disconnected)
        await #expect(throws: (any Error).self) { try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier) }
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == current)
        #expect(try SignatureFactStore(backupDirectoryURL: fixture.backups).currentFact(at: fixture.app) == originalFact)
        try FileManager.default.moveItem(at: disconnected, to: folder)
        let restored = try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(restored.committed && restored.cleanupWarning == nil)
    }

    @Test("Committed cleanup records the typed blocker before returning a success warning")
    func committedCleanupRetainsDiagnosticCause() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let blocker = OperationBlockage(reason: .backupDependency, applicationURL: fixture.app,
            blockingOperationID: UUID(), blockingPhase: "prepared")
        let location = try SignatureBackupStorage.prepareDirectory(fixture.root.appendingPathComponent("AppPorts Backups"))
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true,
            synchronizeTree: { url in
                if url.lastPathComponent.hasPrefix("original-") { throw blocker }
                try DurableFileIO.syncTree(at: url)
            }, backupDestination: { _, _ in location })
        let result = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(result.committed)
        #expect(result.cleanupWarning?.contains(try #require(blocker.blockingOperationID).uuidString) == true)
        let operationID = try #require(result.operationID)
        let summary = try #require(AppLogger.shared.recentOperationSummariesSnapshot().last {
            $0.operationID == operationID.uuidString && $0.details["failure_stage"] == "committed_cleanup"
        })
        #expect(summary.result == "success_with_warning")
        #expect(summary.errorCode == blocker.diagnosticCode)
        #expect(summary.details["record_id"] == operationID.uuidString)
        #expect(summary.details["application_path"] == fixture.app.path)
        #expect(summary.details["cause_blocking_operation_id"] == blocker.blockingOperationID?.uuidString)
        #expect(summary.details["cause_blocking_phase"] == "prepared")
        #expect(try SignatureOperationStore(backupDirectoryURL: fixture.backups).record(id: operationID).phase == .committed)
    }

    @Test("A published copy is rechecked before a cold retry deletes the remaining local original")
    func offlineCopyPreventsSourceCleanup() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let location = try SignatureBackupStorage.prepareDirectory(fixture.root.appendingPathComponent("AppPorts Backups"))
        let result = try await fixture.signer(officialEvidence: true, captureOfficialOriginal: true,
            deleteTemporary: { _, _, _, _ in throw Injected.failure },
            backupDestination: { _, _ in location }, preferMovingOriginal: false)
            .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(result.cleanupWarning != nil)
        let operations = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let pending = try #require(try operations.records().first)
        #expect(pending.originalBackup?.completed == true)
        let original = try SignatureSnapshot.fingerprint(of: pending.candidateURL)
        let disconnected = fixture.root.appendingPathComponent("Disconnected")
        try FileManager.default.moveItem(at: location.displayURL, to: disconnected)
        #expect(await fixture.signer(officialEvidence: true, captureOfficialOriginal: true).performAutomaticMaintenance().isEmpty == false)
        #expect(try SignatureSnapshot.fingerprint(of: pending.candidateURL) == original)
        try FileManager.default.moveItem(at: disconnected, to: URL(fileURLWithPath: location.path))
        #expect(await fixture.signer(officialEvidence: true, captureOfficialOriginal: true).performAutomaticMaintenance().isEmpty)
        #expect(try operations.records().isEmpty)
    }

    @Test("Old internal originals relocate with durable recovery before and after publication", arguments: ["none", "copy", "remove"])
    func relocatesLegacyOriginal(interruption: String) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        _ = try await fixture.signer(officialEvidence: true, captureOfficialOriginal: true)
            .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        var backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        let source = try history.verifiedSnapshot(for: backup)
        let original = try SignatureSnapshot.fingerprint(of: source)
        backup.schemaVersion = 2
        backup.snapshotLocation = nil
        backup.snapshotIdentity = nil
        backup.applicationParentLocation = nil
        try history.write(backup)
        let location = try SignatureBackupStorage.prepareDirectory(fixture.root.appendingPathComponent("AppPorts Backups"))
        // Even before there is a relocation intent, a newly selected paused
        // destination must not acquire one or receive the snapshot.
        let ejection = DiskEjectionPauseStore(directory: fixture.root)
        let paused = try ejection.pause(.init(deviceIdentifier: "fixture", connectionID: "fixture:1", displayName: "Fixture",
            volumeUUIDs: ["PAUSED-FIXTURE"], containerUUIDs: [], mountPaths: [location.path]))
        let beforePause = try history.read(bundleIdentifier: fixture.identifier)
        _ = await fixture.signer(officialEvidence: true, captureOfficialOriginal: true,
            copy: { _, _ in Issue.record("A newly selected paused destination must not be copied into"); throw Injected.failure },
            backupDestination: { _, _ in location }).performAutomaticMaintenance()
        #expect(try history.read(bundleIdentifier: fixture.identifier) == beforePause)
        #expect(try SignatureSnapshot.fingerprint(of: source) == original)
        _ = try ejection.reconcile(.init(disks: [.init(deviceIdentifier: "fixture", connectionID: "fixture:2",
                displayName: paused.displayName, volumeUUIDs: paused.volumeUUIDs, containerUUIDs: paused.containerUUIDs, mountPaths: paused.mountPaths)]))
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true, copy: { from, to in
            if interruption == "copy" {
                try FileManager.default.createDirectory(at: to.appendingPathComponent("Contents"), withIntermediateDirectories: false)
                throw Injected.failure
            }
            try SignatureSnapshot.copyContents(from: from, into: to)
        }, deleteTemporary: { path, manifest, partial, unlock in
            if interruption == "remove" {
                try FileManager.default.removeItem(at: path.appendingPathComponent("Contents/Resources/payload"))
                throw Injected.failure
            }
            try manifest.remove(at: path, allowingPartial: partial, unlockCopiedFlags: unlock)
        }, backupDestination: { _, _ in location })
        let warnings = await signer.performAutomaticMaintenance()
        #expect(warnings.isEmpty == (interruption == "none"))
        if interruption != "none" {
            let pending = try #require(try history.read(bundleIdentifier: fixture.identifier))
            #expect(pending.relocation != nil)
            #expect(pending.relocation?.published == (interruption == "remove"))
            #expect(try SignatureSnapshot.entryExists(source))
            let pauses = DiskEjectionPauseStore(directory: fixture.root)
            let pause = try pauses.pause(.init(deviceIdentifier: "fixture", connectionID: "fixture:1", displayName: "Fixture",
                volumeUUIDs: ["PAUSED-FIXTURE"], containerUUIDs: [], mountPaths: [location.path]))
            _ = await fixture.signer(officialEvidence: true, captureOfficialOriginal: true,
                copy: { _, _ in Issue.record("Paused relocation must not copy"); throw Injected.failure },
                deleteTemporary: { _, _, _, _ in Issue.record("Paused relocation must not delete"); throw Injected.failure },
                backupDestination: { _, _ in location }).performAutomaticMaintenance()
            #expect(try history.read(bundleIdentifier: fixture.identifier) == pending)
            _ = try pauses.reconcile(.init(disks: [.init(deviceIdentifier: "fixture", connectionID: "fixture:2",
                displayName: pause.displayName, volumeUUIDs: pause.volumeUUIDs, containerUUIDs: pause.containerUUIDs, mountPaths: pause.mountPaths)]))
            #expect(await fixture.signer(officialEvidence: true, captureOfficialOriginal: true,
                backupDestination: { _, _ in location }).performAutomaticMaintenance().isEmpty)
        }
        let migrated = try #require(try history.read(bundleIdentifier: fixture.identifier))
        #expect(migrated.schemaVersion == 3 && migrated.relocation == nil)
        #expect(try history.snapshotParent(for: migrated) == location.resolve())
        #expect(try SignatureSnapshot.fingerprint(of: history.verifiedSnapshot(for: migrated)) == original)
        #expect(try !SignatureSnapshot.entryExists(source))
        let restored = try await fixture.signer(officialEvidence: true, captureOfficialOriginal: true)
            .restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(restored.committed && restored.cleanupWarning == nil)
    }

    @Test("Unrecoverable old records retire only their index while preserving independent signature facts", arguments: [false, true])
    func retiresMissingOriginalIndex(identityOnly: Bool) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true)
        _ = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        var backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        try SignatureSnapshot.remove(history.verifiedSnapshot(for: backup))
        if identityOnly {
            backup.schemaVersion = nil
            backup.snapshotName = nil
            backup.originalFingerprint = nil
            backup.originalDeveloper = nil
            backup.applicationIdentity = nil
            backup.version = nil
            try history.write(backup)
        }
        #expect(await signer.performAutomaticMaintenance().isEmpty)
        #expect(try history.read(bundleIdentifier: fixture.identifier) == nil)
        let fact = try #require(try SignatureFactStore(backupDirectoryURL: fixture.backups).currentFact(at: fixture.app))
        #expect(fact.signatureWasReplaced && fact.originalDeveloper == Fixture.developer)
        #expect(fact.legacyBackupRecordPath == nil)
    }

    @Test("A legacy name-only record remains when the current fact has a different origin", arguments: [false, true])
    func retainsUnprovenLegacyIdentity(withFact: Bool) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true)
        if withFact { _ = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true) }
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        try FileManager.default.createDirectory(at: fixture.backups, withIntermediateDirectories: true)
        let backup = SignatureBackup(bundleIdentifier: fixture.identifier, signingIdentity: "Different Old Developer",
            originalPath: fixture.app.path, backupDate: Date(timeIntervalSince1970: 100))
        try history.write(backup)
        _ = await signer.performAutomaticMaintenance()
        #expect(try history.read(bundleIdentifier: fixture.identifier) == backup)
    }

    @Test("A changed second ad-hoc signature still restores from its schema-3 original")
    func subsequentSignatureExtendsExternalLineage() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true)
        _ = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let first = try SignatureSnapshot.fingerprint(of: fixture.app)
        let changed = fixture.signer(officialEvidence: true, captureOfficialOriginal: true, runner: ChangedSignatureRunner())
        let result = try await changed.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(result.committed && result.cleanupWarning == nil)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) != first)
        let restored = try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(restored.committed && restored.cleanupWarning == nil)
    }

    private struct ChangedSignatureRunner: ShellCommandRunning {
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            var arguments = arguments
            if arguments.contains("--sign") {
                arguments.insert(contentsOf: ["--identifier", "com.appports.tests.changed-signature"], at: arguments.count - 1)
            }
            return try await ProcessCommandRunner().run(executable: executable, arguments: arguments, timeout: timeout)
        }
    }

    @Test("Signing unsigned code leaves a current fact without inventing an official original")
    func noPermanentBackup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = try await fixture.signer().sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(result.committed)
        #expect(result.cleanupWarning == nil)
        #expect(try fixture.signingMaterialsAreEmpty())
        #expect(try SignatureFactStore(backupDirectoryURL: fixture.backups).facts().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(at: fixture.backups, includingPropertiesForKeys: nil).allSatisfy { $0.pathExtension != "app" && $0.pathExtension != "plist" })
        #expect(!FileManager.default.fileExists(atPath: fixture.backups.appendingPathComponent("retired").path))
        let appDirectories = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasPrefix(".AppPorts-signature-") }
        #expect(appDirectories.isEmpty)
    }

    @Test("Classic signing automatically keeps its official original through repeated signing and restores it")
    func automaticallyRetainsAndRestoresOfficialOriginal() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true)
        let signed = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(signed.committed && signed.cleanupWarning == nil)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        #expect(backup.originalFingerprint == original)
        #expect(backup.originalDeveloper == Fixture.developer)
        #expect(backup.originalApplicationGroups == ["group.not-related-to-app-name.shared"])
        #expect(try SignatureSnapshot.fingerprint(of: history.verifiedSnapshot(for: backup)) == original)
        _ = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(try history.read(bundleIdentifier: fixture.identifier)?.snapshotName == backup.snapshotName)
        _ = await signer.performAutomaticMaintenance()
        #expect(try history.read(bundleIdentifier: fixture.identifier) != nil)
        let restored = try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(restored.committed && restored.cleanupWarning == nil)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
        #expect(try history.read(bundleIdentifier: fixture.identifier) == nil)
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("A failed original-backup copy keeps the exchanged original and completes on a cold retry")
    func originalRetentionResumesAfterPartialCopy() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let failing = fixture.signer(officialEvidence: true, captureOfficialOriginal: true, copy: { source, destination in
            if destination.lastPathComponent.hasPrefix("original-") {
                try FileManager.default.createDirectory(at: destination.appendingPathComponent("Contents"), withIntermediateDirectories: false)
                throw Injected.failure
            }
            try SignatureSnapshot.copyContents(from: source, into: destination)
        }, preferMovingOriginal: false)
        let result = try await failing.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(result.committed && result.cleanupWarning != nil)
        let operations = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let pending = try #require(try operations.records().first)
        #expect(pending.schemaVersion == 3 && pending.originalBackup?.completed == false)
        #expect(!pending.cleanupStarted)
        #expect(try SignatureSnapshot.fingerprint(of: pending.candidateURL) == original)
        let warnings = await fixture.signer(officialEvidence: true, captureOfficialOriginal: true).performAutomaticMaintenance()
        #expect(warnings.isEmpty)
        #expect(try operations.records().isEmpty)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        #expect(try SignatureSnapshot.fingerprint(of: history.verifiedSnapshot(for: backup)) == original)
    }

    @Test("An official update retires a backup only after authenticated developer verification", arguments: [false, true])
    func officialUpdateRetention(wrongDeveloper: Bool) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("OfficialUpdate.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true)
        _ = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        try Data("official updated data".utf8).write(to: official.appendingPathComponent("Contents/Resources/payload"))
        let signing = try await ProcessCommandRunner().run(executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--entitlements", fixture.root.appendingPathComponent("entitlements.plist").path, official.path], timeout: 30)
        #expect(signing.status == 0)
        try SignatureSnapshot.exchange(fixture.app, official)
        let developer = wrongDeveloper ? OriginalDeveloperIdentity(authority: "Different Developer",
            teamIdentifier: "OTHERTEAM0", designatedRequirement: "identifier other", certificateSHA256: String(repeating: "b", count: 64)) : Fixture.developer
        _ = await fixture.signer(officialEvidence: true, captureOfficialOriginal: true, officialDeveloper: developer).performAutomaticMaintenance()
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        #expect((try history.read(bundleIdentifier: fixture.identifier) != nil) == wrongDeveloper)
        #expect(try String(contentsOf: fixture.app.appendingPathComponent("Contents/Resources/payload"), encoding: .utf8) == "official updated data")
    }

    @Test("A saved original and signature fact can finish after the last retention checkpoint was interrupted")
    func originalRetentionResumesAfterHistoryAndFactCommit() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let signer = fixture.signer(officialEvidence: true, captureOfficialOriginal: true, checkpoint: { record in
            if record.originalBackup?.completed == true { throw Injected.failure }
        })
        let result = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(result.committed && result.cleanupWarning != nil)
        let operations = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let pending = try #require(try operations.records().first)
        #expect(pending.originalBackup?.completed == false)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        let snapshotIdentity = try DataPathIdentity.capture(history.verifiedSnapshot(for: backup))
        let warnings = await fixture.signer(officialEvidence: true, captureOfficialOriginal: true).performAutomaticMaintenance()
        #expect(warnings.isEmpty)
        #expect(try operations.records().isEmpty)
        let retained = try #require(try history.read(bundleIdentifier: fixture.identifier))
        #expect(try DataPathIdentity.capture(history.verifiedSnapshot(for: retained)) == snapshotIdentity)
    }

    @Test("An original-backup obligation cannot be decoded as a legacy signature operation")
    func originalBackupRequiresNewOperationSchema() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        _ = try await fixture.signer(officialEvidence: true, captureOfficialOriginal: true, checkpoint: { record in
            if record.originalBackup?.completed == true { throw Injected.failure }
        }).sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let operations = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        var pending = try #require(try operations.records().first)
        pending.schemaVersion = 1
        let url = operations.directoryURL.appendingPathComponent(pending.id.uuidString + ".plist")
        let bytes = try PropertyListEncoder().encode(pending)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try operations.read(url) }
        _ = await fixture.signer(officialEvidence: true, captureOfficialOriginal: true).performAutomaticMaintenance()
        #expect(try Data(contentsOf: url) == bytes)
        let original = try #require(pending.originalBackup)
        #expect(try SignatureSnapshot.entryExists(try #require(SignatureHistoryStore(backupDirectoryURL: fixture.backups).snapshotURL(for: original.backup))))
    }

    @Test("Official updates retain the old original while an operation depends on a removed application group")
    func officialUpdateKeepsOldGroupDependencies() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("OfficialUpdate.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        _ = try await fixture.signer(officialEvidence: true, captureOfficialOriginal: true)
            .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let entitlements = fixture.root.appendingPathComponent("updated-entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.app-sandbox": true], format: .xml, options: 0)
            .write(to: entitlements)
        try Data("new official content".utf8).write(to: official.appendingPathComponent("Contents/Resources/payload"))
        let signed = try await ProcessCommandRunner().run(executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--entitlements", entitlements.path, official.path], timeout: 30)
        #expect(signed.status == 0)
        try SignatureSnapshot.exchange(fixture.app, official)
        let home = fixture.root.appendingPathComponent("Home")
        let group = home.appendingPathComponent("Library/Group Containers/group.not-related-to-app-name.shared/Store")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try Data("latest group data".utf8).write(to: group.appendingPathComponent("payload"))
        let data = ContainerMountStore(fileURL: fixture.root.appendingPathComponent("group-operation.plist"))
        let pending = DataTransferRecord(mode: .symlink, direction: .migrate, appName: "Shared Group",
            bundleIdentifier: "org.unrelated.app", dataDirType: "groupContainers", originalPath: group.path,
            activePath: group.path, destinationPath: fixture.root.appendingPathComponent("ExternalGroup").path,
            sourceIdentity: try DataPathIdentity.capture(group))
        try data.beginTransfer(pending)
        let maintenance = fixture.signer(officialEvidence: true, captureOfficialOriginal: true,
            dataTransferStore: data, homeDirectory: home)
        _ = await maintenance.performAutomaticMaintenance()
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        #expect(try history.read(bundleIdentifier: fixture.identifier) != nil)
        try data.endUnswitchedTransfer(pending) { }
        #expect(await maintenance.performAutomaticMaintenance().isEmpty)
        #expect(try history.read(bundleIdentifier: fixture.identifier) == nil)
        #expect(try String(contentsOf: group.appendingPathComponent("payload"), encoding: .utf8) == "latest group data")
    }

    @Test("Temporary-space preview charges sparse official content at logical size in the target's actual parent")
    func temporarySpacePreviewUsesFullCopySizeAndDestinationParent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("OfficialSource/Official.app")
        try FileManager.default.createDirectory(at: official.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let sparse = official.appendingPathComponent("Contents/Resources/sparse-payload")
        #expect(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let size: UInt64 = 2 * 1024 * 1024 * 1024
        let file = try FileHandle(forWritingTo: sparse)
        try file.truncate(atOffset: size)
        try file.close()
        let local = try CodeSigner.temporarySpaceRequirement(appURL: fixture.app)
        let restoration = try CodeSigner.temporarySpaceRequirement(appURL: fixture.app, sourceURL: official)
        #expect(restoration.parentURL.path == fixture.app.deletingLastPathComponent().path)
        #expect(restoration.logicalSourceBytes >= Int64(size))
        #expect(restoration.requiredAdditionalBytes > restoration.logicalSourceBytes)
        #expect(restoration.requiredAdditionalBytes >= local.requiredAdditionalBytes + Int64(size))
        #expect(Int64(try SignatureSnapshot.info(at: sparse).st_blocks) * 512 < Int64(size))
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("Insufficient full-copy capacity is rejected before creating a candidate or running codesign")
    func insufficientTemporarySpacePreservesApplicationBeforeCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let commands = RecordingRunner()
        let signer = fixture.signer(runner: commands, availableTemporaryCapacity: { parent in
            #expect(parent.path == fixture.root.path)
            let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            #expect(names.allSatisfy { !$0.hasPrefix(".AppPorts-signature-") })
            return 0
        })
        do {
            try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
            Issue.record("A full-copy candidate must not be started without enough available capacity")
        } catch CodeSigner.SigningError.insufficientTemporarySpace(let parent, let required, let available) {
            #expect(parent.path == fixture.root.path)
            #expect(required > 0 && available == 0)
        }
        #expect(await commands.signCount == 0)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("Official restoration also checks the candidate capacity before changing the signed installation")
    func officialRestorationRechecksTemporaryCapacity() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        try await fixture.signer(officialEvidence: true).sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let signer = fixture.signer(officialEvidence: true, availableTemporaryCapacity: { _ in 0 })
        do {
            try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier, originalApplication: official)
            Issue.record("Restoration must check available space before creating its official candidate")
        } catch CodeSigner.SigningError.insufficientTemporarySpace(_, let required, let available) {
            #expect(required > 0 && available == 0)
        }
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("The prepared candidate rechecks remaining space without requiring a second full-copy budget", arguments: [Int64(0), Int64(16 * 1024 * 1024)])
    func capacityChangeBeforeExchange(remainingBytes: Int64) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let beforeIdentity = try DataPathIdentity.capture(fixture.app)
        let capacity = CapacitySequence(afterCopy: remainingBytes)
        let commands = RecordingRunner()
        let signer = fixture.signer(runner: commands, availableTemporaryCapacity: { _ in capacity.next() })
        do {
            let result = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
            #expect(remainingBytes > 0)
            #expect(result.committed && result.cleanupWarning == nil)
        } catch CodeSigner.SigningError.insufficientTemporarySpace(_, let required, let available) {
            #expect(remainingBytes == 0 && available == 0 && required > 0)
            #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
            #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(beforeIdentity))
        }
        #expect(capacity.callCount == 2)
        #expect(await commands.signCount == 1)
        #expect(try fixture.signingMaterialsAreEmpty())
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".AppPorts-signature-") })
    }

    @Test("Cancelling inside a native ordinary-copy write stops the Contents tree and leaves an actionable journal")
    func nativeOrdinaryCopyCancellationRetainsRecoverableCandidate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let names = (0..<3).map { "copy-stop-\($0)" }
        let resources = fixture.app.appendingPathComponent("Contents/Resources")
        let sourceSize: Int64 = 16 * 1024 * 1024
        let block = Data(repeating: 0xa5, count: 1_048_576)
        for name in names {
            let url = resources.appendingPathComponent(name)
            try block.write(to: url)
            let output = try FileHandle(forWritingTo: url)
            try output.seekToEnd()
            for _ in 1..<16 { try output.write(contentsOf: block) }
            try output.close()
        }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let identity = try DataPathIdentity.capture(fixture.app)
        let observation = CopyCancellationObservation()
        let commands = RecordingRunner()
        let signer = CodeSigner(backupDirectoryURL: fixture.backups, allowAdministratorPrompt: false,
            copyApplication: { source, destination in
                try SignatureSnapshot.copyContents(from: source, into: destination, allowCloning: false, onDataCopied: { sourceFile, copied in
                    guard names.contains(sourceFile.lastPathComponent), copied > 0 else { return }
                    observation.record(path: sourceFile.lastPathComponent, copied: copied)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
            }, runner: commands, requireStopped: { _, _ in }, recoveryDependencyCheck: { _ in })
        let task = Task { try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier) }
        await #expect(throws: CancellationError.self) { try await task.value }
        let firstWrite = try #require(observation.first)
        #expect(firstWrite.copied > 0 && firstWrite.copied <= 1_048_576 && firstWrite.copied < sourceSize)
        #expect(observation.callCount == 1)
        #expect(await commands.signCount == 0)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(identity))
        let records = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let pending = try #require(try records.records().first)
        #expect(pending.phase == .cancelling)
        #expect(pending.candidateIdentity != nil && pending.directoryIdentity != nil)
        let copiedResources = pending.candidateURL.appendingPathComponent("Contents/Resources")
        for name in names where name != firstWrite.path {
            #expect(try !SignatureSnapshot.entryExists(copiedResources.appendingPathComponent(name)))
        }
        let interruptedFile = copiedResources.appendingPathComponent(firstWrite.path)
        // libcopyfile unlinks the current destination when copyfile_data
        // returns ECANCELED. Some platform versions may retain a partial file;
        // neither outcome permits a completed payload or further tree copying.
        if try SignatureSnapshot.entryExists(interruptedFile) {
            let partial = try FileHandle(forReadingFrom: interruptedFile)
            try partial.seek(toOffset: UInt64(sourceSize - 1))
            #expect(try partial.read(upToCount: 1)?.first != 0xa5)
            try partial.close()
        }
        let candidateIdentity = try #require(pending.candidateIdentity)
        let directoryIdentity = try #require(pending.directoryIdentity)
        #expect(try DataPathIdentity.capture(pending.candidateURL).matchesFilesystemObject(candidateIdentity))
        #expect(try DataPathIdentity.capture(pending.directoryURL).matchesFilesystemObject(directoryIdentity))
        let material = try #require(try await signer.signatureMaterials().first(where: { $0.id == "operation:" + pending.id.uuidString }))
        #expect(material.canCancel && !material.canDelete)
        let result = try await fixture.signer().cancelSignatureMaterial(id: material.id)
        #expect(!result.committed && result.cleanupWarning == nil)
        #expect(try records.records().isEmpty)
        #expect(try !SignatureSnapshot.entryExists(pending.directoryURL))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
    }

    @Test("Original developer facts survive repeated signing and a verified relocation before no-backup official repair")
    func repeatedSigningRelocationAndOfficialRepair() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let data = fixture.root.appendingPathComponent("SeparateUserData")
        try Data("user data remains independent".utf8).write(to: data)
        let dependencyChecks = Checks()
        let signer = fixture.signer(officialEvidence: true, recoveryCheck: { requirements in
            await dependencyChecks.append(requirements)
        })
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let store = SignatureFactStore(backupDirectoryURL: fixture.backups)
        let first = try #require(try store.currentFact(at: fixture.app, verifyContent: true))
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let second = try #require(try store.currentFact(at: fixture.app, verifyContent: true))
        #expect(first.installationID == second.installationID)
        #expect(second.originalDeveloper == Fixture.developer)
        #expect(second.originalFingerprint == first.originalFingerprint)
        #expect(try store.facts().count == 1)
        #expect(await !signer.hasBackup(bundleIdentifier: fixture.identifier))

        let relocation = try #require(try store.captureRelocation(from: fixture.app))
        let moved = fixture.root.appendingPathComponent("External/Installed.app")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SignatureSnapshot.copy(from: fixture.app, to: moved)
        try SignatureSnapshot.remove(fixture.app)
        try FileManager.default.createSymbolicLink(at: fixture.app, withDestinationURL: moved)
        try store.commitRelocation(relocation, to: moved)
        try store.commitRelocation(relocation, to: moved)
        #expect(try store.currentFact(at: moved)?.installationID == first.installationID)

        let result = try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier, originalApplication: official)
        #expect(result.committed)
        #expect(result.cleanupWarning == nil)
        #expect(CodeSigner.isSandboxed(at: moved))
        #expect(try SignatureSnapshot.fingerprint(of: moved) == SignatureSnapshot.fingerprint(of: official))
        #expect(try String(contentsOf: data, encoding: .utf8) == "user data remains independent")
        let checks = await dependencyChecks.values
        #expect(checks.count == 2)
        #expect(checks.allSatisfy { $0.applicationGroups == ["group.not-related-to-app-name.shared"] })
        #expect(try store.currentFact(at: moved)?.signatureWasReplaced == false)
    }

    @Test("Cancellation after exchange preserves identity before repeated signing and official repair", arguments: [false, true])
    func postCommitCancellationKeepsOfficialIdentity(legacyBackup: Bool) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let firstSigner = fixture.signer(officialEvidence: true, checkpoint: { record in
            if record.phase == .committed { withUnsafeCurrentTask { $0?.cancel() } }
        })
        if legacyBackup {
            try await firstSigner.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        }
        let task = Task { try await firstSigner.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true) }
        let first = try await task.value
        #expect(first.committed && first.cleanupWarning != nil)
        let facts = SignatureFactStore(backupDirectoryURL: fixture.backups)
        let firstFact = try #require(try facts.currentFact(at: fixture.app, verifyContent: true))
        #expect(firstFact.originalDeveloper == Fixture.developer)
        if legacyBackup {
            let backup = try #require(try SignatureHistoryStore(backupDirectoryURL: fixture.backups).read(bundleIdentifier: fixture.identifier))
            #expect(backup.restorableFingerprints?.contains(firstFact.currentFingerprint) == true)
            #expect(backup.applicationIdentity?.matchesFilesystemObject(firstFact.applicationIdentity) == true)
        }

        // Both old packages may remain pending; neither cleanup is a prerequisite
        // for the next explicitly authorized signature or official repair.
        let second = try await fixture.signer(officialEvidence: true, deleteTemporary: { _, _, _, _ in throw Injected.failure })
            .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(second.committed && second.cleanupWarning != nil)
        let secondFact = try #require(try facts.currentFact(at: fixture.app, verifyContent: true))
        #expect(secondFact.installationID == firstFact.installationID)
        #expect(secondFact.originalDeveloper == Fixture.developer)
        let restored = try await fixture.signer(officialEvidence: true).restoreSignature(
            appURL: fixture.app, bundleIdentifier: fixture.identifier, originalApplication: official)
        #expect(restored.committed && restored.cleanupWarning == nil)
        let officialFact = try #require(try facts.currentFact(at: fixture.app, verifyContent: true))
        #expect(!officialFact.signatureWasReplaced)
        let operations = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        for record in try operations.records() {
            let cleaned = try await fixture.signer().resumeSignatureMaterial(id: "operation:" + record.id.uuidString)
            #expect(cleaned.committed && cleaned.cleanupWarning == nil)
        }
        #expect(try operations.records().isEmpty)
        #expect(try facts.currentFact(at: fixture.app, verifyContent: true) == officialFact)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == SignatureSnapshot.fingerprint(of: official))
    }

    @Test("An exchanged app whose fact was not saved can next be signed or moved without losing official provenance", arguments: [false, true])
    func unpublishedCommittedFactSurvivesNextOperation(moveBeforeRepair: Bool) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let result = try await fixture.signer(officialEvidence: true, checkpoint: { record in
            if record.phase == .committed { throw Injected.failure }
        }).sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(result.committed && result.cleanupWarning != nil)
        let transfers = AppTransferStore(directoryURL: fixture.root.appendingPathComponent("Transfers"))
        let facts = SignatureFactStore(backupDirectoryURL: fixture.backups, applicationTransferStore: transfers)
        #expect(try facts.currentFact(at: fixture.app) == nil)
        let operationStore = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let interrupted = try #require(try operationStore.records().first)
        #expect(interrupted.phase == .switching)
        let expectedID = try #require(interrupted.pendingFact?.installationID)
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 }, transferStore: transfers,
            signatureFactStore: facts, runningApplications: { [] })
        let active: URL
        if moveBeforeRepair {
            active = fixture.root.appendingPathComponent("External/Installed.app")
            try FileManager.default.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
            let moved = try await service.moveAndLink(appToMove: AppItem(name: "Installed", path: fixture.app, status: AppStatus.local),
                destinationURL: active, isRunning: false, lockExternal: false, progressHandler: nil)
            #expect(moved.isComplete)
        } else {
            active = fixture.app
            let signed = try await fixture.signer(officialEvidence: true, applicationTransferStore: transfers)
                .sign(appURL: active, bundleIdentifier: fixture.identifier)
            #expect(signed.committed && signed.cleanupWarning == nil)
        }
        let current = try #require(try facts.currentFact(at: active, verifyContent: true))
        #expect(current.installationID == expectedID && current.originalDeveloper == Fixture.developer)
        let repaired = try await fixture.signer(officialEvidence: true, applicationTransferStore: transfers)
            .restoreSignature(appURL: active, bundleIdentifier: fixture.identifier, originalApplication: official)
        #expect(repaired.committed && repaired.cleanupWarning == nil)
        if moveBeforeRepair {
            let local = try await service.moveBack(app: AppItem(name: "Installed", path: active, status: AppStatus.external),
                localDestinationURL: fixture.app, progressHandler: nil)
            #expect(local.transferResult.isComplete)
        }
        let officialFact = try #require(try facts.currentFact(at: fixture.app, verifyContent: true))
        #expect(officialFact.installationID == expectedID && !officialFact.signatureWasReplaced)
        for record in try operationStore.records() {
            let cleaned = try await fixture.signer().resumeSignatureMaterial(id: "operation:" + record.id.uuidString)
            #expect(cleaned.cleanupWarning == nil)
        }
        #expect(try facts.currentFact(at: fixture.app, verifyContent: true) == officialFact)
        #expect(try operationStore.records().isEmpty && transfers.records().isEmpty)
    }

    @Test("A committed migration keeps cleanup authority after a verified same-version official repair with a different fingerprint")
    func migrationFactFailureBeforeResigningRetainsIdentityAndCleanup() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        // Resource modes are part of our full-package fingerprint but do not
        // invalidate this real synthetic application's strict code signature.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
            ofItemAtPath: official.appendingPathComponent("Contents/Resources/payload").path)
        let officialFingerprint = try SignatureSnapshot.fingerprint(of: official)
        #expect(try officialFingerprint != SignatureSnapshot.fingerprint(of: fixture.app))
        let transfers = AppTransferStore(directoryURL: fixture.root.appendingPathComponent("Transfers"))
        let facts = SignatureFactStore(backupDirectoryURL: fixture.backups, applicationTransferStore: transfers)
        let commands = RecordingRunner()
        try await fixture.signer(officialEvidence: true, runner: commands, applicationTransferStore: transfers)
            .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let originalFact = try #require(try facts.currentFact(at: fixture.app, verifyContent: true))
        let external = fixture.root.appendingPathComponent("External/Installed.app")
        try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        let interrupted = AppMigrationService(dockShortcutUpdater: { _, _ in 0 }, transferStore: transfers,
            signatureFactStore: facts, transferHooks: .init(checkpoint: { point, _ in
                if point == .committed { throw Injected.failure }
            }), runningApplications: { [] })
        let moved = try await interrupted.moveAndLink(appToMove: AppItem(name: "Installed", path: fixture.app, status: AppStatus.local),
            destinationURL: external, isRunning: false, lockExternal: false, progressHandler: nil)
        #expect(moved.isSwitchComplete && !moved.isComplete)
        #expect(try !transfers.record(moved.operationID).signatureFactsCommitted)
        #expect(try facts.currentFact(at: external) == nil)
        let signer = fixture.signer(officialEvidence: true, runner: commands, applicationTransferStore: transfers)
        #expect(await signer.verify(appURL: official) == .valid)
        let signed = try await signer.sign(appURL: external, bundleIdentifier: fixture.identifier)
        #expect(signed.committed && signed.cleanupWarning == nil)
        let current = try #require(try facts.currentFact(at: external, verifyContent: true))
        #expect(current.installationID == originalFact.installationID && current.originalDeveloper == Fixture.developer)
        #expect(try transfers.record(moved.operationID).signatureFactsCommitted)
        let restored = try await signer.restoreSignature(appURL: external, bundleIdentifier: fixture.identifier, originalApplication: official)
        #expect(restored.committed && restored.cleanupWarning == nil)
        let restoredFact = try #require(try facts.currentFact(at: external, verifyContent: true))
        #expect(restoredFact.installationID == originalFact.installationID)
        #expect(restoredFact.originalFingerprint == originalFact.originalFingerprint)
        #expect(restoredFact.currentFingerprint == officialFingerprint && !restoredFact.signatureWasReplaced)
        let beforeCleanup = try transfers.record(moved.operationID)
        let signingCount = await commands.signCount
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 }, transferStore: transfers,
            signatureFactStore: facts, transferHooks: .init(checkpoint: { point, _ in
                guard [.committed, .beforeCleanup, .afterCleanup].contains(point) else {
                    Issue.record("A committed cleanup must not replay transfer preparation: \(point)")
                    throw Injected.failure
                }
            }), runningApplications: { [] })
        let cleaned = try await service.retryTransfer(operationID: moved.operationID)
        #expect(cleaned.isComplete)
        #expect(try transfers.records().isEmpty)
        #expect(await commands.signCount == signingCount)
        #expect(try facts.currentFact(at: external, verifyContent: true) == restoredFact)
        #expect(try SignatureSnapshot.fingerprint(of: external) == officialFingerprint)
        for item in beforeCleanup.cleanupItems { #expect(try !SignatureSnapshot.entryExists(URL(fileURLWithPath: item.path))) }
        #expect(try !SignatureSnapshot.entryExists(URL(fileURLWithPath: beforeCleanup.stagePath)))
        #expect(try SignatureOperationStore(backupDirectoryURL: fixture.backups).records().isEmpty)
    }

    @Test("A replaced installation, different version, or different developer cannot finish another installation's committed migration",
          arguments: ["installation", "version", "developer"])
    func migrationCleanupDoesNotBorrowRepairedIdentity(change: String) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let transfers = AppTransferStore(directoryURL: fixture.root.appendingPathComponent("Transfers"))
        let facts = SignatureFactStore(backupDirectoryURL: fixture.backups, applicationTransferStore: transfers)
        let signer = fixture.signer(officialEvidence: true, applicationTransferStore: transfers)
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let originalFact = try #require(try facts.currentFact(at: fixture.app, verifyContent: true))
        let external = fixture.root.appendingPathComponent("External/Installed.app")
        try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        let interrupted = AppMigrationService(dockShortcutUpdater: { _, _ in 0 }, transferStore: transfers,
            signatureFactStore: facts, transferHooks: .init(checkpoint: { point, _ in
                if point == .beforeCleanup { throw Injected.failure }
            }), runningApplications: { [] })
        let moved = try await interrupted.moveAndLink(appToMove: AppItem(name: "Installed", path: fixture.app, status: AppStatus.local),
            destinationURL: external, isRunning: false, lockExternal: false, progressHandler: nil)
        #expect(moved.isSwitchComplete && !moved.isComplete)
        #expect(try transfers.record(moved.operationID).signatureFactsCommitted)
        let restored = try await signer.restoreSignature(appURL: external, bundleIdentifier: fixture.identifier, originalApplication: official)
        #expect(restored.committed && restored.cleanupWarning == nil)
        try FileManager.default.moveItem(at: external, to: fixture.root.appendingPathComponent("PreservedOriginalInstallation.app"))
        try SignatureSnapshot.copy(from: official, to: external)
        if change == "version" {
            let info = external.appendingPathComponent("Contents/Info.plist")
            var values = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
            values["CFBundleVersion"] = "2"
            values["CFBundleShortVersionString"] = "2.0"
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info)
            // Model a valid release of the other version, not a broken seal
            // whose failed verification must now stop before re-signing.
            let sealed = try await ProcessCommandRunner().run(executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", "--entitlements",
                    fixture.root.appendingPathComponent("entitlements.plist").path, external.path], timeout: 15)
            try #require(sealed.status == 0)
        }
        let otherDeveloper = OriginalDeveloperIdentity(authority: "Other Synthetic Developer", teamIdentifier: "DIFFERENT0",
            designatedRequirement: "identifier com.appports.tests.operations", certificateSHA256: String(repeating: "b", count: 64))
        let replacement = try await fixture.signer(officialEvidence: true,
            officialDeveloper: change == "developer" ? otherDeveloper : nil, applicationTransferStore: transfers)
            .sign(appURL: external, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(replacement.committed && replacement.cleanupWarning == nil)
        let replacementFact = try #require(try facts.currentFact(at: external, verifyContent: true))
        #expect(replacementFact.installationID != originalFact.installationID)
        if change == "version" { #expect(replacementFact.version != originalFact.version) }
        if change == "developer" { #expect(replacementFact.originalDeveloper == otherDeveloper) }
        let record = try transfers.record(moved.operationID)
        #expect(!record.canCancel && record.cleanupItems.contains { !$0.completed })
        let oldFingerprints = try Dictionary(uniqueKeysWithValues: record.cleanupItems.filter { !$0.completed }.map {
            ($0.path, try SignatureSnapshot.fingerprint(of: URL(fileURLWithPath: $0.path)))
        })
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 }, transferStore: transfers,
            signatureFactStore: facts, runningApplications: { [] })
        let pending = try await service.retryTransfer(operationID: moved.operationID)
        #expect(pending.isSwitchComplete && !pending.isComplete)
        #expect(pending.warnings.contains {
            $0.contains("记录中的活动应用已被替换或磁盘尚未连接，保留所有旧副本。".localized)
        })
        let cleanupEncoder = JSONEncoder()
        cleanupEncoder.outputFormatting = .sortedKeys
        #expect(try cleanupEncoder.encode(transfers.record(moved.operationID).cleanupItems)
            == cleanupEncoder.encode(record.cleanupItems))
        for (path, fingerprint) in oldFingerprints {
            #expect(try SignatureSnapshot.fingerprint(of: URL(fileURLWithPath: path)) == fingerprint)
        }
        #expect(try facts.currentFact(at: external, verifyContent: true) == replacementFact)
    }

    @Test("A pending signature fact cannot attach to a changed installation", arguments: [false, true])
    func unpublishedFactDoesNotAuthorizeReplacement(replaceObject: Bool) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        try await fixture.signer(officialEvidence: true, checkpoint: { record in
            if record.phase == .committed { throw Injected.failure }
        }).sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        if replaceObject {
            let saved = fixture.root.appendingPathComponent("OriginalSignedInstallation.app")
            try FileManager.default.moveItem(at: fixture.app, to: saved)
            try SignatureSnapshot.copy(from: saved, to: fixture.app)
        } else {
            try Data("changed after commit".utf8).write(to: fixture.app.appendingPathComponent("Contents/Resources/payload"))
        }
        let facts = SignatureFactStore(backupDirectoryURL: fixture.backups)
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        #expect(try facts.captureRelocation(from: fixture.app) == nil)
        #expect(try facts.currentFact(at: fixture.app) == nil)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
    }

    @Test("Another installation with identical ID, versions and signed bytes cannot borrow official repair authority")
    func refusesIdentityBorrowing() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let signer = fixture.signer(officialEvidence: true)
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let other = fixture.root.appendingPathComponent("SecondInstallation.app")
        try SignatureSnapshot.copy(from: fixture.app, to: other)
        #expect(try SignatureFactStore(backupDirectoryURL: fixture.backups).currentFact(at: other) == nil)
        let original = try SignatureSnapshot.fingerprint(of: other)
        await #expect(throws: CodeSigner.SigningError.self) {
            try await signer.restoreSignature(appURL: other, bundleIdentifier: fixture.identifier, originalApplication: official)
        }
        #expect(try SignatureSnapshot.fingerprint(of: other) == original)
    }

    @Test("A corrupt legacy record cannot veto official repair backed by current developer facts")
    func officialRepairWithUnreadableLegacyRecord() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let signer = fixture.signer(officialEvidence: true)
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let legacy = fixture.backups.appendingPathComponent(fixture.identifier + ".plist")
        let unreadable = Data("unreadable historical record".utf8)
        try unreadable.write(to: legacy)

        let result = try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier, originalApplication: official)
        #expect(result.committed)
        #expect(result.cleanupWarning == nil)
        #expect(CodeSigner.isSandboxed(at: fixture.app))
        #expect(try Data(contentsOf: legacy) == unreadable)
        let materials = try await signer.signatureMaterials()
        #expect(materials.count == 1)
        #expect(materials.first?.kind == .unreadableRecord)
    }

    @Test("One damaged operation stays visible while another same-ID installation can sign and restore", arguments: OperationDamage.allCases)
    func damagedOperationDoesNotBlockOtherInstallation(damage: OperationDamage) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        await #expect(throws: CancellationError.self) {
            try await fixture.signer(officialEvidence: true, synchronizeTree: { _ in throw CancellationError() })
                .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        }
        let store = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let pending = try #require(try store.records().first)
        let original = try SignatureSnapshot.fingerprint(of: fixture.app)
        let candidate = try SignatureSnapshot.fingerprint(of: pending.candidateURL)
        let broken = try damageOperation(pending, in: store, damage: damage)
        let second = fixture.root.appendingPathComponent("SecondInstallation.app")
        try SignatureSnapshot.copy(from: fixture.app, to: second)
        let signer = fixture.signer(officialEvidence: true)
        try await signer.backupOriginalSignature(appURL: second, bundleIdentifier: fixture.identifier)
        let signed = try await signer.sign(appURL: second, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(signed.committed && signed.cleanupWarning == nil)
        // Exercise the restore entry's pending-operation fast path as well.
        let restored = try await signer.restoreSignature(appURL: second, bundleIdentifier: fixture.identifier)
        #expect(restored.committed && restored.cleanupWarning == nil)
        #expect(try SignatureSnapshot.fingerprint(of: second) == original)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
        #expect(try SignatureSnapshot.fingerprint(of: pending.candidateURL) == candidate)
        #expect(try Data(contentsOf: broken.url) == broken.bytes)
        let inventory = try store.inventory()
        #expect(inventory.records.isEmpty && inventory.unreadableRecords.count == 1)
        let material = try #require(try await signer.signatureMaterials().first(where: { $0.url.path == broken.url.path }))
        #expect(material.kind == .unreadableRecord)
        #expect(!material.canResume && !material.canCancel && !material.canRestore && !material.canDelete && !material.canRemoveRecord)
        await #expect(throws: (any Error).self) {
            try await signer.cancelSignatureMaterial(id: "operation:" + pending.id.uuidString)
        }
        #expect(try Data(contentsOf: broken.url) == broken.bytes)
        #expect(try SignatureSnapshot.fingerprint(of: pending.candidateURL) == candidate)
    }

    @Test("A readable association in a damaged operation pauses its original or exchanged installation only", arguments: [false, true])
    func damagedRelatedOperationCannotBeBypassed(committed: Bool) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        if committed {
            let result = try await fixture.signer(officialEvidence: true, deleteTemporary: { _, _, _, _ in throw Injected.failure })
                .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
            #expect(result.committed && result.cleanupWarning != nil)
        } else {
            await #expect(throws: CancellationError.self) {
                try await fixture.signer(officialEvidence: true, synchronizeTree: { _ in throw CancellationError() })
                    .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
            }
        }
        let store = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let pending = try #require(try store.records().first)
        let broken = try damageOperation(pending, in: store, damage: .unsupportedVersion)
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let identity = try DataPathIdentity.capture(fixture.app)
        let commands = RecordingRunner()
        let signer = fixture.signer(officialEvidence: true, runner: commands)
        for restore in [false, true] {
            do {
                if restore {
                    _ = try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier, originalApplication: official)
                } else {
                    _ = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
                }
                Issue.record("An associated unreadable operation must be reported before new application work")
            } catch let error as OperationBlockage {
                #expect(error.reason == .signatureRecordUnreadable)
                #expect(error.recordURL?.path == broken.url.path)
                #expect(error.applicationURL?.resolvingSymlinksInPath().path == fixture.app.resolvingSymlinksInPath().path)
            }
        }
        #expect(await commands.signCount == 0)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(identity))
        #expect(try Data(contentsOf: broken.url) == broken.bytes)
    }

    @Test("A damaged old operation cannot reserve a replacement object's path forever")
    func damagedOperationDoesNotBlockReplacementAtSamePath() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        await #expect(throws: CancellationError.self) {
            try await fixture.signer(officialEvidence: true, synchronizeTree: { _ in throw CancellationError() })
                .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        }
        let store = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let pending = try #require(try store.records().first)
        let broken = try damageOperation(pending, in: store, damage: .invalidPhase)
        let old = fixture.root.appendingPathComponent("PreviousInstallation.app")
        try FileManager.default.moveItem(at: fixture.app, to: old)
        try SignatureSnapshot.copy(from: old, to: fixture.app)
        let before = try SignatureSnapshot.fingerprint(of: old)
        let signed = try await fixture.signer(officialEvidence: true)
            .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        #expect(signed.committed && signed.cleanupWarning == nil)
        #expect(try SignatureSnapshot.fingerprint(of: old) == before)
        #expect(try Data(contentsOf: broken.url) == broken.bytes)
        #expect(try SignatureSnapshot.entryExists(pending.directoryURL))
    }

    @Test("Damaged cleanup receipts do not hide independent originals, temporary operations, or valid cleanup actions")
    func damagedCleanupReceiptsAreIsolatedAndReadonly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let signer = fixture.signer(deleteTemporary: { _, _, _, _ in throw Injected.failure })
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        let historicalOriginal = try #require(history.snapshotURL(for: backup))
        let signed = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(signed.committed && signed.cleanupWarning != nil)
        let protected = fixture.backups.appendingPathComponent("Uncertain.app")
        let removable = fixture.backups.appendingPathComponent("Authorized.app")
        for target in [protected, removable] { try SignatureSnapshot.copy(from: fixture.app, to: target) }
        let protectedBefore = try SignatureSnapshot.fingerprint(of: protected)
        let invalid = try deletionFixture(for: protected)
        let valid = try deletionFixture(for: removable)
        try history.writeDeletion(invalid)
        try history.writeDeletion(valid)
        let invalidURL = history.cleanupDirectoryURL.appendingPathComponent(invalid.id.uuidString + ".plist")
        var corrupt = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: invalidURL), format: nil) as? [String: Any])
        corrupt["manifest"] = "not a deletion manifest"
        let corruptBytes = try PropertyListSerialization.data(fromPropertyList: corrupt, format: .binary, options: 0)
        try corruptBytes.write(to: invalidURL)
        let unknownURL = history.cleanupDirectoryURL.appendingPathComponent(UUID().uuidString + ".plist")
        let unknownBytes = Data("unreadable cleanup receipt".utf8)
        try unknownBytes.write(to: unknownURL)

        let reopened = fixture.signer()
        let materials = try await reopened.signatureMaterials()
        #expect(materials.contains { $0.url.path == historicalOriginal.path && $0.canRestore && $0.canDelete })
        #expect(materials.contains { $0.kind == .temporaryOperation && $0.canResume })
        let protectedMaterial = try #require(materials.first { $0.url.path == protected.path })
        #expect(!protectedMaterial.canDelete)
        for url in [invalidURL, unknownURL] {
            let diagnostic = try #require(materials.first { $0.url.path == url.path })
            #expect(diagnostic.kind == .unreadableRecord)
            #expect(!diagnostic.canResume && !diagnostic.canCancel && !diagnostic.canDelete && !diagnostic.canRestore && !diagnostic.canRemoveRecord)
            await #expect(throws: CodeSigner.SigningError.self) { try await reopened.deleteSignatureMaterial(id: diagnostic.id) }
            await #expect(throws: CodeSigner.SigningError.self) {
                try await reopened.removeSignatureMaterialRecord(id: diagnostic.id, confirmation: .keepAllFilesAndVolumes)
            }
        }
        let resumed = try await reopened.resumeSignatureMaterial(id: "history-cleanup:" + valid.id.uuidString)
        #expect(resumed.committed && resumed.cleanupWarning == nil)
        #expect(try !SignatureSnapshot.entryExists(removable))
        let temporaryID = try #require(materials.first { $0.kind == .temporaryOperation }?.id)
        let finished = try await reopened.resumeSignatureMaterial(id: temporaryID)
        #expect(finished.committed && finished.cleanupWarning == nil)
        let historyMaterial = try #require(try await reopened.signatureMaterials().first { $0.url.path == historicalOriginal.path })
        _ = try await reopened.deleteSignatureMaterial(id: historyMaterial.id)
        #expect(try !SignatureSnapshot.entryExists(historicalOriginal))
        #expect(try SignatureSnapshot.fingerprint(of: protected) == protectedBefore)
        #expect(try Data(contentsOf: invalidURL) == corruptBytes)
        #expect(try Data(contentsOf: unknownURL) == unknownBytes)
        #expect(try history.deletions().isEmpty)
        #expect(try history.deletionInventory().unreadableRecords.count == 2)
    }

    @Test("Directory faults stay visible without hiding readable history or independent signature operations",
          arguments: SignatureDirectoryDamage.allCases)
    func signatureDirectoryFailuresStayLocal(damage: SignatureDirectoryDamage) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let operationStore = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let factStore = SignatureFactStore(backupDirectoryURL: fixture.backups)
        try await fixture.signer().backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        let original = try #require(history.snapshotURL(for: backup))
        let originalFingerprint = try SignatureSnapshot.fingerprint(of: original)
        await #expect(throws: CancellationError.self) {
            try await fixture.signer(synchronizeTree: { _ in throw CancellationError() })
                .sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        }
        let pending = try #require(try operationStore.records().first)
        let appFingerprint = try SignatureSnapshot.fingerprint(of: fixture.app)
        let badDirectory: URL
        switch damage {
        case .retiredFile, .retiredUnreadable: badDirectory = fixture.backups.appendingPathComponent("retired")
        case .factsFile: badDirectory = factStore.directoryURL
        case .operationsFile: badDirectory = operationStore.directoryURL
        case .cleanupFile: badDirectory = history.cleanupDirectoryURL
        case .historyRootFile: badDirectory = fixture.backups
        }
        let saved = fixture.root.appendingPathComponent("Preserved-" + damage.rawValue)
        if try SignatureSnapshot.entryExists(badDirectory) {
            try FileManager.default.moveItem(at: badDirectory, to: saved)
        }
        let marker = Data("unreadable directory fixture remains unchanged".utf8)
        if damage == .retiredUnreadable {
            try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)
            try marker.write(to: badDirectory.appendingPathComponent("untouched"))
            #expect(chmod(badDirectory.path, 0o111) == 0)
        } else {
            try marker.write(to: badDirectory)
        }
        defer { if damage == .retiredUnreadable { _ = chmod(badDirectory.path, 0o700) } }

        let reopened = fixture.signer()
        let materials = try await reopened.signatureMaterials()
        let diagnostic = try #require(materials.first { $0.url.path == badDirectory.path && $0.kind == .unreadableRecord })
        #expect(!diagnostic.canResume && !diagnostic.canCancel && !diagnostic.canRestore && !diagnostic.canDelete && !diagnostic.canRemoveRecord)
        if damage != .operationsFile {
            #expect(materials.contains { $0.id == "operation:" + pending.id.uuidString && $0.canCancel })
        }
        if damage != .operationsFile && damage != .historyRootFile {
            let cancelled = try await reopened.cancelSignatureMaterial(id: "operation:" + pending.id.uuidString)
            #expect(!cancelled.committed && cancelled.cleanupWarning == nil)
            #expect(try !SignatureSnapshot.entryExists(pending.directoryURL))
            #expect(try operationStore.records().isEmpty)
        }
        if damage != .historyRootFile {
            let originalRow = try #require(materials.first { $0.url.path == original.path })
            let cleanupUnavailable = damage == .operationsFile || damage == .cleanupFile
            #expect(originalRow.canDelete == !cleanupUnavailable)
            #expect(originalRow.canRestore == !cleanupUnavailable)
            if cleanupUnavailable {
                // The original is visible, but an unreadable deletion directory
                // cannot establish that it is independent of an old deletion.
                await #expect(throws: (any Error).self) { try await reopened.deleteSignatureMaterial(id: originalRow.id) }
                await #expect(throws: (any Error).self) {
                    try await reopened.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier,
                                                        historicalMaterialID: originalRow.id)
                }
                #expect(try SignatureSnapshot.fingerprint(of: original) == originalFingerprint)
            } else {
                // This crosses selectedRecordURL and the real material action;
                // merely producing a healthy-looking row is not sufficient.
                let deleted = try await reopened.deleteSignatureMaterial(id: originalRow.id)
                #expect(deleted.committed && deleted.cleanupWarning == nil)
                #expect(try !SignatureSnapshot.entryExists(original))
                #expect(try history.read(bundleIdentifier: fixture.identifier) == nil)
            }
        }
        let markerURL = damage == .retiredUnreadable ? badDirectory.appendingPathComponent("untouched") : badDirectory
        #expect(try Data(contentsOf: markerURL) == marker)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == appFingerprint)
    }

    @Test("A fact FIFO with no writer returns promptly as a diagnostic while normal facts and signing still work")
    func factFIFOIsNonblockingAndIsolated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.signer().sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let store = SignatureFactStore(backupDirectoryURL: fixture.backups)
        let first = try #require(try store.currentFact(at: fixture.app, verifyContent: true))
        let fifo = store.directoryURL.appendingPathComponent(UUID().uuidString + ".plist")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        defer { _ = unlink(fifo.path) }
        let fifoIdentity = try DataPathIdentity.capture(fifo)
        let read = FactInventoryRead()
        // A regressed blocking open cannot hold the entire suite hostage. No
        // writer is ever opened, including the timeout/failure path.
        DispatchQueue.global().async {
            read.complete(Result { try store.inventory() })
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while read.result == nil && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let inventory = try #require(read.result).get()
        #expect(inventory.facts == [first])
        #expect(inventory.unreadableRecords.count == 1)
        #expect(inventory.unreadableRecords.first?.url.path == fifo.path)
        let scanner = AppScanner(backupDirectoryURL: fixture.backups)
        _ = await scanner.checkSigningStatus(bundleURL: fixture.app)
        #expect(try store.currentFact(at: fixture.app, verifyContent: true) == first)
        let second = fixture.root.appendingPathComponent("Second.app")
        try SignatureSnapshot.copy(from: fixture.app, to: second)
        let signed = try await fixture.signer().sign(appURL: second, bundleIdentifier: fixture.identifier)
        #expect(signed.committed && signed.cleanupWarning == nil)
        #expect(try store.currentFact(at: second, verifyContent: true)?.installationID != first.installationID)
        let diagnostic = try #require(try await fixture.signer().signatureMaterials().first { $0.url.path == fifo.path })
        #expect(diagnostic.kind == .unreadableRecord && !diagnostic.canRemoveRecord && !diagnostic.canDelete)
        #expect(try DataPathIdentity.capture(fifo).matchesFilesystemObject(fifoIdentity))
        #expect(try SignatureSnapshot.info(at: fifo).st_mode & S_IFMT == S_IFIFO)
    }

    @MainActor
    @Test("Official repair completes after a local historical original moves and retains only its internal history")
    func unavailableOriginalDoesNotTrapOfficialRepair() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let signer = fixture.signer(officialEvidence: true)
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        let snapshot = try #require(history.snapshotURL(for: backup))
        let recordURL = try history.recordURL(bundleIdentifier: fixture.identifier)
        let recordBytes = try Data(contentsOf: recordURL)
        // The old local path is provably absent; the moved original and its
        // historical record survive while the available-copy row disappears.
        let unavailable = fixture.root.appendingPathComponent("DisconnectedOriginal.app")
        try FileManager.default.moveItem(at: snapshot, to: unavailable)
        let original = try SignatureSnapshot.fingerprint(of: unavailable)
        let identity = try DataPathIdentity.capture(unavailable)
        let result = try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier, originalApplication: official)
        #expect(result.committed && result.cleanupWarning == nil)
        #expect(try SignatureOperationStore(backupDirectoryURL: fixture.backups).records().isEmpty)
        #expect(try Data(contentsOf: recordURL) == recordBytes)
        #expect(try await signer.signatureMaterials().isEmpty)

        #expect(try Data(contentsOf: recordURL) == recordBytes)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
        #expect(try SignatureSnapshot.fingerprint(of: unavailable) == original)
        #expect(try DataPathIdentity.capture(unavailable).matchesFilesystemObject(identity))
    }

    @Test("A previously committed official restore can finish temporary cleanup after its independent history disappears")
    func unavailableHistoryDoesNotRetainCompletedTemporaryOperation() async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let signer = fixture.signer(officialEvidence: true)
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let result = try await fixture.signer(officialEvidence: true, deleteTemporary: { _, _, _, _ in throw Injected.failure })
            .restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier, originalApplication: official)
        #expect(result.committed && result.cleanupWarning != nil)
        let store = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let operation = try #require(try store.records().first)
        #expect(operation.legacyRecordPath != nil)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        let snapshot = try #require(history.snapshotURL(for: backup))
        let unavailable = fixture.root.appendingPathComponent("SavedOriginal.app")
        let recordURL = try history.recordURL(bundleIdentifier: fixture.identifier)
        let recordBytes = try Data(contentsOf: recordURL)
        try FileManager.default.moveItem(at: snapshot, to: unavailable)
        let original = try SignatureSnapshot.fingerprint(of: unavailable)
        let finished = try await signer.resumeSignatureMaterial(id: "operation:" + operation.id.uuidString)
        #expect(finished.committed && finished.cleanupWarning == nil)
        #expect(try store.records().isEmpty)
        #expect(try !SignatureSnapshot.entryExists(operation.directoryURL))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == original)
        #expect(try SignatureSnapshot.fingerprint(of: unavailable) == original)
        #expect(try await signer.signatureMaterials().isEmpty)
        #expect(try Data(contentsOf: recordURL) == recordBytes)
    }

    @Test("Finder-deleted local snapshots disappear from available copies while history remains readable")
    func externallyRemovedSnapshotDoesNotLeaveAnEmptyCopyRow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        let snapshot = try #require(history.snapshotURL(for: backup))
        #expect(try await signer.signatureMaterials().count == 1)
        try FileManager.default.removeItem(at: snapshot)
        #expect(try await signer.signatureMaterials().isEmpty)
        #expect(try history.read(bundleIdentifier: fixture.identifier) == backup)
    }

    @Test("A missing original without a deletion checkpoint keeps its record until explicit metadata-only removal")
    func missingHistoryWithoutDeletionProofIsNotSilentlyCompleted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        try await signer.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        var backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        let snapshot = try #require(history.snapshotURL(for: backup))
        backup.cleanup = .init(parentIdentity: try DataPathIdentity.capture(fixture.backups),
            snapshotIdentity: try DataPathIdentity.capture(snapshot), applicationFingerprint: try SignatureSnapshot.fingerprint(of: fixture.app))
        try history.write(backup)
        let saved = fixture.root.appendingPathComponent("UnavailableOriginal.app")
        try FileManager.default.moveItem(at: snapshot, to: saved)
        await #expect(throws: CodeSigner.SigningError.self) {
            try await signer.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        #expect(try history.read(bundleIdentifier: fixture.identifier) == backup)
        let item = try #require(try await signer.signatureMaterials().first)
        #expect(item.canRemoveRecord && !item.canResume && !item.canDelete)
        #expect(try await signer.removeSignatureMaterialRecord(id: item.id, confirmation: .keepAllFilesAndVolumes) == .recordRemoved)
        #expect(try SignatureSnapshot.fingerprint(of: saved) == SignatureSnapshot.fingerprint(of: fixture.app))
    }

    @Test("Record-only removal rejects stale content and gives no authority through a symlink diagnostic")
    func recordOnlyRemovalIsBoundToSelectedMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.backups, withIntermediateDirectories: true)
        let record = fixture.backups.appendingPathComponent(fixture.identifier + ".plist")
        try Data("invalid old metadata".utf8).write(to: record)
        let signer = fixture.signer()
        let old = try #require(try await signer.signatureMaterials().first)
        #expect(old.canRemoveRecord && !old.canDelete)
        let replacement = Data("different metadata selected by nobody".utf8)
        try replacement.write(to: record, options: .atomic)
        #expect(try await signer.removeSignatureMaterialRecord(id: old.id, confirmation: .keepAllFilesAndVolumes) == .recordUnavailable)
        #expect(try Data(contentsOf: record) == replacement)
        let externalMetadata = fixture.root.appendingPathComponent("UnrelatedMetadata.plist")
        try replacement.write(to: externalMetadata)
        let symlink = fixture.backups.appendingPathComponent("Unreadable.plist")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: externalMetadata)
        let diagnostic = try #require(try await signer.signatureMaterials().first { $0.url.path == symlink.path })
        #expect(!diagnostic.canRemoveRecord && !diagnostic.canDelete)
        await #expect(throws: CodeSigner.SigningError.self) {
            try await signer.removeSignatureMaterialRecord(id: diagnostic.id, confirmation: .keepAllFilesAndVolumes)
        }
        let current = try #require(try await signer.signatureMaterials().first { $0.url.path == record.path })
        #expect(try await signer.removeSignatureMaterialRecord(id: current.id, confirmation: .keepAllFilesAndVolumes) == .recordRemoved)
        #expect(try Data(contentsOf: externalMetadata) == replacement)
        #expect(try SignatureSnapshot.info(at: symlink).st_mode & S_IFMT == S_IFLNK)
    }

    @Test("A damaged fact for one installation cannot block another installation's real move, sign, and restore", arguments: FactDamage.allCases)
    func unrelatedDamagedFactDoesNotBlockOperations(damage: FactDamage) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer()
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let store = SignatureFactStore(backupDirectoryURL: fixture.backups)
        let first = try #require(try store.currentFact(at: fixture.app))
        let firstFingerprint = try SignatureSnapshot.fingerprint(of: fixture.app)
        let second = fixture.root.appendingPathComponent("SecondInstallation.app")
        try SignatureSnapshot.copy(from: fixture.app, to: second)
        let broken = try damageFact(first, in: store, damage: damage)

        let external = fixture.root.appendingPathComponent("External/SecondInstallation.app")
        try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        let transfers = AppTransferStore(directoryURL: fixture.root.appendingPathComponent("Transfers"))
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 }, transferStore: transfers,
            signatureFactStore: store, runningApplications: { [] })
        let moved = try await service.moveAndLink(appToMove: AppItem(name: second.lastPathComponent, path: second, status: AppStatus.local),
            destinationURL: external, isRunning: false, lockExternal: false, progressHandler: nil)
        #expect(moved.isComplete)
        let signed = try await signer.sign(appURL: second, bundleIdentifier: fixture.identifier)
        #expect(signed.committed)
        #expect(signed.cleanupWarning == nil)
        let secondFact = try #require(try store.currentFact(at: external, verifyContent: true))
        #expect(secondFact.installationID != first.installationID)
        let scanner = AppScanner(backupDirectoryURL: fixture.backups)
        let signingStatus = await scanner.checkSigningStatus(bundleURL: external)
        #expect(signingStatus.isResigned)

        let restored = try await service.moveBack(app: AppItem(name: external.lastPathComponent, path: external, status: AppStatus.external),
            localDestinationURL: second, progressHandler: nil)
        #expect(restored.transferResult.isComplete)
        #expect(try store.currentFact(at: second, verifyContent: true)?.installationID == secondFact.installationID)
        #expect(try transfers.records().isEmpty)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == firstFingerprint)
        #expect(try Data(contentsOf: broken.url) == broken.bytes)
        let material = try #require(try await signer.signatureMaterials().first(where: { $0.url.path == broken.url.path }))
        #expect(material.kind == .unreadableRecord)
        #expect(material.appURL == nil)
        #expect(!material.canRestore && !material.canDelete && !material.canResume && !material.canCancel && !material.canRemoveRecord)
    }

    @Test("Damaged target facts cannot borrow another installation's official identity or authorize a repair", arguments: FactDamage.allCases)
    func damagedTargetFactDoesNotAuthorizeOfficialRepair(damage: FactDamage) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        let other = fixture.root.appendingPathComponent("OtherInstallation.app")
        try SignatureSnapshot.copy(from: official, to: other)
        let signer = fixture.signer(officialEvidence: true)
        try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        try await signer.sign(appURL: other, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let store = SignatureFactStore(backupDirectoryURL: fixture.backups)
        let target = try #require(try store.currentFact(at: fixture.app))
        let otherFact = try #require(try store.currentFact(at: other))
        #expect(otherFact.originalDeveloper == Fixture.developer)
        let broken = try damageFact(target, in: store, damage: damage)
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let identity = try DataPathIdentity.capture(fixture.app)

        await #expect(throws: CodeSigner.SigningError.self) {
            try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier, originalApplication: official)
        }
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(identity))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try Data(contentsOf: broken.url) == broken.bytes)
        #expect(try store.currentFact(at: other, verifyContent: true) == otherFact)
        #expect(try SignatureOperationStore(backupDirectoryURL: fixture.backups).records().isEmpty)
        #expect(try await signer.signatureMaterials().contains(where: { $0.url.path == broken.url.path && $0.kind == .unreadableRecord }))
        if damage != .unreadable {
            #expect(throws: CodeSigner.SigningError.self) { try store.currentFact(at: fixture.app) }
        }
        #expect(throws: CodeSigner.SigningError.self) { try store.write(target) }
        #expect(try Data(contentsOf: broken.url) == broken.bytes)
    }

    @Test("Malformed deletion paths and duplicate records fail before any unlink", arguments: [false, true])
    func refusesMalformedDeletionManifest(pathTraversal: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let valid = try SignatureRemovalManifest.capture(at: fixture.app)
        let entry = try #require(valid.entries.first)
        let invalid = SignatureRemovalManifest.Entry(path: pathTraversal ? "../outside" : entry.path,
            inode: entry.inode, kind: entry.kind, mode: entry.mode, flags: entry.flags,
            birthSeconds: entry.birthSeconds, birthNanoseconds: entry.birthNanoseconds, fingerprint: entry.fingerprint)
        let manifest = SignatureRemovalManifest(rootIdentity: valid.rootIdentity, entries: valid.entries + [invalid])
        #expect(throws: CodeSigner.SigningError.self) {
            try manifest.remove(at: fixture.app, allowingPartial: true, unlockCopiedFlags: true)
        }
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
    }

    @Test("Read failure never becomes permission to sign a non-sandboxed application", arguments: [false, true])
    func unreadableEntitlements(allowSandboxed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let signer = CodeSigner(backupDirectoryURL: fixture.backups, inspectSignature: { _ in
            .init(sandboxStatus: .unavailable("injected entitlement read failure"), isAdHoc: false,
                  codeDirectoryHash: nil, developerIdentity: nil, applicationGroups: [], keychainAccessGroups: [])
        }, requireStopped: { _, _ in }, recoveryDependencyCheck: { _ in })
        await #expect(throws: CodeSigner.SigningError.self) {
            try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: allowSandboxed)
        }
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.backups.path))
    }

    @Test("An unverified certificate-signed original cannot be replaced without a recovery backup",
          arguments: OriginalValidationFailure.allCases)
    func refusesUnverifiedOfficialOriginal(failure: OriginalValidationFailure) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let identity = try DataPathIdentity.capture(fixture.app)
        let runner = OriginalValidationRunner(applicationPath: fixture.app.path, failure: failure)
        let signer = CodeSigner(backupDirectoryURL: fixture.backups, runner: runner,
            inspectSignature: { app in
                let actual = try SignatureInspector.inspect(at: app)
                return .init(sandboxStatus: actual.sandboxStatus, isAdHoc: false,
                    codeDirectoryHash: actual.codeDirectoryHash,
                    developerIdentity: failure == .missingIdentity ? nil : Fixture.developer,
                    applicationGroups: actual.applicationGroups, keychainAccessGroups: actual.keychainAccessGroups)
            }, requireStopped: { _, _ in }, recoveryDependencyCheck: { _ in })

        await #expect(throws: CodeSigner.SigningError.self) {
            try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        }

        #expect(await runner.signCount == 0)
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(identity))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try fixture.signingMaterialsAreEmpty())
        #expect(try SignatureHistoryStore(backupDirectoryURL: fixture.backups).records().isEmpty)
        #expect(try SignatureFactStore(backupDirectoryURL: fixture.backups).currentFact(at: fixture.app) == nil)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .contains(where: { $0.hasPrefix(".AppPorts-signature-") }))
    }

    @Test("Consent bound to an old filesystem object cannot sign its identical replacement")
    func refusesStaleConsent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = try DataPathIdentity.capture(fixture.app)
        let fingerprint = try SignatureSnapshot.fingerprint(of: fixture.app)
        let replacement = fixture.root.appendingPathComponent("Replacement.app")
        try SignatureSnapshot.copy(from: fixture.app, to: replacement)
        try SignatureSnapshot.remove(fixture.app)
        try FileManager.default.moveItem(at: replacement, to: fixture.app)
        await #expect(throws: CodeSigner.SigningError.self) {
            try await fixture.signer().sign(appURL: fixture.app, bundleIdentifier: fixture.identifier,
                expectedFingerprint: fingerprint, expectedIdentity: identity)
        }
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == fingerprint)
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("The locked signature inspection cannot reuse an earlier non-sandbox result")
    func checksSandboxAgainAfterAcquiringLocks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inspections = ChangingInspection()
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let signer = CodeSigner(backupDirectoryURL: fixture.backups, inspectSignature: { _ in inspections.next() },
                                requireStopped: { _, _ in }, recoveryDependencyCheck: { _ in })
        do {
            try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
            Issue.record("The newly sandboxed target requires its own confirmation")
        } catch CodeSigner.SigningError.sandboxedApplication {}
        #expect(inspections.count == 2)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("An identical installation swapped during the process check cannot inherit signing consent")
    func refusesReplacementWhileWaitingForExit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replacement = fixture.root.appendingPathComponent("Replacement.app")
        try SignatureSnapshot.copy(from: fixture.app, to: replacement)
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let identity = try DataPathIdentity.capture(fixture.app)
        let signer = CodeSigner(backupDirectoryURL: fixture.backups, requireStopped: { app, _ in
            try SignatureSnapshot.exchange(app, replacement)
        }, recoveryDependencyCheck: { _ in })
        do {
            try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier,
                                  expectedFingerprint: before, expectedIdentity: identity)
            Issue.record("The process-check wait must not replace the consent baseline")
        } catch CodeSigner.SigningError.applicationChanged {}
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try !DataPathIdentity.capture(fixture.app).matchesFilesystemObject(identity))
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("Official recovery refuses app changes during dependency preflight", arguments: [false, true])
    func refusesChangesDuringRecoveryPreflight(identicalReplacement: Bool) async throws {
        let fixture = try Fixture(sandboxed: true)
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official.app")
        try SignatureSnapshot.copy(from: fixture.app, to: official)
        try await fixture.signer(officialEvidence: true).sign(appURL: fixture.app, bundleIdentifier: fixture.identifier, allowSandboxed: true)
        let replacement = fixture.root.appendingPathComponent("Replacement.app")
        try SignatureSnapshot.copy(from: fixture.app, to: replacement)
        let marker = fixture.app.appendingPathComponent("Contents/Resources/new-active-version")
        let signer = fixture.signer(officialEvidence: true, recoveryCheck: { _ in
            if identicalReplacement { try SignatureSnapshot.exchange(fixture.app, replacement) }
            else { try Data("an update arrived during preflight".utf8).write(to: marker) }
        })
        do {
            try await signer.restoreSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier, originalApplication: official)
            Issue.record("Recovery must keep the version and object inspected before its await")
        } catch CodeSigner.SigningError.applicationChanged {}
        #expect(!CodeSigner.isSandboxed(at: fixture.app))
        if !identicalReplacement { #expect(try String(contentsOf: marker, encoding: .utf8) == "an update arrived during preflight") }
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("Unknown bundle-root content is never silently removed to make signing pass")
    func preservesUnknownRootFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unknown = fixture.app.appendingPathComponent(".git/owned-by-user")
        try FileManager.default.createDirectory(at: unknown.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep this exact file".utf8).write(to: unknown)
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        do { try await fixture.signer().sign(appURL: fixture.app, bundleIdentifier: fixture.identifier) }
        catch CodeSigner.SigningError.codesignFailed { #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before) }
        #expect(try String(contentsOf: unknown, encoding: .utf8) == "keep this exact file")
    }

    @Test("A failed writer check withdraws prepared signing before deferred cleanup can commit it", arguments: [false, true])
    func failedAdmissionCannotLaterCommit(firstWithdrawalWriteFails: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let identity = try DataPathIdentity.capture(fixture.app)
        let commands = RecordingRunner()
        let prepared = PreparedOperationObservation()
        let signer = CodeSigner(backupDirectoryURL: fixture.backups, runner: commands,
            requireStopped: { _, _ in }, recoveryDependencyCheck: { _ in },
            checkpoint: { record in
                prepared.capture(record)
                if firstWithdrawalWriteFails, record.phase == .cancelling {
                    try prepared.failFirstWithdrawalWrite()
                }
            }, writerAdmissionCheck: {
                if prepared.record != nil {
                    throw WriterAdmissionError.inspectionFailed(nil, "injected conflicting writer")
                }
            })

        await #expect(throws: WriterAdmissionError.self) {
            try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        }
        let store = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let pending = try #require(try store.records().first)
        #expect(pending.phase == .cancelling)
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(identity))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)

        let warnings = await fixture.signer(runner: commands).performAutomaticMaintenance()
        #expect(warnings.isEmpty)
        #expect(try store.records().isEmpty)
        #expect(try !SignatureSnapshot.entryExists(pending.directoryURL))
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(identity))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try SignatureFactStore(backupDirectoryURL: fixture.backups).currentFact(at: fixture.app) == nil)
        #expect(await commands.signCount == 1)
    }

    @Test("Resuming a prepared signature returns its own commit without a second signing attempt",
          arguments: ["no-consent", "consent", "late-cancellation"])
    func resumedPreparationDoesNotStartAnotherSignature(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let identity = try DataPathIdentity.capture(fixture.app)
        let commands = RecordingRunner()
        let prepared = PreparedOperationObservation()
        let interrupted = fixture.signer(runner: commands, checkpoint: { record in
            prepared.capture(record)
            if record.phase == .prepared { throw Injected.failure }
        }, deleteTemporary: { _, _, _, _ in throw Injected.failure })
        await #expect(throws: Injected.self) {
            try await interrupted.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        }
        let record = try #require(prepared.record)
        let store = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        // Recreate the durable checkpoint of a process that exits immediately
        // after preparation, before its catch/cleanup path can run.
        try store.write(record)

        let withConsent = mode != "no-consent"
        let lateCancellation = mode == "late-cancellation"
        let reopened = fixture.signer(runner: commands, checkpoint: { record in
            if lateCancellation, record.phase == .committed {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })
        let resumed = Task {
            try await reopened.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier,
                expectedFingerprint: withConsent ? before : nil, expectedIdentity: withConsent ? identity : nil)
        }
        let result = try await resumed.value

        #expect(result.committed)
        #expect((result.cleanupWarning != nil) == lateCancellation)
        #expect(result.operationID == record.id)
        #expect(await commands.signCount == 1)
        if lateCancellation {
            let warnings = await fixture.signer(runner: commands).performAutomaticMaintenance()
            #expect(warnings.isEmpty)
        }
        #expect(try store.records().isEmpty)
        let candidateIdentity = try #require(record.candidateIdentity)
        #expect(try DataPathIdentity.capture(fixture.app).matchesFilesystemObject(candidateIdentity))
        let fact = try #require(try SignatureFactStore(backupDirectoryURL: fixture.backups).currentFact(at: fixture.app, verifyContent: true))
        #expect(fact.lastOperationID == record.id)
    }

    @Test("A lost post-exchange checkpoint resumes cleanup without re-signing, including later writes", arguments: [false, true])
    func resumesExchangedApplication(laterWrite: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let commands = RecordingRunner()
        let failing = fixture.signer(runner: commands, checkpoint: { record in
            if record.phase == .committed { throw Injected.failure }
        })
        let result = try await failing.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(result.committed)
        #expect(result.cleanupWarning != nil)
        let reopened = fixture.signer(runner: commands)
        let items = try await reopened.signatureMaterials()
        let item = try #require(items.first(where: { $0.kind == .temporaryOperation }))
        #expect(item.canResume)
        let count = await commands.signCount
        let activeWrite = fixture.app.appendingPathComponent("Contents/Resources/after-commit")
        if laterWrite { try Data("newly active content".utf8).write(to: activeWrite) }
        let completed = try await reopened.resumeSignatureMaterial(id: item.id)
        #expect(completed.committed)
        #expect(completed.cleanupWarning == nil)
        #expect(await commands.signCount == count)
        #expect(try await reopened.signatureMaterials().isEmpty)
        if laterWrite { #expect(try String(contentsOf: activeWrite, encoding: .utf8) == "newly active content") }
    }

    @Test("A Trash request for a temporary operation cannot silently delete retained material", arguments: [false, true])
    func temporaryOperationTrashRequestPreservesMaterials(committed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signer = fixture.signer(checkpoint: { record in
            if record.phase == (committed ? .committed : .prepared) { throw Injected.failure }
        }, deleteTemporary: { _, _, _, _ in throw Injected.failure })
        if committed {
            let signed = try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
            #expect(signed.committed && signed.cleanupWarning != nil)
        } else {
            await #expect(throws: Injected.self) { try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier) }
        }
        let store = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let record = try #require(try store.records().first)
        let retained = try SignatureSnapshot.fingerprint(of: record.candidateURL)
        let current = try SignatureSnapshot.fingerprint(of: fixture.app)
        let material = try #require(try await signer.signatureMaterials().first)
        #expect(!material.canDelete)
        do {
            try await fixture.signer().deleteSignatureMaterial(id: "operation:" + record.id.uuidString, moveToTrash: true)
            Issue.record("Temporary material cannot accept a Trash request")
        } catch CodeSigner.SigningError.temporaryMaterialCannotBeTrashed {}
        #expect(try SignatureSnapshot.fingerprint(of: record.candidateURL) == retained)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == current)
        #expect(try store.records().first == record)
        let completed = try await fixture.signer().resumeSignatureMaterial(id: material.id)
        #expect(completed.committed == committed && completed.cleanupWarning == nil)
        #expect(try store.records().isEmpty)
    }

    @Test("A persisted historical deletion keeps its original disposition and has one continuable row", arguments: [false, true])
    func existingDeletionReceiptCannotSilentlyChangeDisposition(moveToTrash: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.backups, withIntermediateDirectories: true)
        let original = fixture.backups.appendingPathComponent("original-orphan.app")
        try SignatureSnapshot.copy(from: fixture.app, to: original)
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let previousMaterialID = try history.materialID(for: original)
        let deletion = SignatureMaterialDeletion(id: UUID(), targetPath: original.path,
            parentIdentity: try DataPathIdentity.capture(fixture.backups), targetIdentity: try DataPathIdentity.capture(original),
            manifest: try SignatureRemovalManifest.capture(at: original), recordPath: nil, recordDigest: nil, moveToTrash: moveToTrash)
        try history.writeDeletion(deletion)
        let id = "history-cleanup:" + deletion.id.uuidString
        let materials = try await fixture.signer().signatureMaterials().filter { $0.url.path == original.path }
        let material = try #require(materials.first)
        #expect(materials.count == 1 && material.id == id)
        #expect(material.canResume && !material.canDelete)
        let before = try SignatureSnapshot.fingerprint(of: original)
        do {
            try await fixture.signer().deleteSignatureMaterial(id: id, moveToTrash: !moveToTrash)
            Issue.record("A persisted deletion cannot accept a different disposition")
        } catch CodeSigner.SigningError.deletionDispositionChanged {}
        // A second window may still hold the menu from before the receipt was
        // persisted. That obsolete material ID must not start another deletion.
        await #expect(throws: CodeSigner.SigningError.self) {
            try await fixture.signer().deleteSignatureMaterial(id: previousMaterialID, moveToTrash: !moveToTrash)
        }
        #expect(try SignatureSnapshot.fingerprint(of: original) == before)
        #expect(try history.deletions() == [deletion])
        let trash = fixture.root.appendingPathComponent("FixtureTrash.app")
        let reopened = CodeSigner(backupDirectoryURL: fixture.backups, allowAdministratorPrompt: false,
            trashHistoricalMaterial: { try FileManager.default.moveItem(at: $0, to: trash) },
            requireStopped: { _, _ in }, recoveryDependencyCheck: { _ in })
        let result = try await reopened.resumeSignatureMaterial(id: id)
        #expect(result.committed)
        #expect((result.cleanupWarning != nil) == moveToTrash)
        #expect(try history.deletions().isEmpty)
        #expect(try !SignatureSnapshot.entryExists(original))
        #expect(try SignatureSnapshot.entryExists(trash) == moveToTrash)
        if moveToTrash { #expect(try SignatureSnapshot.fingerprint(of: trash) == before) }
        #expect(try await reopened.signatureMaterials().isEmpty)
    }

    @Test("A redundant historical backup already being cleaned cannot start a separate disposal operation", arguments: [false, true])
    func automaticBackupCleanupOnlyOffersContinuation(moveToTrash: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let failing = CodeSigner(backupDirectoryURL: fixture.backups, allowAdministratorPrompt: false,
            trashBackupSnapshot: { _ in throw Injected.failure }, requireStopped: { _, _ in }, recoveryDependencyCheck: { _ in })
        try await failing.backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        await #expect(throws: Injected.self) {
            try await failing.discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        let recordURL = try history.recordURL(bundleIdentifier: fixture.identifier)
        let recordData = try Data(contentsOf: recordURL)
        let material = try #require(try await failing.signatureMaterials().first)
        #expect(material.canResume && !material.canDelete && !material.canRestore)
        let before = try SignatureSnapshot.fingerprint(of: material.url)
        await #expect(throws: CodeSigner.SigningError.self) {
            try await fixture.signer().deleteSignatureMaterial(id: material.id, moveToTrash: moveToTrash)
        }
        #expect(try Data(contentsOf: recordURL) == recordData)
        #expect(try SignatureSnapshot.fingerprint(of: material.url) == before)
        #expect(try history.deletions().isEmpty)
        let result = try await fixture.signer().resumeSignatureMaterial(id: material.id)
        #expect(result.committed && result.cleanupWarning == nil)
        #expect(try !SignatureSnapshot.entryExists(material.url))
        #expect(try !SignatureSnapshot.entryExists(recordURL))
        #expect(try await fixture.signer().signatureMaterials().isEmpty)
    }

    @Test("A partial old-copy deletion retries from its checkpoint and preserves a newly inserted file", arguments: [false, true])
    func partialCleanupIsRecoverable(insertConflict: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let failing = fixture.signer(deleteTemporary: { url, _, _, _ in
            try FileManager.default.removeItem(at: url.appendingPathComponent("Contents/Resources/payload"))
            throw Injected.failure
        })
        let result = try await failing.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        #expect(result.committed)
        #expect(result.cleanupWarning != nil)
        let reopened = fixture.signer()
        let item = try #require(try await reopened.signatureMaterials().first(where: { $0.kind == .temporaryOperation }))
        let foreign = item.url.appendingPathComponent(fixture.app.lastPathComponent + "/Contents/Resources/foreign")
        if insertConflict { try Data("do not discard".utf8).write(to: foreign) }
        let retry = try await reopened.resumeSignatureMaterial(id: item.id)
        if insertConflict {
            #expect(retry.cleanupWarning != nil)
            #expect(try String(contentsOf: foreign, encoding: .utf8) == "do not discard")
            try FileManager.default.removeItem(at: foreign)
            let finished = try await reopened.resumeSignatureMaterial(id: item.id)
            #expect(finished.cleanupWarning == nil)
        } else { #expect(retry.cleanupWarning == nil) }
        #expect(try await reopened.signatureMaterials().isEmpty)
    }

    @Test("A sync failure and interrupted cancellation retain the partial-deletion checkpoint")
    func resumesCancelledPreparation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let failing = fixture.signer(synchronizeTree: { _ in throw Injected.failure }, deleteTemporary: { url, _, _, _ in
            try FileManager.default.removeItem(at: url.appendingPathComponent("Contents/Resources/payload"))
            throw Injected.failure
        })
        await #expect(throws: Injected.self) {
            try await failing.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        }
        let store = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let record = try #require(try store.records().first)
        #expect(record.phase == .cancelling)
        #expect(record.cleanupStarted)
        #expect(record.cleanupManifest != nil)
        let result = try await fixture.signer().cancelSignatureMaterial(id: "operation:" + record.id.uuidString)
        #expect(!result.committed)
        #expect(result.cleanupWarning == nil)
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try store.records().isEmpty)
    }

    @Test("Explicit historical deletion retains its receipt after a missing-target sync failure and rejects parent replacement",
          arguments: [false, true])
    func historicalDeletionRetriesMissingParentBarrier(replaceParent: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        try await fixture.signer().backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let original = try #require(try history.materials().first { $0.kind == .historicalSnapshot })
        let appBefore = try SignatureSnapshot.fingerprint(of: fixture.app)
        let fault = DirectoryBarrierFault(parent: fixture.backups)
        await #expect(throws: POSIXError(.EIO)) {
            try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).deleteSignatureMaterial(id: original.id)
        }
        #expect(try !SignatureSnapshot.entryExists(original.url))
        let deletion = try #require(try history.deletions().first)
        #expect(deletion.started)
        let receipt = history.cleanupDirectoryURL.appendingPathComponent(deletion.id.uuidString + ".plist")
        let retainedReceipt = try Data(contentsOf: receipt)
        let recordURL = try history.recordURL(bundleIdentifier: fixture.identifier)
        let retainedRecord = try Data(contentsOf: recordURL)
        let actionID = "history-cleanup:" + deletion.id.uuidString
        let pauses = DiskEjectionPauseStore(directory: fixture.root)
        let pause = try pauses.pause(.init(deviceIdentifier: "fixture", connectionID: "fixture:1", displayName: "Fixture",
            volumeUUIDs: [deletion.parentIdentity.volumeUUID ?? "PAUSED-FIXTURE"], containerUUIDs: [], mountPaths: [fixture.backups.path]))
        _ = await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).performAutomaticMaintenance()
        #expect(fault.calls == 1)
        #expect(try Data(contentsOf: receipt) == retainedReceipt)
        #expect(try Data(contentsOf: recordURL) == retainedRecord)
        _ = try pauses.reconcile(.init(disks: [.init(deviceIdentifier: "fixture", connectionID: "fixture:2",
                displayName: pause.displayName, volumeUUIDs: pause.volumeUUIDs, containerUUIDs: pause.containerUUIDs, mountPaths: pause.mountPaths)]))
        // A newly constructed service sees no target. EIO still prevents it
        // from deleting the record or its independent cleanup receipt.
        await #expect(throws: POSIXError(.EIO)) {
            try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).resumeSignatureMaterial(id: actionID)
        }
        #expect(fault.calls == 2)
        #expect(try Data(contentsOf: receipt) == retainedReceipt)
        #expect(try Data(contentsOf: recordURL) == retainedRecord)
        if replaceParent {
            let saved = fixture.root.appendingPathComponent("OriginalMaterialParent")
            fault.replaceParentOnNextSync(savingAt: saved)
            await #expect(throws: CodeSigner.SigningError.self) {
                try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).resumeSignatureMaterial(id: actionID)
            }
            #expect(try Data(contentsOf: receipt) == retainedReceipt)
            #expect(try Data(contentsOf: saved.appendingPathComponent(recordURL.lastPathComponent)) == retainedRecord)
            try restoreReplacedParent(fixture.backups, savedAt: saved)
        }
        fault.allowSynchronization()
        let finished = try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).resumeSignatureMaterial(id: actionID)
        #expect(finished.committed && finished.cleanupWarning == nil)
        #expect(try history.deletions().isEmpty)
        #expect(try !SignatureSnapshot.entryExists(recordURL))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == appBefore)
        #expect(try await fixture.signer().signatureMaterials().isEmpty)
    }

    @Test("A separate retired metadata parent also retains its deletion receipt until cold synchronization succeeds")
    func historicalDeletionRetriesMissingRecordParentBarrier() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        try await fixture.signer().backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let retired = fixture.backups.appendingPathComponent("retired")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: false)
        let oldRecord = try history.recordURL(bundleIdentifier: fixture.identifier)
        let recordURL = retired.appendingPathComponent(oldRecord.lastPathComponent)
        try FileManager.default.moveItem(at: oldRecord, to: recordURL)
        let material = try #require(try history.materials().first { $0.kind == .retiredSnapshot })
        let currentBefore = try SignatureSnapshot.fingerprint(of: fixture.app)
        let parentIdentity = try DataPathIdentity.capture(retired)
        let fault = DirectoryBarrierFault(parent: retired)
        await #expect(throws: POSIXError(.EIO)) {
            try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).deleteSignatureMaterial(id: material.id)
        }
        #expect(try !SignatureSnapshot.entryExists(material.url) && !SignatureSnapshot.entryExists(recordURL))
        let pending = try #require(try history.deletions().first)
        #expect(pending.recordParentIdentity?.matchesFilesystemObject(parentIdentity) == true)
        let receipt = history.cleanupDirectoryURL.appendingPathComponent(pending.id.uuidString + ".plist")
        let retained = try Data(contentsOf: receipt)
        let id = "history-cleanup:" + pending.id.uuidString
        await #expect(throws: POSIXError(.EIO)) {
            try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).resumeSignatureMaterial(id: id)
        }
        #expect(fault.calls == 2)
        #expect(try Data(contentsOf: receipt) == retained)
        let saved = fixture.root.appendingPathComponent("OriginalRetiredParent")
        fault.replaceParentOnNextSync(savingAt: saved)
        await #expect(throws: CodeSigner.SigningError.self) {
            try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).resumeSignatureMaterial(id: id)
        }
        #expect(try Data(contentsOf: receipt) == retained)
        try restoreReplacedParent(retired, savedAt: saved)
        fault.allowSynchronization()
        let finished = try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).resumeSignatureMaterial(id: id)
        #expect(finished.committed && finished.cleanupWarning == nil)
        #expect(try history.deletions().isEmpty)
        #expect(try !SignatureSnapshot.entryExists(material.url) && !SignatureSnapshot.entryExists(recordURL))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == currentBefore)
    }

    @Test("Automatic historical cleanup synchronizes a missing original before removing its sole record",
          arguments: [false, true])
    func historicalBackupRetriesMissingParentBarrier(replaceParent: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = SignatureHistoryStore(backupDirectoryURL: fixture.backups)
        try await fixture.signer().backupOriginalSignature(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        let backup = try #require(try history.read(bundleIdentifier: fixture.identifier))
        let original = try #require(history.snapshotURL(for: backup))
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let fault = DirectoryBarrierFault(parent: fixture.backups)
        await #expect(throws: POSIXError(.EIO)) {
            try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) })
                .discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        #expect(try !SignatureSnapshot.entryExists(original))
        let recordURL = try history.recordURL(bundleIdentifier: fixture.identifier)
        let record = try Data(contentsOf: recordURL)
        let pending = try #require(try history.read(bundleIdentifier: fixture.identifier))
        #expect(pending.cleanup?.actualDeletionStarted == true && pending.cleanup?.removalManifest != nil)
        await #expect(throws: POSIXError(.EIO)) {
            try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) })
                .discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
        }
        #expect(fault.calls == 2)
        #expect(try Data(contentsOf: recordURL) == record)
        if replaceParent {
            let saved = fixture.root.appendingPathComponent("OriginalBackupParent")
            fault.replaceParentOnNextSync(savingAt: saved)
            await #expect(throws: CodeSigner.SigningError.self) {
                try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) })
                    .discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier)
            }
            #expect(try Data(contentsOf: saved.appendingPathComponent(recordURL.lastPathComponent)) == record)
            try restoreReplacedParent(fixture.backups, savedAt: saved)
        }
        fault.allowSynchronization()
        #expect(try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) })
            .discardUnusedOriginalBackup(bundleIdentifier: fixture.identifier))
        #expect(try !SignatureSnapshot.entryExists(recordURL))
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try await fixture.signer().signatureMaterials().isEmpty)
    }

    @Test("Cancellation retries a removed candidate directory's parent barrier without deleting or signing again",
          arguments: [false, true])
    func cancelledPreparationRetriesRemovedDirectoryBarrier(replaceParent: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let parent = fixture.root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let app = parent.appendingPathComponent("Installed.app")
        try SignatureSnapshot.copy(from: fixture.app, to: app)
        let before = try SignatureSnapshot.fingerprint(of: app)
        let originalIdentity = try DataPathIdentity.capture(app)
        let commands = RecordingRunner()
        await #expect(throws: CancellationError.self) {
            try await fixture.signer(runner: commands, synchronizeTree: { _ in throw CancellationError() })
                .sign(appURL: app, bundleIdentifier: fixture.identifier)
        }
        let store = SignatureOperationStore(backupDirectoryURL: fixture.backups)
        let pending = try #require(try store.records().first)
        let actionID = "operation:" + pending.id.uuidString
        let fault = DirectoryBarrierFault(parent: parent)
        await #expect(throws: POSIXError(.EIO)) {
            try await fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }).cancelSignatureMaterial(id: actionID)
        }
        #expect(try !SignatureSnapshot.entryExists(pending.directoryURL))
        #expect(try store.record(id: pending.id).cleanupStarted)
        let recordURL = store.directoryURL.appendingPathComponent(pending.id.uuidString + ".plist")
        let retainedRecord = try Data(contentsOf: recordURL)
        let cold = fixture.signer(synchronizeDirectory: { try fault.synchronize($0) }, deleteTemporary: { _, _, _, _ in
            Issue.record("Cold cancellation must only finish synchronization after its directory has already been removed")
            throw Injected.failure
        })
        await #expect(throws: POSIXError(.EIO)) { try await cold.cancelSignatureMaterial(id: actionID) }
        #expect(fault.calls == 2)
        #expect(try Data(contentsOf: recordURL) == retainedRecord)
        if replaceParent {
            let saved = fixture.root.appendingPathComponent("OriginalApplicationParent")
            fault.replaceParentOnNextSync(savingAt: saved)
            await #expect(throws: CodeSigner.SigningError.self) { try await cold.cancelSignatureMaterial(id: actionID) }
            #expect(try Data(contentsOf: recordURL) == retainedRecord)
            try restoreReplacedParent(parent, savedAt: saved)
        }
        fault.allowSynchronization()
        let finished = try await cold.cancelSignatureMaterial(id: actionID)
        #expect(!finished.committed && finished.cleanupWarning == nil)
        #expect(try store.records().isEmpty)
        #expect(await commands.signCount == 1)
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
        #expect(try DataPathIdentity.capture(app).matchesFilesystemObject(originalIdentity))
    }

    @Test("Cancellation terminates a pending command before the original can be exchanged")
    func commandCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        let runner = WaitingRunner()
        let signer = fixture.signer(runner: runner)
        let task = Task { try await signer.sign(appURL: fixture.app, bundleIdentifier: fixture.identifier) }
        await runner.waitUntilStarted()
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        let material = try #require(try await signer.signatureMaterials().first)
        #expect(material.canCancel)
        let cleanup = try await fixture.signer().cancelSignatureMaterial(id: material.id)
        #expect(!cleanup.committed)
        #expect(cleanup.cleanupWarning == nil)
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("A command timeout preserves the source and cleans its sole temporary candidate")
    func commandTimeout() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try SignatureSnapshot.fingerprint(of: fixture.app)
        await #expect(throws: CodeSigner.SigningError.self) {
            try await fixture.signer(runner: TimeoutRunner()).sign(appURL: fixture.app, bundleIdentifier: fixture.identifier)
        }
        #expect(try SignatureSnapshot.fingerprint(of: fixture.app) == before)
        #expect(try fixture.signingMaterialsAreEmpty())
    }

    @Test("No signing fact means malformed unrelated apps do not block position-only migration")
    func missingFactsDoNotInspectMalformedApps() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not a plist".utf8).write(to: fixture.app.appendingPathComponent("Contents/Info.plist"))
        #expect(try SignatureFactStore(backupDirectoryURL: fixture.backups).captureRelocation(from: fixture.app) == nil)
    }

    enum OperationDamage: String, CaseIterable, Sendable { case unreadable, unsupportedVersion, invalidPhase }
    enum FactDamage: String, CaseIterable, Sendable { case unreadable, unsupportedVersion, invalidDeveloper }
    enum SignatureDirectoryDamage: String, CaseIterable, Sendable {
        case retiredFile, retiredUnreadable, factsFile, operationsFile, cleanupFile, historyRootFile
    }

    private func damageOperation(_ record: SignatureOperationRecord, in store: SignatureOperationStore,
                                 damage: OperationDamage) throws -> (url: URL, bytes: Data) {
        let url = store.directoryURL.appendingPathComponent(record.id.uuidString + ".plist")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes: Data
        switch damage {
        case .unreadable:
            bytes = Data("unreadable signature operation".utf8)
        case .unsupportedVersion:
            var future = record
            future.schemaVersion = 99
            bytes = try encoder.encode(future)
        case .invalidPhase:
            var plist = try #require(try PropertyListSerialization.propertyList(from: encoder.encode(record), format: nil) as? [String: Any])
            plist["phase"] = "unknown-operation-phase"
            bytes = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        }
        try bytes.write(to: url)
        return (url, bytes)
    }

    private func deletionFixture(for target: URL) throws -> SignatureMaterialDeletion {
        .init(id: UUID(), targetPath: target.path, parentIdentity: try DataPathIdentity.capture(target.deletingLastPathComponent()),
            targetIdentity: try DataPathIdentity.capture(target), manifest: try SignatureRemovalManifest.capture(at: target),
            recordPath: nil, recordDigest: nil, moveToTrash: false)
    }

    private func restoreReplacedParent(_ parent: URL, savedAt original: URL) throws {
        let marker = parent.appendingPathComponent("replacement-marker")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "independent replacement directory")
        // Keep the replacement and its contents intact while restoring only
        // this test's original directory identity for the final cold retry.
        try FileManager.default.moveItem(at: parent, to: original.appendingPathExtension("replacement"))
        try FileManager.default.moveItem(at: original, to: parent)
    }

    private func damageFact(_ fact: SignatureFact, in store: SignatureFactStore, damage: FactDamage) throws -> (url: URL, bytes: Data) {
        let url = store.directoryURL.appendingPathComponent(fact.installationID.uuidString + ".plist")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes: Data
        switch damage {
        case .unreadable:
            bytes = Data("unreadable signature fact".utf8)
        case .unsupportedVersion:
            var future = fact
            future.schemaVersion = 99
            bytes = try encoder.encode(future)
        case .invalidDeveloper:
            var plist = try #require(try PropertyListSerialization.propertyList(from: encoder.encode(fact), format: nil) as? [String: Any])
            plist["originalDeveloper"] = "corrupt developer identity"
            bytes = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        }
        try bytes.write(to: url)
        return (url, bytes)
    }

    private enum Injected: Error { case failure }
    private final class PreparedOperationObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SignatureOperationRecord?
        private var withdrawalWrites = 0
        var record: SignatureOperationRecord? { lock.lock(); defer { lock.unlock() }; return value }
        func capture(_ record: SignatureOperationRecord) {
            guard record.phase == .prepared else { return }
            lock.lock(); defer { lock.unlock() }
            value = record
        }
        func failFirstWithdrawalWrite() throws {
            lock.lock(); defer { lock.unlock() }
            withdrawalWrites += 1
            if withdrawalWrites == 1 { throw Injected.failure }
        }
    }
    private final class DirectoryBarrierFault: @unchecked Sendable {
        private enum Action { case fail, synchronize, replace(URL) }
        private let lock = NSLock()
        private let parent: URL
        private var action = Action.fail
        private var callCount = 0
        init(parent: URL) { self.parent = parent.standardizedFileURL }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
        func allowSynchronization() { lock.lock(); defer { lock.unlock() }; action = .synchronize }
        func replaceParentOnNextSync(savingAt original: URL) { lock.lock(); defer { lock.unlock() }; action = .replace(original) }
        func synchronize(_ url: URL) throws {
            guard url.standardizedFileURL == parent else { try DurableFileIO.syncDirectory(at: url); return }
            lock.lock()
            callCount += 1
            let selected = action
            if case .replace = action { action = .synchronize }
            lock.unlock()
            switch selected {
            case .fail: throw POSIXError(.EIO)
            case .synchronize: try DurableFileIO.syncDirectory(at: url)
            case .replace(let original):
                try FileManager.default.moveItem(at: parent, to: original)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                try Data("independent replacement directory".utf8).write(to: parent.appendingPathComponent("replacement-marker"))
                try DurableFileIO.syncDirectory(at: parent)
            }
        }
    }
    private final class FactInventoryRead: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<SignatureFactStore.Inventory, Error>?
        var result: Result<SignatureFactStore.Inventory, Error>? { lock.lock(); defer { lock.unlock() }; return value }
        func complete(_ result: Result<SignatureFactStore.Inventory, Error>) {
            lock.lock(); defer { lock.unlock() }
            value = result
        }
    }
    private final class CapacitySequence: @unchecked Sendable {
        private let lock = NSLock()
        private let afterCopy: Int64
        private var calls = 0
        init(afterCopy: Int64) { self.afterCopy = afterCopy }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func next() -> Int64 {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls == 1 ? Int64.max : afterCopy
        }
    }
    private final class CopyCancellationObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [(path: String, copied: Int64)] = []
        var first: (path: String, copied: Int64)? { lock.lock(); defer { lock.unlock() }; return observations.first }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return observations.count }
        func record(path: String, copied: Int64) {
            lock.lock(); defer { lock.unlock() }
            observations.append((path: path, copied: copied))
        }
    }
    private final class ChangingInspection: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func next() -> SignatureInspection {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return .init(sandboxStatus: calls == 1 ? .notSandboxed : .sandboxed, isAdHoc: false,
                         codeDirectoryHash: nil, developerIdentity: nil, applicationGroups: [], keychainAccessGroups: [])
        }
    }
    private actor Checks {
        var values: [SignatureRecoveryRequirements] = []
        func append(_ value: SignatureRecoveryRequirements) { values.append(value) }
    }
    private actor RecordingRunner: ShellCommandRunning {
        var signCount = 0
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            if arguments.contains("--sign") { signCount += 1 }
            return try await ProcessCommandRunner().run(executable: executable, arguments: arguments, timeout: timeout)
        }
    }
    enum OriginalValidationFailure: CaseIterable, Sendable {
        case invalidSignature, timedOut, missingIdentity
    }
    private actor OriginalValidationRunner: ShellCommandRunning {
        let applicationPath: String
        let failure: OriginalValidationFailure
        var signCount = 0
        init(applicationPath: String, failure: OriginalValidationFailure) {
            self.applicationPath = applicationPath
            self.failure = failure
        }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            if arguments.contains("--sign") { signCount += 1 }
            if arguments.contains("--verify"), arguments.last == applicationPath, failure != .missingIdentity {
                return .init(status: 1, standardOutput: Data(),
                    standardError: Data("injected original verification failure".utf8), timedOut: failure == .timedOut)
            }
            return try await ProcessCommandRunner().run(executable: executable, arguments: arguments, timeout: timeout)
        }
    }
    private actor WaitingRunner: ShellCommandRunning {
        var started = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw Injected.failure
        }
    }
    private struct TimeoutRunner: ShellCommandRunning {
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            .init(status: -1, standardOutput: Data(), standardError: Data("timeout".utf8), timedOut: true)
        }
    }
    private struct Fixture: Sendable {
        static let developer = OriginalDeveloperIdentity(authority: "Synthetic AppPorts Test Developer",
            teamIdentifier: "APPPORTS00", designatedRequirement: "identifier com.appports.tests.operations",
            certificateSHA256: String(repeating: "a", count: 64))
        let root: URL
        let identifier = "com.appports.tests.operations"
        var app: URL { root.appendingPathComponent("Installed.app") }
        var backups: URL { root.appendingPathComponent("SignatureBackups") }
        init(sandboxed: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsSignatureOperation-" + UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
            try FileManager.default.copyItem(at: #require(Bundle.main.url(forResource: "StubLauncherBinary", withExtension: nil)), to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
                "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Data("original application payload".utf8).write(to: app.appendingPathComponent("Contents/Resources/payload"))
            if sandboxed {
                let entitlements = root.appendingPathComponent("entitlements.plist")
                try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.app-sandbox": true,
                    "com.apple.security.application-groups": ["group.not-related-to-app-name.shared"]] as [String: Any], format: .xml, options: 0).write(to: entitlements)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["--force", "--sign", "-", "--entitlements", entitlements.path, app.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                try #require(process.terminationStatus == 0)
            }
        }
        func signer(officialEvidence: Bool = false, captureOfficialOriginal: Bool = false, officialDeveloper: OriginalDeveloperIdentity? = nil,
                    copy: @escaping @Sendable (URL, URL) throws -> Void = { try SignatureSnapshot.copyContents(from: $0, into: $1) },
                    runner: any ShellCommandRunning = ProcessCommandRunner(),
                    checkpoint: @escaping @Sendable (SignatureOperationRecord) throws -> Void = { _ in },
                    synchronizeTree: @escaping @Sendable (URL) throws -> Void = { try DurableFileIO.syncTree(at: $0) },
                    synchronizeDirectory: @escaping @Sendable (URL) throws -> Void = { try DurableFileIO.syncDirectory(at: $0) },
                    deleteTemporary: @escaping @Sendable (URL, SignatureRemovalManifest, Bool, Bool) throws -> Void = { try $1.remove(at: $0, allowingPartial: $2, unlockCopiedFlags: $3) },
                    recoveryCheck: @escaping @Sendable (SignatureRecoveryRequirements) async throws -> Void = { _ in },
                    availableTemporaryCapacity: @escaping @Sendable (URL) throws -> Int64 = { try CodeSigner.availableTemporarySpace(at: $0) },
                    applicationTransferStore: AppTransferStore? = nil,
                    dataTransferStore: ContainerMountStore? = nil,
                    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                    backupDestination: (@Sendable (URL, Int64) throws -> SignatureDirectoryLocation)? = nil,
                    preferMovingOriginal: Bool = true) -> CodeSigner {
            CodeSigner(backupDirectoryURL: backups, allowAdministratorPrompt: false,
                copyApplication: copy, availableTemporaryCapacity: availableTemporaryCapacity, runner: runner,
                inspectSignature: { app in
                    let actual = try SignatureInspector.inspect(at: app)
                    guard officialEvidence, actual.sandboxStatus == .sandboxed else { return actual }
                    // Simulate a verified certificate identity at the reader seam;
                    // application copies/signatures themselves are real synthetic code.
                    return .init(sandboxStatus: actual.sandboxStatus, isAdHoc: captureOfficialOriginal ? false : actual.isAdHoc,
                        codeDirectoryHash: actual.codeDirectoryHash, developerIdentity: officialDeveloper ?? Self.developer,
                        applicationGroups: actual.applicationGroups, keychainAccessGroups: actual.keychainAccessGroups)
                }, requireDeveloperIdentity: { expected, original in
                    guard officialEvidence, expected == (officialDeveloper ?? Self.developer), CodeSigner.isSandboxed(at: original) else { throw Injected.failure }
                }, requireStopped: { _, _ in }, recoveryDependencyCheck: recoveryCheck,
                checkpoint: checkpoint, synchronizeTree: synchronizeTree, synchronizeDirectory: synchronizeDirectory,
                deleteTemporaryTree: deleteTemporary,
                applicationTransferStore: applicationTransferStore, dataTransferStore: dataTransferStore, homeDirectory: homeDirectory,
                backupDestination: backupDestination, preferMovingOriginal: preferMovingOriginal)
        }
        func signingMaterialsAreEmpty() throws -> Bool { try SignatureOperationStore(backupDirectoryURL: backups).records().isEmpty }
        func remove() { try? SignatureSnapshot.remove(root) }
    }
}
