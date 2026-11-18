import Darwin
import XCTest
@testable import AppPorts

final class AppTransferTransactionTests: XCTestCase {
    private struct Interrupted: Error {}
    private struct Workspace {
        let root: URL
        let local: URL
        let external: URL
        let store: AppTransferStore
        let facts: SignatureFactStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsTransferTests-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            local = root.appendingPathComponent("Applications")
            external = root.appendingPathComponent("External")
            store = AppTransferStore(directoryURL: root.appendingPathComponent("Journal"))
            facts = SignatureFactStore(backupDirectoryURL: root.appendingPathComponent("SignatureBackups"))
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        }

        func service(hook: ((AppTransferHooks.Checkpoint, AppTransferRecord) throws -> Void)? = nil,
                     dock: @escaping AppMigrationService.DockShortcutUpdater = { _, _ in 0 },
                     running: @escaping () -> [AppRunningState.RunningApplication] = { [] },
                     storeOverride: AppTransferStore? = nil,
                     synchronizeCleanupParent: @escaping (URL) throws -> Void = { try DurableFileIO.syncDirectory(at: $0) },
                     synchronizeStagingParent: @escaping (URL) throws -> Void = { try DurableFileIO.syncDirectory(at: $0) },
                     exchange: @escaping (URL, URL) throws -> Void = { try AppTransferTransaction.exchange($0, $1) },
                     administratorOperation: ((PrivilegedAppTransfer.Request) throws -> Void)? = nil) -> AppMigrationService {
            AppMigrationService(dockShortcutUpdater: dock, transferStore: storeOverride ?? store, signatureFactStore: facts,
                                transferHooks: .init(checkpoint: hook, synchronizeCleanupParent: synchronizeCleanupParent,
                                                     synchronizeStagingParent: synchronizeStagingParent,
                                                     exchange: exchange, administratorOperation: administratorOperation),
                                updaterCacheDirectory: root.appendingPathComponent("Caches"),
                                runningApplications: running)
        }

        func cleanup() {
            guard root.lastPathComponent.hasPrefix("AppPortsTransferTests-"),
                  root.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else { return }
            // Only this fixture's UUID directory is ever unlocked or removed.
            if let entries = try? SignatureSnapshot.items(in: root) {
                for url in entries {
                    if let info = try? SignatureSnapshot.info(at: url) {
                        _ = lchflags(url.path, info.st_flags & ~UInt32(UF_IMMUTABLE))
                    }
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    func testUpdaterConfirmationUsesTheApplicationInsteadOfCachedScanFlags() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        try makeApp(source)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/Frameworks/Squirrel.framework"),
                                                withIntermediateDirectories: true)
        let app = item(source)
        XCTAssertFalse(app.hasSelfUpdater)
        var choices: [Bool] = []
        let request = try XCTUnwrap(ContentView.updateProtectionRequest(for: [app], service: w.service()) { choices.append($0) })
        XCTAssertEqual(request.actions.map(\.title), ["锁定迁移".localized, "非锁定迁移".localized])
        XCTAssertEqual(request.actions[0].style, .normal)
        XCTAssertEqual(request.actions[1].style, .preferred)
        XCTAssertFalse(request.actions[0].isDefault)
        XCTAssertTrue(request.actions[1].isDefault)
        XCTAssertNotNil(request.introText)
        XCTAssertTrue(choices.isEmpty)
        request.onCancel()
        XCTAssertTrue(choices.isEmpty)
        request.actions[0].handler()
        request.actions[1].handler()
        XCTAssertEqual(choices, [true, false])
        try FileManager.default.removeItem(at: source.appendingPathComponent("Contents/Frameworks/Squirrel.framework"))
        XCTAssertNil(ContentView.updateProtectionRequest(for: [app], service: w.service()) { _ in XCTFail("No automatic choice") })
    }

    @MainActor
    func testUpdateMigrationCopyUsesLocalizedCatalogStrings() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        try makeApp(source, sparkle: true)
        let language = LanguageManager.shared.language
        let preference = UserDefaults.standard.object(forKey: "selectedLanguage")
        defer {
            LanguageManager.shared.language = language
            if let preference { UserDefaults.standard.set(preference, forKey: "selectedLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "selectedLanguage") }
        }
        let expectations: [(String, String, String)] = [
            ("zh-Hans", "以下应用的更新方式可能受到迁移影响：", "在设置中开启"),
            ("en", "Migration may affect how the following apps update:", "In Settings, enable"),
            ("fr", "La migration peut affecter la façon dont les apps suivantes se mettent à jour :", "Dans Paramètres, activez"),
            ("zh-Hant", "以下應用程式的更新方式可能受到遷移影響：", "在設定中開啟"),
        ]
        for (code, expectedPrefix, expectedSettingsPhrase) in expectations {
            LanguageManager.shared.language = code
            let request = try XCTUnwrap(ContentView.updateProtectionRequest(for: [item(source)], service: w.service()) { _ in })
            let intro = try XCTUnwrap(request.intro)
            XCTAssertTrue(intro.hasPrefix(expectedPrefix), "[\(code)] \(intro)")
            XCTAssertTrue(intro.contains(expectedSettingsPhrase), "[\(code)] \(intro)")
            XCTAssertNotNil(request.introText)
        }
    }

    func testExplicitUpdaterLockChoiceSurvivesMigrationAndRestore() async throws {
        for shouldLock in [false, true] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app")
            let destination = w.external.appendingPathComponent("App.app")
            try makeApp(source)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/Frameworks/Squirrel.framework"),
                                                    withIntermediateDirectories: true)
            let service = w.service()
            XCTAssertEqual(service.applicationsRequiringUpdateProtectionConfirmation(in: [item(source)]).count, 1)
            let result = try await service.moveAndLink(appToMove: item(source), destinationURL: destination,
                isRunning: false, lockExternal: shouldLock, progressHandler: nil)
            XCTAssertTrue(result.isComplete, result.pendingMessage ?? "")
            let locked = try SignatureSnapshot.info(at: destination).st_flags & UInt32(UF_IMMUTABLE) != 0
            XCTAssertEqual(locked, shouldLock)
            XCTAssertTrue(try XCTUnwrap(StorageCapabilityProbe.probe(destination: destination)).missing.isEmpty)
            let restored = try await service.moveBack(app: item(destination), localDestinationURL: source, progressHandler: nil)
            XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
            XCTAssertEqual(try payload(source), "payload")
            XCTAssertEqual(try SignatureSnapshot.info(at: source).st_flags & UInt32(UF_IMMUTABLE), 0)
            XCTAssertEqual(service.applicationsRequiringUpdateProtectionConfirmation(in: [item(source)]).count, 1)
            XCTAssertTrue(try w.store.records().isEmpty)
        }
    }

    @MainActor
    func testOrdinaryUpdateApplicationsSkipConfirmationAndStayUnlockedInMixedSelection() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let service = w.service()
        var ordinary: [AppItem] = []
        for (index, identifier) in ["com.tencent.workbuddy.mac", "com.netease.163music"].enumerated() {
            let source = w.local.appendingPathComponent("Renamed\(index).app")
            try makeApp(source, identifier: identifier, sparkle: true)
            let app = item(source)
            ordinary.append(app)
            XCTAssertTrue(service.hasSelfUpdater(at: source))
            XCTAssertNil(ContentView.updateProtectionRequest(for: [app], service: service) { _ in XCTFail("Unexpected confirmation") })
            XCTAssertFalse(service.needsUpdateProtection(app))
        }
        let other = w.local.appendingPathComponent("WorkBuddy.app")
        try makeApp(other, identifier: "example.unrelated", sparkle: true)
        let request = try XCTUnwrap(ContentView.updateProtectionRequest(for: ordinary + [item(other)], service: service) { _ in })
        XCTAssertEqual(service.applicationsRequiringUpdateProtectionConfirmation(in: ordinary + [item(other)]).map(\.path), [other])
        XCTAssertTrue(try XCTUnwrap(request.intro).contains(item(other).displayName))
        for app in ordinary {
            let destination = w.external.appendingPathComponent(app.path.lastPathComponent)
            // A batch's lock choice for another updater must not lock either ordinary application.
            let result = try await service.moveAndLink(appToMove: app, destinationURL: destination,
                isRunning: false, lockExternal: true, progressHandler: nil)
            XCTAssertTrue(result.isComplete, result.pendingMessage ?? "")
            XCTAssertEqual(try SignatureSnapshot.info(at: destination).st_flags & UInt32(UF_IMMUTABLE), 0)
            let restored = try await service.moveBack(app: item(destination), localDestinationURL: app.path, progressHandler: nil)
            XCTAssertTrue(restored.transferResult.isComplete)
            XCTAssertEqual(try payload(app.path), "payload")
        }
    }

    @MainActor
    func testFolderConfirmationChecksEachChildUpdatePolicy() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let folder = w.local.appendingPathComponent("Suite")
        try makeApp(folder.appendingPathComponent("WorkBuddy.app"), identifier: "com.tencent.workbuddy.mac", sparkle: true)
        try makeApp(folder.appendingPathComponent("Music.app"), identifier: "com.netease.163music", sparkle: true)
        var suite = item(folder)
        suite.isFolder = true
        XCTAssertNil(ContentView.updateProtectionRequest(for: [suite], service: w.service()) { _ in XCTFail("Unexpected confirmation") })
        try makeApp(folder.appendingPathComponent("Other.app"), sparkle: true)
        XCTAssertNotNil(ContentView.updateProtectionRequest(for: [suite], service: w.service()) { _ in })
    }

    func testSparkleCacheLocksAreRemovedByRestoreBeforeNonLockedMigration() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeAppWithSparkleHelper(source)
        let migrated = try await w.service().moveAndLink(appToMove: item(source), destinationURL: destination,
            isRunning: false, lockExternal: true, progressHandler: nil)
        XCTAssertTrue(migrated.isComplete)
        let cache = try copySparkleHelper(from: destination, in: w)
        XCTAssertNotEqual(try SignatureSnapshot.info(at: cache).st_flags & UInt32(UF_IMMUTABLE), 0)
        let cachedContents = try SignatureSnapshot.fingerprint(of: cache)
        let restored = try await w.service().moveBack(app: item(destination), localDestinationURL: source, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: cache), cachedContents)
        for url in try SignatureSnapshot.items(in: cache) {
            XCTAssertEqual(try SignatureSnapshot.info(at: url).st_flags & UInt32(UF_IMMUTABLE), 0)
        }
        // Sparkle's next update first removes and then copies this exact helper.
        try FileManager.default.removeItem(at: cache)
        _ = try copySparkleHelper(from: source, in: w)
        let remigrated = try await w.service().moveAndLink(appToMove: item(source), destinationURL: destination,
            isRunning: false, lockExternal: false, progressHandler: nil)
        XCTAssertTrue(remigrated.isComplete)
        XCTAssertEqual(try SignatureSnapshot.info(at: destination).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: cache), cachedContents)
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testSparkleCacheRepairResumesAfterRestoreProtectionWasSuspended() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeAppWithSparkleHelper(source)
        _ = try await w.service().moveAndLink(appToMove: item(source), destinationURL: destination,
            isRunning: false, lockExternal: true, progressHandler: nil)
        let cache = try copySparkleHelper(from: destination, in: w)
        // A missing entry avoids the unrelated existing-target baseline requirement on this cold retry.
        try FileManager.default.removeItem(at: source)
        do {
            _ = try await w.service(hook: { point, _ in
                if point == .sourceProtectionSuspended { throw Interrupted() }
            }).moveBack(app: item(destination), localDestinationURL: source, progressHandler: nil)
            XCTFail("Expected an interruption before cache repair")
        } catch is Interrupted {}
        XCTAssertNotEqual(try SignatureSnapshot.info(at: cache).st_flags & UInt32(UF_IMMUTABLE), 0)
        let record = try XCTUnwrap(w.store.records().first)
        let resumed = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
            .retryTransfer(operationID: record.id)
        XCTAssertTrue(resumed.isComplete, resumed.warnings.joined(separator: "\n"))
        XCTAssertEqual(try SignatureSnapshot.info(at: cache).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testExplicitUnlockAlsoRepairsSparkleCache() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeAppWithSparkleHelper(source)
        _ = try await w.service().moveAndLink(appToMove: item(source), destinationURL: destination,
            isRunning: false, lockExternal: true, progressHandler: nil)
        let cache = try copySparkleHelper(from: destination, in: w)
        XCTAssertTrue(w.service().unlockExternalApp(at: destination))
        XCTAssertEqual(try SignatureSnapshot.info(at: destination).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(try SignatureSnapshot.info(at: cache).st_flags & UInt32(UF_IMMUTABLE), 0)
    }

    func testNonLockedMigrationRepairsExistingCacheWhileLockedMigrationKeepsIt() async throws {
        for lockExternal in [false, true] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app")
            let destination = w.external.appendingPathComponent("App.app")
            try makeAppWithSparkleHelper(source)
            let cache = try copySparkleHelper(from: source, in: w)
            for url in try SignatureSnapshot.items(in: cache).reversed() {
                XCTAssertEqual(lchflags(url.path, UInt32(UF_IMMUTABLE)), 0)
            }
            let migrated = try await w.service().moveAndLink(appToMove: item(source), destinationURL: destination,
                isRunning: false, lockExternal: lockExternal, progressHandler: nil)
            XCTAssertTrue(migrated.isComplete)
            XCTAssertEqual(try SignatureSnapshot.info(at: cache).st_flags & UInt32(UF_IMMUTABLE) != 0, lockExternal)
            XCTAssertEqual(try payload(destination), "payload")
        }
    }

    private func makeAppWithSparkleHelper(_ app: URL) throws {
        try makeApp(app, sparkle: true)
        try makeApp(app.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Resources/Autoupdate.app"),
                    identifier: "org.sparkle-project.Autoupdate")
    }

    private func copySparkleHelper(from app: URL, in workspace: Workspace) throws -> URL {
        let cache = workspace.root.appendingPathComponent("Caches/example.transfer/org.sparkle-project.Sparkle/App (Autoupdate).app")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Resources/Autoupdate.app"),
                                         to: cache)
        return cache
    }

    func testPermissionDeniedExchangeUsesAuthorizedVerifiedOperation() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        var prompts = 0
        let result = try await w.service(exchange: { _, _ in throw POSIXError(.EACCES) }, administratorOperation: {
            prompts += 1
            try PrivilegedAppTransfer.perform($0)
        }).moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false, progressHandler: nil)
        XCTAssertTrue(result.isComplete, result.pendingMessage ?? "")
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(try payload(destination), "payload")
        XCTAssertEqual(try CodeSigner.resolveAppURL(at: source).path, destination.path)
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testCancelledAuthorizationPreservesBothCopiesAndBackgroundRetryDoesNotPrompt() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        var prompts = 0
        let service = w.service(exchange: { _, _ in throw POSIXError(.EACCES) }, administratorOperation: { _ in
            prompts += 1
            throw CancellationError()
        })
        do {
            _ = try await service.moveAndLink(appToMove: item(source), destinationURL: destination,
                                            isRunning: false, progressHandler: nil)
            XCTFail("Expected cancelled authorization")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let record = try XCTUnwrap(w.store.records().first)
        XCTAssertFalse(record.isSwitchComplete)
        XCTAssertEqual(try payload(source), "payload")
        XCTAssertEqual(try payload(destination), "payload")
        do {
            _ = try await service.retryTransfer(operationID: record.id)
            XCTFail("Background retry must leave the permission error pending")
        } catch { XCTAssertEqual((error as NSError).code, Int(EACCES)) }
        XCTAssertEqual(prompts, 1)
        let recovered = try await w.service().retryTransfer(operationID: record.id)
        XCTAssertTrue(recovered.isComplete)
    }

    func testForegroundLinkAndRestoreResumePermissionBlockedMigration() async throws {
        for restore in [false, true] {
            let w = try Workspace(); defer { w.cleanup() }
            let local = w.local.appendingPathComponent("App.app")
            let external = w.external.appendingPathComponent("App.app")
            try makeApp(local)
            do {
                _ = try await w.service(exchange: { _, _ in throw POSIXError(.EACCES) },
                    administratorOperation: { _ in throw CancellationError() })
                    .moveAndLink(appToMove: item(local), destinationURL: external,
                                 isRunning: false, progressHandler: nil)
                XCTFail("Expected pending authorization")
            } catch is CancellationError {}
            let pending = try XCTUnwrap(w.store.records().first)
            var prompts = 0
            let foreground = w.service(exchange: { _, _ in throw POSIXError(.EACCES) },
                administratorOperation: { request in
                    prompts += 1
                    try PrivilegedAppTransfer.perform(request)
                })
            if restore {
                let result = try await foreground.moveBack(app: item(external, status: AppStatus.unlinked),
                                                          localDestinationURL: local, progressHandler: nil)
                XCTAssertTrue(result.transferResult.isComplete, result.transferResult.pendingMessage ?? "")
                XCTAssertEqual(try payload(local), "payload")
                XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
            } else {
                try await foreground.linkAppWhenReady(appToLink: item(external, status: AppStatus.unlinked),
                                                     destinationURL: local)
                XCTAssertEqual(try CodeSigner.resolveAppURL(at: local).path, external.path)
                XCTAssertEqual(try payload(external), "payload")
            }
            XCTAssertEqual(prompts, 1)
            XCTAssertFalse(try w.store.records().contains { $0.id == pending.id })
            try assertNoStages(w)
        }
    }

    func testForegroundRecoveryDoesNotAdoptReplacedExternalApplication() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app")
        let external = w.external.appendingPathComponent("App.app")
        try makeApp(local)
        do {
            _ = try await w.service(exchange: { _, _ in throw POSIXError(.EACCES) },
                administratorOperation: { _ in throw CancellationError() })
                .moveAndLink(appToMove: item(local), destinationURL: external,
                             isRunning: false, progressHandler: nil)
            XCTFail("Expected pending authorization")
        } catch is CancellationError {}
        let retained = w.external.appendingPathComponent("Retained.app")
        try FileManager.default.moveItem(at: external, to: retained)
        try makeApp(external, payload: "replacement")
        var prompts = 0
        do {
            try await w.service(administratorOperation: { _ in prompts += 1 })
                .linkAppWhenReady(appToLink: item(external, status: AppStatus.unlinked), destinationURL: local)
            XCTFail("An unrelated replacement must not be linked over the original")
        } catch {}
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(try payload(local), "payload")
        XCTAssertEqual(try payload(retained), "payload")
        XCTAssertEqual(try payload(external), "replacement")
    }

    func testAuthorizedExchangeRejectsChangesDuringPasswordPrompt() async throws {
        for changed in ["source", "destination", "portal", "parent"] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app")
            let destination = w.external.appendingPathComponent("App.app")
            try makeApp(source)
            let service = w.service(exchange: { _, _ in throw POSIXError(.EPERM) }, administratorOperation: { request in
                switch changed {
                case "source": try Data("changed".utf8).write(to: source.appendingPathComponent("Contents/Resources/payload"))
                case "destination": try Data("changed".utf8).write(to: destination.appendingPathComponent("Contents/Resources/payload"))
                case "portal":
                    let portal = try XCTUnwrap(request.record.stagedPortalURL)
                    try FileManager.default.removeItem(at: portal)
                    try FileManager.default.createSymbolicLink(at: portal, withDestinationURL: w.root)
                default:
                    let moved = w.root.appendingPathComponent("OriginalApplications")
                    try FileManager.default.moveItem(at: w.local, to: moved)
                    try FileManager.default.createSymbolicLink(at: w.local, withDestinationURL: moved)
                }
                XCTAssertThrowsError(try PrivilegedAppTransfer.perform(request), changed)
                throw CancellationError()
            })
            do {
                _ = try await service.moveAndLink(appToMove: item(source), destinationURL: destination,
                                                isRunning: false, progressHandler: nil)
                XCTFail("Expected unchanged local entry")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertFalse(try XCTUnwrap(w.store.records().first).isSwitchComplete)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Contents/Info.plist").path))
        }
    }

    func testAuthorizedCleanupUsesOriginalBaselineAndColdRetryFinishesJournal() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        let result = try await w.service(hook: { point, _ in
            if point == .beforeCleanup { throw Interrupted() }
        }).moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false, progressHandler: nil)
        XCTAssertTrue(result.isSwitchComplete)
        XCTAssertFalse(result.isComplete)
        let record = try w.store.record(result.operationID)
        let cleanup = try XCTUnwrap(record.cleanupItems.first)
        let baseline = try w.store.baseline("source", operationID: result.operationID)
        let request = PrivilegedAppTransfer.Request(action: .remove, record: record,
                                                     sourceBaseline: baseline, cleanupItem: cleanup)
        try PrivilegedAppTransfer.perform(request.preparedForAuthorization())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanup.path))
        XCTAssertEqual(try payload(destination), "payload")
        let finished = try await w.service().retryTransfer(operationID: result.operationID)
        XCTAssertTrue(finished.isComplete, finished.pendingMessage ?? "")
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testAuthorizedCleanupPreservesChangedRetiredCopy() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        let result = try await w.service(hook: { point, _ in
            if point == .beforeCleanup { throw Interrupted() }
        }).moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false, progressHandler: nil)
        let record = try w.store.record(result.operationID)
        let cleanup = try XCTUnwrap(record.cleanupItems.first)
        let retired = URL(fileURLWithPath: cleanup.path)
        let request = try PrivilegedAppTransfer.Request(action: .remove, record: record,
            sourceBaseline: try w.store.baseline("source", operationID: result.operationID), cleanupItem: cleanup)
            .preparedForAuthorization()
        try Data("changed".utf8).write(to: retired.appendingPathComponent("Contents/Resources/payload"))
        XCTAssertThrowsError(try PrivilegedAppTransfer.perform(request))
        XCTAssertEqual(try payload(retired), "changed")
        XCTAssertEqual(try payload(destination), "payload")
    }

    func testApplicationRoundTripCompletesAndRemovesJournalAndStages() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let target = w.external.appendingPathComponent("App.app")
        try makeApp(source, payload: "unchanged")
        let executable = try Data(contentsOf: source.appendingPathComponent("Contents/MacOS/App"))
        let moved = try await w.service().moveAndLink(appToMove: item(source), destinationURL: target,
                                                    isRunning: false, progressHandler: nil)
        XCTAssertTrue(moved.isComplete)
        XCTAssertTrue(try w.store.records().isEmpty)
        XCTAssertEqual(try payload(target), "unchanged")
        let restored = try await w.service().moveBack(app: item(target), localDestinationURL: source, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete)
        XCTAssertFalse(try AppTransferStore.exists(target))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Contents/MacOS/App")), executable)
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testCommittedCleanupRetriesTransientVerificationBeforeReturningResult() async throws {
        for direction in [AppTransferRecord.Direction.migrate, .restore] {
            for failure in [TreeCopyError.sourceChanged(""), .verificationFailed("")] {
                let w = try Workspace(); defer { w.cleanup() }
                let source = (direction == .migrate ? w.local : w.external).appendingPathComponent("App.app")
                let destination = (direction == .migrate ? w.external : w.local).appendingPathComponent("App.app")
                try makeApp(source, payload: "original")
                var cleanupAttempts = 0
                var copies = 0
                var switches = 0
                let service = w.service(hook: { point, _ in
                    if point == .copied { copies += 1 }
                    if point == .entrySwitched { switches += 1 }
                    if point == .beforeCleanup {
                        cleanupAttempts += 1
                        if cleanupAttempts == 1 {
                            try Data("latest active data".utf8).write(to: destination.appendingPathComponent("Contents/Resources/payload"))
                            throw failure
                        }
                    }
                })
                let result: AppTransferResult
                if direction == .migrate {
                    result = try await service.moveAndLink(appToMove: item(source), destinationURL: destination,
                                                          isRunning: false, progressHandler: nil)
                } else {
                    result = try await service.moveBack(app: item(source), localDestinationURL: destination,
                                                        progressHandler: nil).transferResult
                }
                XCTAssertTrue(result.isComplete, result.pendingMessage ?? "")
                XCTAssertTrue(result.warnings.isEmpty)
                XCTAssertEqual(cleanupAttempts, 2)
                XCTAssertEqual(copies, 1)
                XCTAssertEqual(switches, 1)
                XCTAssertEqual(try payload(destination), "latest active data")
                XCTAssertTrue(try w.store.records().isEmpty)
                try assertNoStages(w)
            }
        }
    }

    func testCleanupVerificationRetryPreservesActualChangesToRetiredCopy() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source, payload: "original")
        var retiredPath: URL?
        var injected = false
        let result = try await w.service(hook: { point, record in
            if point == .beforeCleanup && !injected {
                injected = true
                let retired = try XCTUnwrap(record.cleanupItems.first).path
                retiredPath = URL(fileURLWithPath: retired)
                try Data("new data in retired copy".utf8).write(to: retiredPath!.appendingPathComponent("Contents/Resources/payload"))
                try Data("latest active data".utf8).write(to: destination.appendingPathComponent("Contents/Resources/payload"))
                throw TreeCopyError.sourceChanged("Contents/Resources/payload")
            }
        }).moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false, progressHandler: nil)
        XCTAssertTrue(result.isSwitchComplete)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(try payload(XCTUnwrap(retiredPath)), "new data in retired copy")
        XCTAssertEqual(try payload(destination), "latest active data")
        let cold = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
            .retryTransfer(operationID: result.operationID)
        XCTAssertFalse(cold.isComplete)
        XCTAssertEqual(try payload(XCTUnwrap(retiredPath)), "new data in retired copy")
        XCTAssertEqual(try payload(destination), "latest active data")
        XCTAssertFalse(try w.store.records().isEmpty)
    }

    func testCancellationRetriesRemovedStageParentSynchronizationAfterColdRestart() async throws {
        for (direction, portal) in [(AppTransferRecord.Direction.migrate, false), (.migrate, true), (.restore, false)] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = (direction == .migrate ? w.local : w.external).appendingPathComponent("App.app")
            let destination = (direction == .migrate ? w.external : w.local).appendingPathComponent("App.app")
            try makeApp(source, payload: "original application")
            let original = try SignatureSnapshot.fingerprint(of: source)
            let service = w.service(hook: { point, _ in
                if point == (portal ? .portalPrepared : .copied) { throw Interrupted() }
            })
            do {
                if direction == .migrate {
                    _ = try await service.moveAndLink(appToMove: item(source), destinationURL: destination,
                                                     isRunning: false, progressHandler: nil)
                } else {
                    _ = try await service.moveBack(app: item(source), localDestinationURL: destination, progressHandler: nil)
                }
                XCTFail("Expected an interrupted preparation")
            } catch is Interrupted {}
            let record = try XCTUnwrap(w.store.records().first)
            let stage = URL(fileURLWithPath: portal ? try XCTUnwrap(record.portalStagePath) : record.stagePath)
            let parent = stage.deletingLastPathComponent()
            var attempts = 0
            let failSync: (URL) throws -> Void = { url in
                if url.standardizedFileURL.path == parent.standardizedFileURL.path {
                    attempts += 1
                    throw POSIXError(.EIO)
                }
                try DurableFileIO.syncDirectory(at: url)
            }
            for _ in 0..<2 {
                let cold = w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL),
                                     synchronizeStagingParent: failSync)
                do {
                    _ = try await cold.cancelTransfer(operationID: record.id)
                    XCTFail("A missing stage cannot bypass its failed parent synchronization")
                } catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
                XCTAssertFalse(try AppTransferStore.exists(stage))
                XCTAssertNotEqual(try w.store.record(record.id).phase, .cancelled)
                XCTAssertEqual(try SignatureSnapshot.fingerprint(of: source), original)
            }
            XCTAssertEqual(attempts, 2)
            _ = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
                .cancelTransfer(operationID: record.id)
            XCTAssertTrue(try w.store.records().isEmpty)
            XCTAssertFalse(try AppTransferStore.exists(destination))
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: source), original)
            try assertNoStages(w)
        }
    }

    func testCancellationRejectsParentReplacementDuringMissingStageSynchronization() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.external.appendingPathComponent("App.app"), destination = w.local.appendingPathComponent("App.app")
        try makeApp(source, payload: "untouched")
        do {
            _ = try await w.service(hook: { point, _ in if point == .copied { throw Interrupted() } })
                .moveBack(app: item(source), localDestinationURL: destination, progressHandler: nil)
            XCTFail("Expected interrupted preparation")
        } catch is Interrupted {}
        let record = try XCTUnwrap(w.store.records().first)
        do {
            _ = try await w.service(synchronizeStagingParent: { _ in throw POSIXError(.EIO) })
                .cancelTransfer(operationID: record.id)
            XCTFail("Expected the first parent sync to fail after removing the stage")
        } catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
        XCTAssertFalse(try AppTransferStore.exists(URL(fileURLWithPath: record.stagePath)))
        let saved = w.root.appendingPathComponent("SavedApplications")
        var replacements = 0
        do {
            _ = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL),
                                   synchronizeStagingParent: { parent in
                XCTAssertEqual(parent.standardizedFileURL.path, w.local.standardizedFileURL.path)
                replacements += 1
                try FileManager.default.moveItem(at: parent, to: saved)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                try Data("independent directory".utf8).write(to: parent.appendingPathComponent("sentinel"))
                try DurableFileIO.syncDirectory(at: parent)
            }).cancelTransfer(operationID: record.id)
            XCTFail("Synchronizing a replacement parent must not clear the original operation")
        } catch {}
        XCTAssertEqual(replacements, 1)
        XCTAssertNotEqual(try w.store.record(record.id).phase, .cancelled)
        XCTAssertEqual(try payload(source), "untouched")
        XCTAssertEqual(try String(contentsOf: w.local.appendingPathComponent("sentinel")), "independent directory")
        try FileManager.default.moveItem(at: w.local, to: w.root.appendingPathComponent("ReplacementApplications"))
        try FileManager.default.moveItem(at: saved, to: w.local)
        _ = try await w.service().cancelTransfer(operationID: record.id)
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testCommittedStageWarningFinishesAfterUserRemovesUnknownMaterial() async throws {
        for removeWholeStage in [false, true] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app"), destination = w.external.appendingPathComponent("App.app")
            try makeApp(source)
            let result = try await w.service(hook: { point, record in
                if point == .afterCleanup {
                    try Data("user material".utf8).write(to: URL(fileURLWithPath: record.stagePath).appendingPathComponent("personal-file"))
                }
            }).moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false, progressHandler: nil)
            XCTAssertTrue(result.isSwitchComplete)
            XCTAssertFalse(result.isComplete)
            let record = try w.store.record(result.operationID)
            let stage = URL(fileURLWithPath: record.stagePath)
            XCTAssertEqual(record.unclaimedPaths, [stage.path])
            XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("personal-file")), "user material")
            try Data("written after migration".utf8).write(to: destination.appendingPathComponent("Contents/Resources/active-write"))
            let active = try SignatureSnapshot.fingerprint(of: destination)
            try FileManager.default.removeItem(at: removeWholeStage ? stage : stage.appendingPathComponent("personal-file"))
            let completed = try await w.service(hook: { point, _ in
                if point == .copied || point == .entrySwitched { XCTFail("Resolving a stage warning must not repeat the transfer") }
            }, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL)).retryTransfer(operationID: record.id)
            XCTAssertTrue(completed.isComplete, completed.pendingMessage ?? "")
            XCTAssertTrue(try w.store.records().isEmpty)
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: destination), active)
            try assertNoStages(w)
        }
    }

    func testCommittedStageWarningDoesNotDisappearWithReplacedParent() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        let result = try await w.service(hook: { point, record in
            if point == .afterCleanup {
                try Data("keep".utf8).write(to: URL(fileURLWithPath: record.stagePath).appendingPathComponent("personal-file"))
            }
        }).moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false, progressHandler: nil)
        let record = try w.store.record(result.operationID)
        let saved = w.root.appendingPathComponent("SavedExternal")
        try FileManager.default.moveItem(at: w.external, to: saved)
        try FileManager.default.createDirectory(at: w.external, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: w.external.appendingPathComponent("sentinel"))
        let pending = try await w.service().retryTransfer(operationID: record.id)
        XCTAssertFalse(pending.isComplete)
        XCTAssertEqual(try w.store.record(record.id).unclaimedPaths, record.unclaimedPaths)
        XCTAssertEqual(try String(contentsOf: w.external.appendingPathComponent("sentinel")), "unrelated")
        try FileManager.default.moveItem(at: w.external, to: w.root.appendingPathComponent("ReplacementExternal"))
        try FileManager.default.moveItem(at: saved, to: w.external)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: record.stagePath).appendingPathComponent("personal-file"))
        let completed = try await w.service().retryTransfer(operationID: record.id)
        XCTAssertTrue(completed.isComplete, completed.pendingMessage ?? "")
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testRestoreDeletionRetriesFailedParentSynchronizationAfterColdRestart() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.external.appendingPathComponent("App.app"), destination = w.local.appendingPathComponent("App.app")
        try makeApp(source, payload: "restored application")
        var removals = 0
        var syncAttempts = 0
        let failure: (URL) throws -> Void = { parent in
            XCTAssertEqual(parent.standardizedFileURL.path, w.external.standardizedFileURL.path)
            syncAttempts += 1
            throw POSIXError(.EIO)
        }
        let checkpoint: (AppTransferHooks.Checkpoint, AppTransferRecord) throws -> Void = { point, _ in
            if point == .beforeCleanup { removals += 1 }
        }
        let restored = try await w.service(hook: checkpoint, synchronizeCleanupParent: failure)
            .moveBack(app: item(source), localDestinationURL: destination, progressHandler: nil).transferResult
        XCTAssertTrue(restored.isSwitchComplete)
        XCTAssertFalse(restored.isComplete)
        XCTAssertFalse(try AppTransferStore.exists(source))
        let pending = try w.store.record(restored.operationID)
        let cleanup = try XCTUnwrap(pending.cleanupItems.first)
        XCTAssertTrue(cleanup.deletionStarted)
        XCTAssertFalse(cleanup.completed)
        XCTAssertNil(try TreeCopySession.retainedRemovalURL(at: source, removalID: cleanup.id))
        let baseline = try w.store.baseline(cleanup.baselineName, operationID: pending.id)
        try Data("new application data".utf8).write(to: destination.appendingPathComponent("Contents/Resources/after-restore"))
        let active = try SignatureSnapshot.fingerprint(of: destination)

        let cold = w.service(hook: checkpoint, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL),
                             synchronizeCleanupParent: failure)
        let failedAgain = try await cold.retryTransfer(operationID: pending.id)
        XCTAssertTrue(failedAgain.isSwitchComplete)
        XCTAssertFalse(failedAgain.isComplete)
        XCTAssertFalse(try w.store.record(pending.id).cleanupItems[0].completed)
        XCTAssertEqual(try w.store.baseline(cleanup.baselineName, operationID: pending.id).tree, baseline.tree)
        XCTAssertEqual(syncAttempts, 2)
        XCTAssertEqual(removals, 1, "A missing old bundle must not be deleted a second time")
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: destination), active)

        let repaired = w.service(hook: checkpoint, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL),
                                synchronizeCleanupParent: { parent in
            syncAttempts += 1
            try DurableFileIO.syncDirectory(at: parent)
        })
        let completed = try await repaired.retryTransfer(operationID: pending.id)
        XCTAssertTrue(completed.isComplete, completed.pendingMessage ?? "")
        XCTAssertEqual(syncAttempts, 3)
        XCTAssertEqual(removals, 1)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: destination), active)
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testRestoreDeletionRejectsParentReplacementDuringColdSynchronization() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.external.appendingPathComponent("App.app"), destination = w.local.appendingPathComponent("App.app")
        try makeApp(source, payload: "current application")
        let initial = try await w.service(synchronizeCleanupParent: { _ in throw POSIXError(.EIO) })
            .moveBack(app: item(source), localDestinationURL: destination, progressHandler: nil).transferResult
        let record = try w.store.record(initial.operationID)
        let baseline = try w.store.baseline("source", operationID: record.id)
        let savedParent = w.root.appendingPathComponent("SavedExternalParent")
        var synchronizations = 0
        let replaced = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL),
                                          synchronizeCleanupParent: { parent in
            XCTAssertEqual(parent.standardizedFileURL.path, w.external.standardizedFileURL.path)
            synchronizations += 1
            try DurableFileIO.syncDirectory(at: parent)
            try FileManager.default.moveItem(at: parent, to: savedParent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data("unrelated directory".utf8).write(to: parent.appendingPathComponent("sentinel"))
        }).retryTransfer(operationID: record.id)
        XCTAssertTrue(replaced.isSwitchComplete)
        XCTAssertFalse(replaced.isComplete)
        XCTAssertEqual(synchronizations, 1)
        XCTAssertFalse(try w.store.record(record.id).cleanupItems[0].completed)
        XCTAssertEqual(try w.store.baseline("source", operationID: record.id).tree, baseline.tree)
        XCTAssertEqual(try String(contentsOf: w.external.appendingPathComponent("sentinel")), "unrelated directory")
        XCTAssertEqual(try payload(destination), "current application")
        try FileManager.default.removeItem(at: w.external)
        try FileManager.default.moveItem(at: savedParent, to: w.external)
        let completed = try await w.service().retryTransfer(operationID: record.id)
        XCTAssertTrue(completed.isComplete, completed.pendingMessage ?? "")
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testMissingLegacyPortalRetainsCleanupUntilItsOwnParentSynchronizationSucceeds() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let suite = w.external.appendingPathComponent("Suite"), destination = w.local.appendingPathComponent("Suite")
        let app = suite.appendingPathComponent("App.app"), portal = w.local.appendingPathComponent("App.app")
        try makeApp(app)
        try FileManager.default.createSymbolicLink(at: portal, withDestinationURL: app)
        let folder = AppItem(name: "Suite", path: suite, status: AppStatus.local, isFolder: true)
        var portalSyncAttempts = 0
        let failPortalSync: (URL) throws -> Void = { parent in
            if parent.standardizedFileURL.path == w.local.standardizedFileURL.path {
                portalSyncAttempts += 1
                throw POSIXError(.EIO)
            }
            try DurableFileIO.syncDirectory(at: parent)
        }
        let restored = try await w.service(synchronizeCleanupParent: failPortalSync)
            .moveBack(app: folder, localDestinationURL: destination, progressHandler: nil).transferResult
        XCTAssertTrue(restored.isSwitchComplete)
        XCTAssertFalse(restored.isComplete)
        XCTAssertFalse(try AppTransferStore.exists(portal))
        let pending = try w.store.record(restored.operationID)
        let oldPortal = try XCTUnwrap(pending.legacyPortals.first)
        XCTAssertTrue(oldPortal.deletionStarted)
        XCTAssertFalse(oldPortal.retired)
        XCTAssertTrue(pending.cleanupItems.allSatisfy(\.completed))
        let current = try SignatureSnapshot.fingerprint(of: destination)

        let cold = w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL),
                             synchronizeCleanupParent: failPortalSync)
        let failedAgain = try await cold.retryTransfer(operationID: pending.id)
        XCTAssertFalse(failedAgain.isComplete)
        XCTAssertFalse(try w.store.record(pending.id).legacyPortals[0].retired)
        XCTAssertEqual(portalSyncAttempts, 2)
        XCTAssertFalse(try AppTransferStore.exists(portal))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: destination), current)

        let completed = try await w.service(synchronizeCleanupParent: { parent in
            if parent.standardizedFileURL.path == w.local.standardizedFileURL.path { portalSyncAttempts += 1 }
            try DurableFileIO.syncDirectory(at: parent)
        }).retryTransfer(operationID: pending.id)
        XCTAssertTrue(completed.isComplete, completed.pendingMessage ?? "")
        XCTAssertEqual(portalSyncAttempts, 3)
        XCTAssertTrue(try w.store.records().isEmpty)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: destination), current)
        try assertNoStages(w)
    }

    func testDamagedUnrelatedRecordsStayVisibleWithoutBlockingOtherMovesOrCleanup() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("Pending.app")
        let target = w.external.appendingPathComponent("Pending.app")
        try makeApp(source, payload: "pending cleanup")
        let pending = try await w.service(hook: { point, _ in
            if point == .beforeCleanup { throw Interrupted() }
        }).moveAndLink(appToMove: item(source), destinationURL: target, isRunning: false, progressHandler: nil)
        XCTAssertTrue(pending.isSwitchComplete)
        XCTAssertFalse(pending.isComplete)

        let brokenID = UUID()
        let broken = w.store.directoryURL.appendingPathComponent(brokenID.uuidString + ".plist")
        let brokenBytes = Data("a truncated property list".utf8)
        try brokenBytes.write(to: broken)
        let partial = w.store.directoryURL.appendingPathComponent(UUID().uuidString + ".plist")
        let partialBytes = try PropertyListSerialization.data(fromPropertyList: [
            "appName": "Unrelated damaged operation", "sourcePath": w.root.appendingPathComponent("Other.app").path
        ], format: .binary, options: 0)
        try partialBytes.write(to: partial)
        let inspection = try w.service().pendingTransferInspection()
        XCTAssertEqual(inspection.records.map(\.id), [pending.operationID])
        XCTAssertEqual(Set(inspection.issues.map(\.url)), [broken, partial])
        XCTAssertEqual(try w.service().pendingTransfers().map(\.id), [pending.operationID])
        XCTAssertThrowsError(try w.store.record(brokenID), "An unreadable record never becomes a resumable operation")
        do {
            _ = try await w.service().retryTransfer(operationID: brokenID)
            XCTFail("Retry must reject the selected damaged record")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }

        let other = w.local.appendingPathComponent("Independent.app")
        let otherTarget = w.external.appendingPathComponent("Independent.app")
        try makeApp(other, payload: "independent", identifier: "example.independent")
        let moved = try await w.service().moveAndLink(appToMove: item(other), destinationURL: otherTarget,
            isRunning: false, progressHandler: nil)
        XCTAssertTrue(moved.isComplete, moved.pendingMessage ?? "")
        let pendingURL = w.store.directoryURL.appendingPathComponent(pending.operationID.uuidString + ".plist")
        let pendingBytes = try Data(contentsOf: pendingURL)
        let targetBeforePause = try SignatureSnapshot.fingerprint(of: target)
        let pauses = DiskEjectionPauseStore(directory: w.store.operationLockURL.deletingLastPathComponent())
        let pause = try pauses.pause(.init(deviceIdentifier: "disk-fixture", connectionID: "fixture:1",
            displayName: "Paused fixture", volumeUUIDs: [UUID().uuidString], containerUUIDs: [],
            mountPaths: [target.path]))
        do {
            _ = try await w.service().retryTransfer(operationID: pending.operationID)
            XCTFail("Retry must respect the selected operation's disk pause")
        } catch DiskEjectionError.paused {} catch {
            XCTFail("Expected a disk pause, received \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: pendingURL), pendingBytes)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: target), targetBeforePause)
        XCTAssertEqual(try pauses.snapshot().pauses, [pause])
        try pauses.save([])
        let completed = try await w.service().retryTransfer(operationID: pending.operationID)
        XCTAssertTrue(completed.isComplete, completed.pendingMessage ?? "")
        XCTAssertEqual(try payload(target), "pending cleanup")
        XCTAssertEqual(try payload(otherTarget), "independent")
        XCTAssertEqual(try Data(contentsOf: broken), brokenBytes)
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
        XCTAssertTrue(try w.service().pendingTransfers().isEmpty)
        XCTAssertEqual(try w.service().pendingTransferInspection().issues.count, 2)
        try assertNoStages(w)
    }

    func testDamagedRecordKnownPathsStillBlockAConflictingMove() async throws {
        for field in ["sourcePath", "destinationPath", "stagePath", "portalStagePath", "successorActivation", "predecessorActivations"] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app")
            let target = w.external.appendingPathComponent("App.app")
            try makeApp(source, payload: "must stay local")
            let before = try SignatureSnapshot.fingerprint(of: source)
            try FileManager.default.createDirectory(at: w.store.directoryURL, withIntermediateDirectories: true)
            let broken = w.store.directoryURL.appendingPathComponent(UUID().uuidString + ".plist")
            let object: [String: Any]
            if field == "successorActivation" { object = [field: ["path": source.path]] }
            else if field == "predecessorActivations" { object = [field: [["activation": ["path": source.path]]]] }
            else { object = [field: source.path] }
            let bytes = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
            try bytes.write(to: broken)
            do {
                _ = try await w.service().moveAndLink(appToMove: item(source), destinationURL: target,
                    isRunning: false, progressHandler: nil)
                XCTFail("A damaged record's known \(field) must still protect that location")
            } catch {}
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: source), before)
            XCTAssertFalse(try AppTransferStore.exists(target))
            XCTAssertEqual(try Data(contentsOf: broken), bytes)
            XCTAssertTrue(try w.store.inventory().records.isEmpty)
            XCTAssertEqual(try w.store.inventory().issues.count, 1)
            try assertNoStages(w)
        }
    }

    func testReplacementKeepsOldExternalVersionUntilCandidateVerification() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source, payload: "new", version: "2")
        try makeApp(target, payload: "old", version: "1")
        var inspected = false
        let interrupted = w.service(hook: { point, _ in
            if point == .copied {
                inspected = true
                XCTAssertEqual(try self.payload(target), "old")
                XCTAssertEqual(try self.payload(source), "new")
                throw Interrupted()
            }
        })
        do {
            _ = try await interrupted.moveAndLink(appToMove: item(source, status: AppStatus.pendingMoveOut),
                destinationURL: target, isRunning: false, progressHandler: nil)
            XCTFail("Expected an interruption before verification")
        } catch is Interrupted {}
        XCTAssertTrue(inspected)
        XCTAssertEqual(try payload(target), "old")
        let pending = try XCTUnwrap(w.store.records().first)
        let completed = try await w.service().retryTransfer(operationID: pending.id)
        XCTAssertTrue(completed.isComplete)
        XCTAssertEqual(try payload(target), "new")
        try assertNoStages(w)
    }

    func testSameIDUnknownVersionRequiresExplicitReplacementAndDifferentIDIsNeverAdopted() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source, payload: "new", version: "next")
        try makeApp(target, payload: "old", version: "stable")
        do {
            _ = try await w.service().moveAndLink(appToMove: item(source, status: AppStatus.pendingMoveOut), destinationURL: target,
                                                isRunning: false, progressHandler: nil)
            XCTFail("An unrecognized version must require explicit replacement")
        } catch {}
        XCTAssertEqual(try payload(target), "old")
        let choice = try XCTUnwrap(w.service().replacementChoice(for: item(source), destinationURL: target))
        XCTAssertEqual(choice.versionComparison, .unrecognized)
        let result = try await w.service().moveAndLink(appToMove: item(source), destinationURL: target,
            isRunning: false, replacementChoice: choice, progressHandler: nil)
        XCTAssertTrue(result.isComplete)

        let other = w.local.appendingPathComponent("Other.app")
        try makeApp(other, payload: "unrelated", identifier: "example.unrelated")
        XCTAssertNil(try w.service().replacementChoice(for: item(other), destinationURL: target))
        do {
            _ = try await w.service().moveAndLink(appToMove: item(other), destinationURL: target,
                isRunning: false, replaceExistingSameApplication: true, progressHandler: nil)
            XCTFail("Explicit replacement cannot adopt a different bundle identity")
        } catch {}
        XCTAssertEqual(try payload(target), "new")
        XCTAssertEqual(try payload(other), "unrelated")
    }

    func testReplacementConfirmationCannotBeReusedAfterEitherApplicationObjectChanges() async throws {
        for replacingSource in [true, false] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
            try makeApp(source, payload: "selected source", version: "next")
            try makeApp(target, payload: "selected target", version: "stable")
            let choice = try XCTUnwrap(w.service().replacementChoice(for: item(source), destinationURL: target))
            let changed = replacingSource ? source : target
            let saved = changed.deletingLastPathComponent().appendingPathComponent("Saved.app")
            try FileManager.default.moveItem(at: changed, to: saved)
            try makeApp(changed, payload: "other installation", version: "unrecognized")
            do {
                _ = try await w.service().moveAndLink(appToMove: item(source), destinationURL: target,
                    isRunning: false, replacementChoice: choice, progressHandler: nil)
                XCTFail("The user confirmed specific source and target objects")
            } catch {}
            XCTAssertEqual(try payload(changed), "other installation")
            XCTAssertEqual(try payload(saved), replacingSource ? "selected source" : "selected target")
            XCTAssertTrue(try w.store.records().isEmpty)
        }
    }

    func testReplacementChoiceReportsVersionComparisonForTheUI() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source, version: "2")
        for (version, comparison) in [("1", AppMigrationService.ReplacementChoice.VersionComparison.newer),
                                      ("2", .same), ("3", .older), ("stable", .unrecognized)] {
            if try AppTransferStore.exists(target) { try FileManager.default.removeItem(at: target) }
            try makeApp(target, version: version)
            let choice = try XCTUnwrap(w.service().replacementChoice(for: item(source), destinationURL: target))
            XCTAssertEqual(choice.versionComparison, comparison)
        }
    }

    func testInterruptionBeforeExistingTargetBaselineCannotAdoptItsLaterContentOnRetry() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source, payload: "new", version: "2")
        try makeApp(target, payload: "old", version: "1")
        do {
            _ = try await w.service(hook: { point, _ in if point == .intentSaved { throw Interrupted() } })
                .moveAndLink(appToMove: item(source, status: AppStatus.pendingMoveOut), destinationURL: target,
                             isRunning: false, progressHandler: nil)
            XCTFail("Expected interruption before the target baseline was saved")
        } catch is Interrupted {}
        let record = try XCTUnwrap(w.store.records().first)
        XCTAssertFalse(record.hasExistingDestinationBaseline)
        XCTAssertNil(record.candidateIdentity)
        let identity = try DataPathIdentity.capture(target)
        try Data("changed after interruption".utf8).write(to: target.appendingPathComponent("Contents/Resources/payload"))
        do {
            _ = try await w.service().retryTransfer(operationID: record.id)
            XCTFail("Retry must not adopt previously unrecorded target contents")
        } catch {}
        XCTAssertEqual(try DataPathIdentity.capture(target), identity)
        XCTAssertEqual(try payload(target), "changed after interruption")
        _ = try await w.service().cancelTransfer(operationID: record.id)
        XCTAssertEqual(try payload(source), "new")
        XCTAssertEqual(try payload(target), "changed after interruption")
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testFolderRestorePreservesPersonalFilesAddedBesideManagedEntries() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let suite = w.external.appendingPathComponent("Suite"), local = w.local.appendingPathComponent("Suite")
        try makeApp(suite.appendingPathComponent("App.app"))
        let suiteItem = AppItem(name: "Suite", path: suite, status: AppStatus.local, isFolder: true)
        try w.service().linkApp(appToLink: suiteItem, destinationURL: local)
        let personal = local.appendingPathComponent("Personal.txt")
        try Data("personal content".utf8).write(to: personal)
        do {
            _ = try await w.service().moveBack(app: suiteItem, localDestinationURL: local, progressHandler: nil)
            XCTFail("A folder marker cannot authorize removing personal content")
        } catch {}
        XCTAssertEqual(try String(contentsOf: personal), "personal content")
        XCTAssertEqual(try payload(suite.appendingPathComponent("App.app")), "payload")
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testSourceChangeImmediatelyBeforeSwitchIsRejectedAndCancellationKeepsNewSourceContent() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source, payload: "initial")
        let service = w.service(hook: { point, _ in
            if point == .beforeSwitch { try Data("changed while copying".utf8).write(to: source.appendingPathComponent("Contents/Resources/payload")) }
        })
        do {
            _ = try await service.moveAndLink(appToMove: item(source), destinationURL: target, isRunning: false, progressHandler: nil)
            XCTFail("Changed source must not be committed")
        } catch {}
        XCTAssertFalse(try AppTransferStore.exists(target))
        XCTAssertEqual(try payload(source), "changed while copying")
        let pending = try XCTUnwrap(w.store.records().first)
        _ = try await w.service().cancelTransfer(operationID: pending.id)
        XCTAssertEqual(try payload(source), "changed while copying")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testApplicationStartingDuringRestoreKeepsOriginalPortalUntilCommit() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.external.appendingPathComponent("App.app"), local = w.local.appendingPathComponent("App.app")
        try makeApp(source, payload: "original")
        try w.service().linkApp(appToLink: item(source), destinationURL: local)
        let portalIdentity = try DataPathIdentity.capture(local)
        var started = false
        let service = w.service(hook: { point, _ in if point == .copied { started = true } },
            running: { started ? [.init(bundleURL: source, bundleIdentifier: "example.transfer")] : [] })
        do {
            _ = try await service.moveBack(app: item(source), localDestinationURL: local, progressHandler: nil)
            XCTFail("A late launch must prevent the entry switch")
        } catch AppMoverError.appIsRunning {}
        XCTAssertEqual(try DataPathIdentity.capture(local), portalIdentity)
        XCTAssertEqual(try payload(source), "original")
        let pending = try XCTUnwrap(w.store.records().first)
        XCTAssertFalse(pending.isSwitchComplete)
        let result = try await w.service().retryTransfer(operationID: pending.id)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(try payload(local), "original")
    }

    func testRestartAfterEntrySwitchAcceptsActiveWritesAndOnlyFinishesOutstandingWork() async throws {
        for direction in [AppTransferRecord.Direction.migrate, .restore] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = (direction == .migrate ? w.local : w.external).appendingPathComponent("App.app")
            let target = (direction == .migrate ? w.external : w.local).appendingPathComponent("App.app")
            try makeApp(source, payload: "original")
            let interrupted = w.service(hook: { point, _ in if point == .entrySwitched { throw Interrupted() } })
            let partial: AppTransferResult
            if direction == .migrate {
                partial = try await interrupted.moveAndLink(appToMove: item(source), destinationURL: target,
                                                            isRunning: false, progressHandler: nil)
            } else {
                partial = try await interrupted.moveBack(app: item(source), localDestinationURL: target, progressHandler: nil).transferResult
            }
            XCTAssertTrue(partial.isSwitchComplete)
            XCTAssertFalse(partial.pendingTasks.isEmpty)
            let newFile = target.appendingPathComponent("Contents/Resources/after-switch")
            try Data("written through active package".utf8).write(to: newFile)
            let restarted = w.service(hook: { point, _ in
                if point == .copied { XCTFail("A switched transfer must not copy again") }
            })
            XCTAssertTrue(try XCTUnwrap(restarted.pendingTransfers().first).isSwitchComplete)
            let result = try await restarted.retryTransfer(operationID: partial.operationID)
            XCTAssertTrue(result.isComplete, result.warnings.joined(separator: "\n"))
            XCTAssertEqual(try String(contentsOf: newFile), "written through active package")
            try assertNoStages(w)
        }
    }

    func testPostCommitOldInstanceDelaysDeletionWithoutFailingRestore() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.external.appendingPathComponent("App.app"), local = w.local.appendingPathComponent("App.app")
        try makeApp(source, payload: "live")
        var running = false
        var dockCalls = 0
        let service = w.service(hook: { point, _ in if point == .committed { running = true } },
            dock: { _, _ in dockCalls += 1; return 1 },
            running: { running ? [.init(bundleURL: source, bundleIdentifier: "example.transfer")] : [] })
        let result = try await service.moveBack(app: item(source), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(result.isSwitchComplete)
        XCTAssertTrue(result.externalSourceRemains)
        XCTAssertEqual(dockCalls, 1)
        XCTAssertTrue(result.pendingTasks.contains { $0.kind == .oldCopy })
        XCTAssertEqual(try payload(source), "live")
        XCTAssertEqual(try payload(local), "live")
        running = false
        let completed = try await w.service().retryTransfer(operationID: result.transferResult.operationID)
        XCTAssertTrue(completed.isComplete)
        XCTAssertFalse(try AppTransferStore.exists(source))
    }

    func testDockRetryWorksAfterOldCopiesAndStageDirectoriesAreAlreadyGone() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        let result = try await w.service(dock: { _, _ in throw Interrupted() })
            .moveAndLink(appToMove: item(source), destinationURL: target, isRunning: false, progressHandler: nil)
        XCTAssertTrue(result.isSwitchComplete)
        XCTAssertTrue(result.pendingTasks.contains { $0.kind == .dock })
        XCTAssertFalse(result.pendingTasks.contains { $0.kind == .oldCopy })
        try assertNoStages(w)
        var calls = 0
        let retry = try await w.service(hook: { point, _ in if point == .copied { XCTFail("Dock retry must not copy") } },
                                       dock: { _, _ in calls += 1; return 1 }).retryTransfer(operationID: result.operationID)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(retry.isComplete, retry.warnings.joined(separator: "\n"))
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testCleanupFailureStaysVisibleAndRetryDoesNotRepeatCopy() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.external.appendingPathComponent("App.app"), local = w.local.appendingPathComponent("App.app")
        try makeApp(source, payload: "retained")
        let result = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
            .moveBack(app: item(source), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(result.isSwitchComplete)
        XCTAssertTrue(result.externalSourceRemains)
        XCTAssertEqual(try payload(source), "retained")
        let pending = try XCTUnwrap(w.service().pendingTransfers().first)
        XCTAssertFalse(pending.canCancel)
        XCTAssertTrue(pending.pendingTasks.contains { $0.kind == .oldCopy })
        let retry = try await w.service(hook: { point, _ in if point == .copied { XCTFail("Cleanup retry must not copy") } })
            .retryTransfer(operationID: pending.id)
        XCTAssertTrue(retry.isComplete)
        XCTAssertFalse(try AppTransferStore.exists(source))
    }

    func testPendingMigrationFinishesAfterSubsequentRestoreWithoutRepeatingCopy() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app")
        let external = w.external.appendingPathComponent("App.app")
        try makeApp(local, payload: "original")
        let executable = try Data(contentsOf: local.appendingPathComponent("Contents/MacOS/App"))
        var cleanupAttempts = 0
        let migrated = try await w.service(hook: { point, _ in
            if point == .beforeCleanup {
                cleanupAttempts += 1
                if cleanupAttempts == 1 { throw Interrupted() }
            }
        }).moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        XCTAssertTrue(migrated.isSwitchComplete)
        XCTAssertFalse(migrated.isComplete)
        let pending = try w.store.record(migrated.operationID)
        let oldCopy = URL(fileURLWithPath: try XCTUnwrap(pending.cleanupItems.first { $0.role == .source }).path)
        XCTAssertEqual(try payload(oldCopy), "original")
        let addedRelativePath = "Contents/Resources/created-after-migration"
        try Data("new active content".utf8).write(to: external.appendingPathComponent(addedRelativePath))

        let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
        XCTAssertFalse(try AppTransferStore.exists(external))
        XCTAssertEqual(try payload(oldCopy), "original")
        let activeIdentity = try DataPathIdentity.capture(local)
        let activeFingerprint = try SignatureSnapshot.fingerprint(of: local)
        let linked = try w.store.record(migrated.operationID)
        let successor = try XCTUnwrap(linked.successorActivation)
        XCTAssertEqual(successor.operationID, restored.transferResult.operationID)
        XCTAssertEqual(linked.destinationPath, external.path)
        XCTAssertEqual(linked.activeDestinationPath, local.path)
        XCTAssertTrue(successor.identity.matchesFilesystemObject(activeIdentity))
        XCTAssertTrue(try successor.parentIdentity.matchesFilesystemObject(DataPathIdentity.capture(w.local)))
        let retried = try await w.service(hook: { point, _ in
            if ![.committed, .beforeCleanup, .afterCleanup].contains(point) {
                XCTFail("The pending migration must only finish its old cleanup")
            }
        }, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
            .retryTransfer(operationID: migrated.operationID)

        XCTAssertTrue(retried.isComplete, retried.warnings.joined(separator: "\n"))
        XCTAssertEqual(retried.destinationURL.standardizedFileURL.path, local.standardizedFileURL.path)
        XCTAssertTrue(try DataPathIdentity.capture(local).matchesFilesystemObject(activeIdentity))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), activeFingerprint)
        XCTAssertEqual(try payload(local), "original")
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent(addedRelativePath)), "new active content")
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("Contents/MacOS/App")), executable)
        XCTAssertFalse(try AppTransferStore.exists(oldCopy))
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testPendingMigrationDockTaskFinishesAtRestoredLocation() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        try makeApp(local)
        let migrated = try await w.service(dock: { _, _ in throw Interrupted() })
            .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        XCTAssertEqual(migrated.pendingTasks.map(\.kind), [.dock])
        try assertNoStages(w)
        let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete)
        let pending = try w.store.record(migrated.operationID)
        XCTAssertEqual(pending.pendingTasks.map(\.path), [local.path])
        let active = try SignatureSnapshot.fingerprint(of: local)
        var calls = 0
        let completed = try await w.service(hook: { point, _ in
            if point == .copied { XCTFail("A superseded Dock task must not copy") }
        }, dock: { _, destination in
            calls += 1
            XCTAssertEqual(destination, local)
            return 1
        }, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL)).retryTransfer(operationID: migrated.operationID)
        XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
        XCTAssertEqual(completed.destinationURL.standardizedFileURL.path, local.standardizedFileURL.path)
        XCTAssertEqual(calls, 0, "The old Dock source is already the current local destination")
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), active)
        XCTAssertFalse(try AppTransferStore.exists(external))
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testSupersededMigrationNeverAppliesItsOutstandingProtectionToRestoredApp() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        try makeApp(local, sparkle: true)
        let migrated = try await w.service(hook: { point, _ in if point == .committed { throw Interrupted() } })
            .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        XCTAssertTrue(migrated.isSwitchComplete)
        XCTAssertTrue(migrated.pendingTasks.contains { $0.kind == .updateProtection })
        let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete)
        XCTAssertFalse(try w.store.record(migrated.operationID).pendingTasks.contains { $0.kind == .updateProtection })
        let activeFlags = try flagSnapshot(local)
        XCTAssertTrue(activeFlags.values.allSatisfy { $0 & UInt32(UF_IMMUTABLE) == 0 })
        let completed = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
        XCTAssertEqual(try flagSnapshot(local), activeFlags)
        XCTAssertTrue(try AppUpdateProtectionStore(transferStore: w.store).inventory().records.isEmpty)
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testRepeatedRoundTripsAdvanceEveryPendingMigrationWithoutReusingIt() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        try makeApp(local)
        var pendingIDs: [UUID] = []
        var oldCopies: [URL] = []
        for round in 0..<2 {
            try Data("round \(round)".utf8).write(to: local.appendingPathComponent("Contents/Resources/round-\(round)"))
            let migrated = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
                .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
            XCTAssertTrue(migrated.isSwitchComplete)
            XCTAssertFalse(pendingIDs.contains(migrated.operationID), "A new round trip needs its own verified transfer")
            pendingIDs.append(migrated.operationID)
            let record = try w.store.record(migrated.operationID)
            oldCopies.append(URL(fileURLWithPath: try XCTUnwrap(record.cleanupItems.first { $0.role == .source }).path))
            let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
            XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
            for id in pendingIDs {
                let successor = try XCTUnwrap(w.store.record(id).successorActivation)
                XCTAssertEqual(successor.operationID, restored.transferResult.operationID)
                XCTAssertEqual(successor.path, local.path)
                XCTAssertTrue(try successor.identity.matchesFilesystemObject(DataPathIdentity.capture(local)))
            }
        }
        let active = try SignatureSnapshot.fingerprint(of: local)
        for id in pendingIDs {
            let completed = try await w.service(hook: { point, _ in
                if point == .copied { XCTFail("An old transfer cannot repeat preparation at a reused path") }
            }).retryTransfer(operationID: id)
            XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
            XCTAssertEqual(completed.destinationURL.standardizedFileURL.path, local.standardizedFileURL.path)
        }
        for round in 0..<2 {
            XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("Contents/Resources/round-\(round)")), "round \(round)")
        }
        for copy in oldCopies { XCTAssertFalse(try AppTransferStore.exists(copy)) }
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), active)
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testActivationHandoffWriteFailuresKeepSourceUntilColdRetryCompletesBothRecords() async throws {
        for failClearingPredecessors in [false, true] {
            let w = try Workspace(); defer { w.cleanup() }
            let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
            try makeApp(local, payload: "retained")
            let migrated = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
                .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
            let oldCopy = URL(fileURLWithPath: try XCTUnwrap(w.store.record(migrated.operationID).cleanupItems.first).path)
            let sourceIdentity = try DataPathIdentity.capture(external)
            var failedWrites = 0
            let failingStore = AppTransferStore(directoryURL: w.store.directoryURL, beforeRecordWrite: { record in
                let writesSuccessor = record.operationID == migrated.operationID && record.successorActivation != nil
                let clearsPredecessors = record.direction == .restore && record.isSwitchComplete && record.predecessorActivations == nil
                if failClearingPredecessors ? clearsPredecessors : writesSuccessor {
                    failedWrites += 1
                    XCTAssertTrue(try DataPathIdentity.capture(external).matchesFilesystemObject(sourceIdentity))
                    XCTAssertEqual(try self.payload(local), "retained")
                    throw POSIXError(.EIO)
                }
            })
            let restored = try await w.service(storeOverride: failingStore)
                .moveBack(app: item(external), localDestinationURL: local, progressHandler: nil).transferResult
            XCTAssertTrue(restored.isSwitchComplete)
            XCTAssertFalse(restored.isComplete)
            XCTAssertTrue(restored.pendingTasks.contains { $0.kind == .recordCommit })
            XCTAssertEqual(try w.store.record(restored.operationID).predecessorActivations?.count, 1)
            XCTAssertEqual(try w.store.record(migrated.operationID).successorActivation != nil, failClearingPredecessors)
            let active = try SignatureSnapshot.fingerprint(of: local)
            let stillPending = try await w.service(storeOverride: failingStore).retryTransfer(operationID: restored.operationID)
            XCTAssertFalse(stillPending.isComplete)
            XCTAssertGreaterThanOrEqual(failedWrites, 2)
            XCTAssertEqual(try payload(external), "retained")
            XCTAssertEqual(try payload(oldCopy), "retained")
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), active)

            let cold = w.service(hook: { point, _ in
                if point == .copied { XCTFail("Retrying durable handoff writes must not repeat the transfer") }
            }, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
            let finishedRestore = try await cold.retryTransfer(operationID: restored.operationID)
            XCTAssertTrue(finishedRestore.isComplete, finishedRestore.warnings.joined(separator: "\n"))
            XCTAssertFalse(try AppTransferStore.exists(external))
            let finishedMigration = try await cold.retryTransfer(operationID: migrated.operationID)
            XCTAssertTrue(finishedMigration.isComplete, finishedMigration.warnings.joined(separator: "\n"))
            XCTAssertFalse(try AppTransferStore.exists(oldCopy))
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), active)
            XCTAssertTrue(try w.store.records().isEmpty)
            try assertNoStages(w)
        }
    }

    func testNextMoveReconcilesPendingHandoffWithoutInspectingConflictingOldCopy() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        let nextExternal = w.external.appendingPathComponent("Next.app")
        try makeApp(local, payload: "active")
        let migrated = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
            .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        let oldCopy = URL(fileURLWithPath: try XCTUnwrap(w.store.record(migrated.operationID).cleanupItems.first).path)
        let savedOld = w.root.appendingPathComponent("SavedOriginal.app")
        try FileManager.default.moveItem(at: oldCopy, to: savedOld)
        try makeApp(oldCopy, payload: "unrelated retained copy")
        let replacementIdentity = try DataPathIdentity.capture(oldCopy)
        var writesFail = true
        let store = AppTransferStore(directoryURL: w.store.directoryURL, beforeRecordWrite: { record in
            if writesFail && record.operationID == migrated.operationID && record.successorActivation != nil { throw POSIXError(.EIO) }
        })
        let restored = try await w.service(storeOverride: store)
            .moveBack(app: item(external), localDestinationURL: local, progressHandler: nil).transferResult
        XCTAssertTrue(restored.isSwitchComplete)
        XCTAssertFalse(restored.isComplete)
        let currentIdentity = try DataPathIdentity.capture(local)
        do {
            _ = try await w.service(storeOverride: store).moveAndLink(appToMove: item(local), destinationURL: nextExternal,
                                                                    isRunning: false, progressHandler: nil)
            XCTFail("The preceding handoff must become durable before another transfer begins")
        } catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
        XCTAssertFalse(try AppTransferStore.exists(nextExternal))
        XCTAssertEqual(try w.store.records().count, 2)
        XCTAssertTrue(try DataPathIdentity.capture(local).matchesFilesystemObject(currentIdentity))
        writesFail = false
        var checkedAdmission = false
        let next = try await w.service(hook: { point, _ in
            if point == .beforeSwitch {
                checkedAdmission = true
                XCTAssertNil(try w.store.record(restored.operationID).predecessorActivations)
                XCTAssertEqual(try w.store.record(migrated.operationID).activeDestinationPath, local.path)
                XCTAssertTrue(try DataPathIdentity.capture(oldCopy).matchesFilesystemObject(replacementIdentity))
            }
        }, storeOverride: store).moveAndLink(appToMove: item(local), destinationURL: nextExternal,
                                             isRunning: false, progressHandler: nil)
        XCTAssertTrue(checkedAdmission)
        XCTAssertTrue(next.isComplete, next.warnings.joined(separator: "\n"))
        let finishedRestore = try await w.service().retryTransfer(operationID: restored.operationID)
        XCTAssertTrue(finishedRestore.isComplete, finishedRestore.warnings.joined(separator: "\n"))
        let conflicted = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertFalse(conflicted.isComplete)
        XCTAssertEqual(conflicted.destinationURL.standardizedFileURL.path, nextExternal.standardizedFileURL.path)
        XCTAssertTrue(try DataPathIdentity.capture(oldCopy).matchesFilesystemObject(replacementIdentity))
        XCTAssertEqual(try payload(oldCopy), "unrelated retained copy")
        XCTAssertEqual(try payload(savedOld), "active")
        XCTAssertEqual(try payload(nextExternal), "active")
        let savedReplacement = w.root.appendingPathComponent("SavedReplacement.app")
        try FileManager.default.moveItem(at: oldCopy, to: savedReplacement)
        try FileManager.default.moveItem(at: savedOld, to: oldCopy)
        let completed = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
        XCTAssertEqual(try payload(savedReplacement), "unrelated retained copy")
        XCTAssertEqual(try payload(nextExternal), "active")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testSuccessorReceiptRejectsIdenticalReplacementAndFinishesWhenOriginalReturns() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        try makeApp(local, payload: "same bytes")
        let migrated = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
            .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        let oldCopy = URL(fileURLWithPath: try XCTUnwrap(w.store.record(migrated.operationID).cleanupItems.first).path)
        let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete)
        let original = w.root.appendingPathComponent("SavedActive.app")
        try FileManager.default.moveItem(at: local, to: original)
        try FileManager.default.copyItem(at: original, to: local)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: original), try SignatureSnapshot.fingerprint(of: local))
        let replacement = try DataPathIdentity.capture(local)
        let pending = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertFalse(pending.isComplete)
        XCTAssertEqual(pending.destinationURL.standardizedFileURL.path, local.standardizedFileURL.path)
        XCTAssertTrue(try DataPathIdentity.capture(local).matchesFilesystemObject(replacement))
        XCTAssertEqual(try payload(local), "same bytes")
        XCTAssertEqual(try payload(original), "same bytes")
        XCTAssertEqual(try payload(oldCopy), "same bytes")
        let savedReplacement = w.root.appendingPathComponent("SavedReplacement.app")
        try FileManager.default.moveItem(at: local, to: savedReplacement)
        try FileManager.default.moveItem(at: original, to: local)
        let completed = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
        XCTAssertEqual(try payload(savedReplacement), "same bytes")
        XCTAssertEqual(try payload(local), "same bytes")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testSuccessorReceiptChecksItsOwnParentAfterMoveToAnotherDirectory() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        let nextParent = w.root.appendingPathComponent("AnotherExternal")
        let next = nextParent.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: nextParent, withIntermediateDirectories: false)
        try makeApp(local, payload: "current")
        let migrated = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
            .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        let oldCopy = URL(fileURLWithPath: try XCTUnwrap(w.store.record(migrated.operationID).cleanupItems.first).path)
        _ = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        let movedAgain = try await w.service().moveAndLink(appToMove: item(local), destinationURL: next,
                                                          isRunning: false, progressHandler: nil)
        XCTAssertTrue(movedAgain.isComplete)
        let activation = try XCTUnwrap(w.store.record(migrated.operationID).successorActivation)
        XCTAssertEqual(activation.path, next.path)
        let savedParent = w.root.appendingPathComponent("SavedExternalParent")
        try FileManager.default.moveItem(at: nextParent, to: savedParent)
        try FileManager.default.createDirectory(at: nextParent, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: savedParent.appendingPathComponent("App.app"), to: next)
        XCTAssertTrue(try activation.identity.matchesFilesystemObject(DataPathIdentity.capture(next)))
        XCTAssertFalse(try activation.parentIdentity.matchesFilesystemObject(DataPathIdentity.capture(nextParent)))
        let pending = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertFalse(pending.isComplete, "Matching the root alone cannot admit a replaced parent")
        XCTAssertEqual(try payload(oldCopy), "current")
        XCTAssertEqual(try payload(next), "current")
        try FileManager.default.moveItem(at: next, to: savedParent.appendingPathComponent("App.app"))
        try FileManager.default.removeItem(at: nextParent)
        try FileManager.default.moveItem(at: savedParent, to: nextParent)
        let completed = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
        XCTAssertEqual(completed.destinationURL.standardizedFileURL.path, next.standardizedFileURL.path)
        XCTAssertEqual(try payload(next), "current")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testReplacementDuringActivationHandoffPreservesSourceAndAllowsSafeRetry() async throws {
        for replaceParent in [false, true] {
            let w = try Workspace(); defer { w.cleanup() }
            let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
            try makeApp(local, payload: "current")
            let migrated = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
                .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
            let sourceIdentity = try DataPathIdentity.capture(external)
            let saved = w.root.appendingPathComponent(replaceParent ? "SavedApplications" : "SavedActive.app")
            var replaced = false
            let racingStore = AppTransferStore(directoryURL: w.store.directoryURL, beforeRecordWrite: { record in
                if !replaced && record.operationID == migrated.operationID && record.successorActivation != nil {
                    replaced = true
                    if replaceParent {
                        try FileManager.default.moveItem(at: w.local, to: saved)
                        try FileManager.default.createDirectory(at: w.local, withIntermediateDirectories: false)
                        try FileManager.default.copyItem(at: saved.appendingPathComponent("App.app"), to: local)
                    } else {
                        try FileManager.default.moveItem(at: local, to: saved)
                        try FileManager.default.copyItem(at: saved, to: local)
                    }
                }
            })
            let restored = try await w.service(storeOverride: racingStore)
                .moveBack(app: item(external), localDestinationURL: local, progressHandler: nil).transferResult
            XCTAssertTrue(replaced)
            XCTAssertTrue(restored.isSwitchComplete)
            XCTAssertFalse(restored.isComplete)
            XCTAssertEqual(try w.store.record(restored.operationID).predecessorActivations?.count, 1)
            XCTAssertTrue(try DataPathIdentity.capture(external).matchesFilesystemObject(sourceIdentity))
            let replacement = try DataPathIdentity.capture(local)
            let cold = w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
            let stillPending = try await cold.retryTransfer(operationID: restored.operationID)
            XCTAssertFalse(stillPending.isComplete)
            XCTAssertTrue(try DataPathIdentity.capture(external).matchesFilesystemObject(sourceIdentity))
            XCTAssertTrue(try DataPathIdentity.capture(local).matchesFilesystemObject(replacement))
            let savedReplacement = w.root.appendingPathComponent(replaceParent ? "ReplacementApplications" : "Replacement.app")
            if replaceParent {
                try FileManager.default.moveItem(at: w.local, to: savedReplacement)
                try FileManager.default.moveItem(at: saved, to: w.local)
            } else {
                try FileManager.default.moveItem(at: local, to: savedReplacement)
                try FileManager.default.moveItem(at: saved, to: local)
            }
            let finishedRestore = try await cold.retryTransfer(operationID: restored.operationID)
            XCTAssertTrue(finishedRestore.isComplete, finishedRestore.warnings.joined(separator: "\n"))
            let finishedMigration = try await cold.retryTransfer(operationID: migrated.operationID)
            XCTAssertTrue(finishedMigration.isComplete, finishedMigration.warnings.joined(separator: "\n"))
            XCTAssertEqual(try payload(local), "current")
            XCTAssertEqual(try payload(replaceParent ? savedReplacement.appendingPathComponent("App.app") : savedReplacement), "current")
            XCTAssertTrue(try w.store.records().isEmpty)
            try assertNoStages(w)
        }
    }

    func testSuccessorCleanupStillWaitsForTheRetainedOldInstance() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        try makeApp(local, payload: "keep while running")
        let migrated = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
            .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        let oldCopy = URL(fileURLWithPath: try XCTUnwrap(w.store.record(migrated.operationID).cleanupItems.first).path)
        _ = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        let active = try SignatureSnapshot.fingerprint(of: local)
        let pending = try await w.service(running: { [.init(bundleURL: oldCopy, bundleIdentifier: "example.transfer")] })
            .retryTransfer(operationID: migrated.operationID)
        XCTAssertFalse(pending.isComplete)
        XCTAssertEqual(try payload(oldCopy), "keep while running")
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), active)
        let completed = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
        XCTAssertFalse(try AppTransferStore.exists(oldCopy))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), active)
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testIdenticalReplacementSourceDoesNotAcquireAnOlderTransferLineage() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        try makeApp(local, payload: "identical installation bytes")
        let migrated = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
            .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        let oldCopy = URL(fileURLWithPath: try XCTUnwrap(w.store.record(migrated.operationID).cleanupItems.first).path)
        let savedExternal = w.root.appendingPathComponent("OriginalExternal.app")
        try FileManager.default.moveItem(at: external, to: savedExternal)
        try FileManager.default.copyItem(at: savedExternal, to: external)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: external), try SignatureSnapshot.fingerprint(of: savedExternal))
        let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
        XCTAssertNil(try w.store.record(migrated.operationID).successorActivation)
        let active = try SignatureSnapshot.fingerprint(of: local)
        let pending = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertFalse(pending.isComplete)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), active)
        XCTAssertEqual(try payload(oldCopy), "identical installation bytes")
        XCTAssertEqual(try payload(savedExternal), "identical installation bytes")
        XCTAssertEqual(try w.store.records().map(\.id), [migrated.operationID])
    }

    func testSuccessorCleanupPreservesChangedOldContentWithoutBlockingRestore() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        try makeApp(local, payload: "active original")
        let migrated = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
            .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        let oldItem = try XCTUnwrap(w.store.record(migrated.operationID).cleanupItems.first)
        let oldCopy = URL(fileURLWithPath: oldItem.path)
        try Data("later change in retained copy".utf8).write(to: oldCopy.appendingPathComponent("Contents/Resources/payload"))
        let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
        let active = try SignatureSnapshot.fingerprint(of: local)
        let pending = try await w.service().retryTransfer(operationID: migrated.operationID)
        XCTAssertFalse(pending.isComplete)
        XCTAssertTrue(pending.pendingTasks.contains { $0.kind == .oldCopy })
        let retained = try XCTUnwrap(TreeCopySession.retainedRemovalURL(at: oldCopy, removalID: oldItem.id))
        XCTAssertEqual(try payload(retained), "later change in retained copy")
        XCTAssertEqual(try payload(local), "active original")
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), active)
        XCTAssertFalse(try w.store.record(migrated.operationID).cleanupItems[0].completed)
    }

    func testPendingRestoreFinishesWhenItsOldExternalTargetIsExplicitlyReused() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("App.app"), external = w.external.appendingPathComponent("App.app")
        try makeApp(local, payload: "original", version: "dev")
        let migrated = try await w.service().moveAndLink(appToMove: item(local), destinationURL: external,
                                                        isRunning: false, progressHandler: nil)
        XCTAssertTrue(migrated.isComplete)
        var interruptedCleanup = false
        let restored = try await w.service(hook: { point, _ in
            if point == .beforeCleanup && !interruptedCleanup {
                interruptedCleanup = true
                throw Interrupted()
            }
        }).moveBack(app: item(external), localDestinationURL: local, progressHandler: nil).transferResult
        XCTAssertTrue(interruptedCleanup)
        XCTAssertTrue(restored.isSwitchComplete)
        XCTAssertFalse(restored.isComplete)
        let restoreRecord = try w.store.record(restored.operationID)
        let oldSource = try XCTUnwrap(restoreRecord.cleanupItems.first { $0.role == .source })
        XCTAssertEqual(oldSource.path, external.path)
        XCTAssertFalse(oldSource.completed)
        XCTAssertTrue(try oldSource.identity.matchesFilesystemObject(DataPathIdentity.capture(external)))

        // Exercise the product's actual unknown-version replacement choice.
        // These are normal writes to the now-active local application root.
        let infoURL = local.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleShortVersionString"] = "beta"
        info["CFBundleVersion"] = "beta"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        let newRelativePath = "Contents/Resources/created-after-restore"
        try Data("latest active content".utf8).write(to: local.appendingPathComponent(newRelativePath))
        let service = w.service()
        let choice = try XCTUnwrap(service.replacementChoice(for: item(local), destinationURL: external))
        XCTAssertEqual(choice.versionComparison, .unrecognized)
        XCTAssertTrue(try choice.sourceIdentity.matchesFilesystemObject(DataPathIdentity.capture(local)))
        XCTAssertTrue(choice.destinationIdentity.matchesFilesystemObject(oldSource.identity))
        let movedAgain = try await service.moveAndLink(appToMove: item(local), destinationURL: external,
            isRunning: false, replacementChoice: choice, progressHandler: nil)
        XCTAssertTrue(movedAgain.isComplete, movedAgain.warnings.joined(separator: "\n"))
        let activeIdentity = try DataPathIdentity.capture(external)
        let activeFingerprint = try SignatureSnapshot.fingerprint(of: external)

        // Completing the directly conflicting cleanup before replacement is
        // also a valid exit. Any record still present must finish on cold retry.
        if try w.store.records().contains(where: { $0.id == restored.operationID }) {
            let completed = try await w.service(hook: { point, _ in
                if ![.committed, .beforeCleanup, .afterCleanup].contains(point) {
                    XCTFail("A pending restore must not repeat copying or portal preparation")
                }
            }, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL)).retryTransfer(operationID: restored.operationID)
            XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
            XCTAssertEqual(completed.destinationURL.standardizedFileURL.path, external.standardizedFileURL.path)
        }
        XCTAssertTrue(try DataPathIdentity.capture(external).matchesFilesystemObject(activeIdentity))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: external), activeFingerprint)
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent(newRelativePath)), "latest active content")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testReusingPendingRestoreTargetDoesNotWaitForItsUnrelatedDockTask() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let (local, external, restoreRecord) = try await pendingRestoreWithRetainedExternalCopy(in: w,
            dock: { _, _ in throw Interrupted() })
        XCTAssertFalse(restoreRecord.dockSynchronized)
        let addedFile = "Contents/Resources/after-restore"
        try Data("current local addition".utf8).write(to: local.appendingPathComponent(addedFile))
        var dockSources: [String] = []
        var checkedAdmission = false
        let service = w.service(hook: { point, record in
            if point == .intentSaved {
                checkedAdmission = true
                let original = try w.store.record(restoreRecord.id)
                XCTAssertTrue(try XCTUnwrap(original.cleanupItems.first { $0.role == .source }).completed)
                XCTAssertFalse(original.dockSynchronized)
                XCTAssertNil(record.existingDestinationIdentity)
                XCTAssertFalse(try AppTransferStore.exists(external))
            }
        }, dock: { source, _ in
            dockSources.append(source.standardizedFileURL.path)
            if source.standardizedFileURL.path == external.standardizedFileURL.path { throw Interrupted() }
            return 0
        })
        let choice = try XCTUnwrap(service.replacementChoice(for: item(local), destinationURL: external))
        XCTAssertEqual(choice.versionComparison, .unrecognized)
        let moved = try await service.moveAndLink(appToMove: item(local), destinationURL: external,
            isRunning: false, replacementChoice: choice, progressHandler: nil)
        XCTAssertTrue(moved.isComplete, moved.warnings.joined(separator: "\n"))
        XCTAssertTrue(checkedAdmission)
        XCTAssertEqual(dockSources, [local.standardizedFileURL.path])
        let pending = try w.store.record(restoreRecord.id)
        XCTAssertEqual(pending.successorActivation?.path, external.path)
        XCTAssertTrue(pending.pendingTasks.contains { $0.kind == .dock })
        XCTAssertFalse(pending.pendingTasks.contains { $0.kind == .oldCopy && $0.path == external.path })
        let activeIdentity = try DataPathIdentity.capture(external)
        let activeFingerprint = try SignatureSnapshot.fingerprint(of: external)
        let completed = try await w.service(dock: { _, _ in
            XCTFail("An old restore whose source is current again must not rewrite Dock")
            return 0
        }, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL)).retryTransfer(operationID: restoreRecord.id)
        XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
        XCTAssertTrue(try activeIdentity.matchesFilesystemObject(DataPathIdentity.capture(external)))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: external), activeFingerprint)
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent(addedFile)), "current local addition")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testPendingRestoreTargetCleanupFailureBlocksOnlyThatDestination() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let (local, external, restoreRecord) = try await pendingRestoreWithRetainedExternalCopy(in: w)
        let localIdentity = try DataPathIdentity.capture(local), externalIdentity = try DataPathIdentity.capture(external)
        let localFingerprint = try SignatureSnapshot.fingerprint(of: local), externalFingerprint = try SignatureSnapshot.fingerprint(of: external)
        let localNames = try FileManager.default.contentsOfDirectory(atPath: w.local.path).sorted()
        let externalNames = try FileManager.default.contentsOfDirectory(atPath: w.external.path).sorted()
        let recordURL = w.store.directoryURL.appendingPathComponent(restoreRecord.id.uuidString + ".plist")
        var failedCleanups = 0
        for _ in 0..<2 {
            let service = w.service(hook: { point, record in
                XCTAssertEqual(record.id, restoreRecord.id, "A blocked target must not create another transfer")
                if point == .beforeCleanup {
                    failedCleanups += 1
                    throw Interrupted()
                }
                XCTFail("No new preparation or successful cleanup is allowed while the old deletion fails")
            }, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
            let choice = try XCTUnwrap(service.replacementChoice(for: item(local), destinationURL: external))
            XCTAssertEqual(choice.versionComparison, .unrecognized)
            do {
                _ = try await service.moveAndLink(appToMove: item(local), destinationURL: external,
                    isRunning: false, replacementChoice: choice, progressHandler: nil)
                XCTFail("The directly occupied target must wait for its existing cleanup")
            } catch {
                XCTAssertEqual((error as NSError).userInfo[NSFilePathErrorKey] as? String, recordURL.path)
                XCTAssertTrue(error.localizedDescription.contains(external.path))
                XCTAssertTrue(error.localizedDescription.contains(restoreRecord.id.uuidString))
            }
            XCTAssertEqual(try w.store.records().map(\.id), [restoreRecord.id])
            XCTAssertTrue(try localIdentity.matchesFilesystemObject(DataPathIdentity.capture(local)))
            XCTAssertTrue(try externalIdentity.matchesFilesystemObject(DataPathIdentity.capture(external)))
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), localFingerprint)
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: external), externalFingerprint)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: w.local.path).sorted(), localNames)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: w.external.path).sorted(), externalNames)
            let oldSource = try XCTUnwrap(w.store.record(restoreRecord.id).cleanupItems.first { $0.role == .source })
            XCTAssertFalse(oldSource.completed)
            XCTAssertNotNil(oldSource.lastError)
        }
        XCTAssertEqual(failedCleanups, 2)

        let otherTarget = w.external.appendingPathComponent("OtherTarget.app")
        let independent = try await w.service(hook: { point, record in
            if record.id == restoreRecord.id && point == .beforeCleanup {
                failedCleanups += 1
                throw Interrupted()
            }
        }).moveAndLink(appToMove: item(local), destinationURL: otherTarget, isRunning: false, progressHandler: nil)
        XCTAssertTrue(independent.isComplete, independent.warnings.joined(separator: "\n"))
        XCTAssertEqual(failedCleanups, 2, "A different destination must not attempt the unrelated old cleanup")
        XCTAssertEqual(try w.store.record(restoreRecord.id).successorActivation?.path, otherTarget.path)
        XCTAssertTrue(try externalIdentity.matchesFilesystemObject(DataPathIdentity.capture(external)))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: external), externalFingerprint)
        let currentIdentity = try DataPathIdentity.capture(otherTarget)
        let currentFingerprint = try SignatureSnapshot.fingerprint(of: otherTarget)
        let stillPending = try await w.service(hook: { point, _ in
            if point == .beforeCleanup { throw Interrupted() }
        }, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL)).retryTransfer(operationID: restoreRecord.id)
        XCTAssertFalse(stillPending.isComplete)
        XCTAssertTrue(stillPending.pendingTasks.contains { $0.kind == .oldCopy && $0.path == external.path })
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: external), externalFingerprint)
        let completed = try await w.service().retryTransfer(operationID: restoreRecord.id)
        XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
        XCTAssertTrue(try currentIdentity.matchesFilesystemObject(DataPathIdentity.capture(otherTarget)))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: otherTarget), currentFingerprint)
        XCTAssertEqual(try payload(otherTarget), "confirmed application")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testStaleReplacementChoiceDoesNotStartPendingTargetCleanup() async throws {
        for (replacingSource, leaveReplacement) in [(true, true), (false, true), (false, false)] {
            let w = try Workspace(); defer { w.cleanup() }
            let (local, external, restoreRecord) = try await pendingRestoreWithRetainedExternalCopy(in: w)
            let choice = try XCTUnwrap(w.service().replacementChoice(for: item(local), destinationURL: external))
            XCTAssertEqual(choice.versionComparison, .unrecognized)
            let changed = replacingSource ? local : external
            let saved = w.root.appendingPathComponent("SavedSelection.app")
            let selectedIdentity = try DataPathIdentity.capture(changed)
            let selectedFingerprint = try SignatureSnapshot.fingerprint(of: changed)
            try FileManager.default.moveItem(at: changed, to: saved)
            if leaveReplacement { try makeApp(changed, payload: "independent installation", version: "beta") }
            let recordURL = w.store.directoryURL.appendingPathComponent(restoreRecord.id.uuidString + ".plist")
            let recordBytes = try Data(contentsOf: recordURL)
            do {
                _ = try await w.service(hook: { _, _ in XCTFail("A stale confirmation cannot authorize old cleanup or new preparation") })
                    .moveAndLink(appToMove: item(local), destinationURL: external,
                                 isRunning: false, replacementChoice: choice, progressHandler: nil)
                XCTFail("The replacement choice no longer names both selected objects")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: recordURL), recordBytes)
            XCTAssertEqual(try w.store.records().map(\.id), [restoreRecord.id])
            XCTAssertTrue(try selectedIdentity.matchesFilesystemObject(DataPathIdentity.capture(saved)))
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: saved), selectedFingerprint)
            if leaveReplacement { XCTAssertEqual(try payload(changed), "independent installation") }
            else { XCTAssertFalse(try AppTransferStore.exists(changed)) }
            XCTAssertEqual(try payload(replacingSource ? external : local), "confirmed application")
        }
    }

    func testPendingTargetCleanupRejectsSourceAndTargetReplacementBeforeDeletion() async throws {
        for replacingSource in [true, false] {
            let w = try Workspace(); defer { w.cleanup() }
            let (local, external, restoreRecord) = try await pendingRestoreWithRetainedExternalCopy(in: w)
            let changed = replacingSource ? local : external
            let saved = w.root.appendingPathComponent("SavedSelection.app")
            let selectedIdentity = try DataPathIdentity.capture(changed)
            let selectedFingerprint = try SignatureSnapshot.fingerprint(of: changed)
            let unchanged = replacingSource ? external : local
            let unchangedFingerprint = try SignatureSnapshot.fingerprint(of: unchanged)
            var replacements = 0
            let service = w.service(hook: { point, record in
                XCTAssertEqual(record.id, restoreRecord.id, "The preflight must finish before a new transfer starts")
                if point == .beforeCleanup {
                    replacements += 1
                    try FileManager.default.moveItem(at: changed, to: saved)
                    try self.makeApp(changed, payload: "independent installation", version: "beta")
                }
            })
            let choice = try XCTUnwrap(service.replacementChoice(for: item(local), destinationURL: external))
            XCTAssertEqual(choice.versionComparison, .unrecognized)
            do {
                _ = try await service.moveAndLink(appToMove: item(local), destinationURL: external,
                    isRunning: false, replacementChoice: choice, progressHandler: nil)
                XCTFail("Changing a selected root during cleanup must stop the new transfer")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(restoreRecord.id.uuidString))
            }
            XCTAssertEqual(replacements, 1)
            XCTAssertEqual(try w.store.records().map(\.id), [restoreRecord.id])
            XCTAssertFalse(try XCTUnwrap(w.store.record(restoreRecord.id).cleanupItems.first { $0.role == .source }).completed)
            XCTAssertTrue(try selectedIdentity.matchesFilesystemObject(DataPathIdentity.capture(saved)))
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: saved), selectedFingerprint)
            XCTAssertEqual(try payload(changed), "independent installation")
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: unchanged), unchangedFingerprint)
        }
    }

    func testPendingTargetCleanupRejectsChangedSourceOrReappearingTargetAfterDeletion() async throws {
        for replacingSource in [true, false] {
            let w = try Workspace(); defer { w.cleanup() }
            let (local, external, restoreRecord) = try await pendingRestoreWithRetainedExternalCopy(in: w)
            let localIdentity = try DataPathIdentity.capture(local)
            let localFingerprint = try SignatureSnapshot.fingerprint(of: local)
            let saved = w.root.appendingPathComponent("SavedActive.app")
            let changed = replacingSource ? local : external
            var replacements = 0
            let service = w.service(hook: { point, record in
                XCTAssertEqual(record.id, restoreRecord.id, "No new record may be created after a preflight conflict")
                if point == .afterCleanup {
                    replacements += 1
                    XCTAssertFalse(try AppTransferStore.exists(external))
                    if replacingSource { try FileManager.default.moveItem(at: local, to: saved) }
                    try self.makeApp(changed, payload: "appeared after deletion", version: "beta")
                }
            })
            let choice = try XCTUnwrap(service.replacementChoice(for: item(local), destinationURL: external))
            XCTAssertEqual(choice.versionComparison, .unrecognized)
            do {
                _ = try await service.moveAndLink(appToMove: item(local), destinationURL: external,
                    isRunning: false, replacementChoice: choice, progressHandler: nil)
                XCTFail("A consumed target does not authorize another source or a reappearing target")
            } catch {
                XCTAssertEqual((error as NSError).userInfo[NSFilePathErrorKey] as? String, changed.path)
            }
            XCTAssertEqual(replacements, 1)
            XCTAssertEqual(try w.store.records().map(\.id), [restoreRecord.id])
            let pending = try w.store.record(restoreRecord.id)
            XCTAssertTrue(try XCTUnwrap(pending.cleanupItems.first { $0.role == .source }).completed)
            XCTAssertNil(pending.successorActivation)
            XCTAssertEqual(try payload(changed), "appeared after deletion")
            XCTAssertTrue(try localIdentity.matchesFilesystemObject(DataPathIdentity.capture(replacingSource ? saved : local)))
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: replacingSource ? saved : local), localFingerprint)
            let replacementFingerprint = try SignatureSnapshot.fingerprint(of: changed)
            let preservedReplacement = replacingSource ? w.root.appendingPathComponent("IndependentActive.app") : external
            if replacingSource {
                let blocked = try await w.service().retryTransfer(operationID: restoreRecord.id)
                XCTAssertFalse(blocked.isComplete)
                XCTAssertEqual(try SignatureSnapshot.fingerprint(of: changed), replacementFingerprint)
                try FileManager.default.moveItem(at: local, to: preservedReplacement)
                try FileManager.default.moveItem(at: saved, to: local)
            }
            let completed = try await w.service(hook: { point, _ in
                if ![.committed, .beforeCleanup, .afterCleanup].contains(point) {
                    XCTFail("Finishing the original record must not repeat the transfer")
                }
            }, storeOverride: AppTransferStore(directoryURL: w.store.directoryURL)).retryTransfer(operationID: restoreRecord.id)
            XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), localFingerprint)
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: preservedReplacement), replacementFingerprint)
            XCTAssertTrue(try w.store.records().isEmpty)
            try assertNoStages(w)
        }
    }

    func testPendingTargetCleanupRequiresDurableRemovalBeforeFreshMigration() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let (local, external, restoreRecord) = try await pendingRestoreWithRetainedExternalCopy(in: w)
        let localIdentity = try DataPathIdentity.capture(local)
        let localFingerprint = try SignatureSnapshot.fingerprint(of: local)
        var syncAttempts = 0
        let service = w.service(hook: { _, record in
            XCTAssertEqual(record.id, restoreRecord.id, "A failed cleanup barrier must not start another transfer")
        }, synchronizeCleanupParent: { parent in
            if parent.standardizedFileURL.path == w.external.standardizedFileURL.path {
                syncAttempts += 1
                throw POSIXError(.EIO)
            }
            try DurableFileIO.syncDirectory(at: parent)
        })
        let choice = try XCTUnwrap(service.replacementChoice(for: item(local), destinationURL: external))
        XCTAssertEqual(choice.versionComparison, .unrecognized)
        do {
            _ = try await service.moveAndLink(appToMove: item(local), destinationURL: external,
                isRunning: false, replacementChoice: choice, progressHandler: nil)
            XCTFail("Deletion must cross its directory synchronization barrier before the target is reused")
        } catch { XCTAssertTrue(error.localizedDescription.contains(restoreRecord.id.uuidString)) }
        XCTAssertEqual(syncAttempts, 1)
        XCTAssertFalse(try AppTransferStore.exists(external))
        XCTAssertTrue(try localIdentity.matchesFilesystemObject(DataPathIdentity.capture(local)))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: local), localFingerprint)
        XCTAssertEqual(try w.store.records().map(\.id), [restoreRecord.id])
        XCTAssertFalse(try XCTUnwrap(w.store.record(restoreRecord.id).cleanupItems.first { $0.role == .source }).completed)
        do {
            _ = try await w.service(hook: { _, _ in XCTFail("A prior call's target disappearance cannot consume this stale choice") })
                .moveAndLink(appToMove: item(local), destinationURL: external,
                             isRunning: false, replacementChoice: choice, progressHandler: nil)
            XCTFail("A replacement choice cannot be reused after its target disappeared")
        } catch {}
        let moved = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
            .moveAndLink(appToMove: item(local), destinationURL: external, isRunning: false, progressHandler: nil)
        XCTAssertTrue(moved.isComplete, moved.warnings.joined(separator: "\n"))
        let pending = try w.store.record(restoreRecord.id)
        XCTAssertTrue(try XCTUnwrap(pending.cleanupItems.first { $0.role == .source }).completed)
        XCTAssertEqual(pending.successorActivation?.path, external.path)
        let activeIdentity = try DataPathIdentity.capture(external)
        let activeFingerprint = try SignatureSnapshot.fingerprint(of: external)
        let completed = try await w.service().retryTransfer(operationID: restoreRecord.id)
        XCTAssertTrue(completed.isComplete, completed.warnings.joined(separator: "\n"))
        XCTAssertTrue(try activeIdentity.matchesFilesystemObject(DataPathIdentity.capture(external)))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: external), activeFingerprint)
        XCTAssertEqual(try payload(external), "confirmed application")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testCreationWithoutDurableIdentityCanBeCancelledWithoutClaimingOrDeletingArtifact() async throws {
        for interruption in [AppTransferHooks.Checkpoint.stageCreated, .candidateCreated] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
            try makeApp(source, payload: "keep")
            do {
                _ = try await w.service(hook: { point, _ in if point == interruption { throw Interrupted() } })
                    .moveAndLink(appToMove: item(source), destinationURL: target, isRunning: false, progressHandler: nil)
                XCTFail("Expected creation interruption")
            } catch is Interrupted {}
            let pending = try XCTUnwrap(w.store.records().first)
            let artifact = interruption == .stageCreated ? URL(fileURLWithPath: pending.stagePath) : pending.candidateURL
            XCTAssertTrue(try AppTransferStore.exists(artifact))
            let cancelled = try await w.service().cancelTransfer(operationID: pending.id)
            XCTAssertFalse(cancelled.isSwitchComplete)
            XCTAssertTrue(cancelled.pendingTasks.contains { $0.kind == .unclaimedArtifact })
            XCTAssertTrue(try AppTransferStore.exists(artifact))
            XCTAssertEqual(try payload(source), "keep")
            XCTAssertFalse(try XCTUnwrap(w.store.records().first).canCancel)
            let next = try await w.service().moveAndLink(appToMove: item(source), destinationURL: target,
                                                        isRunning: false, progressHandler: nil)
            XCTAssertTrue(next.isComplete, "Cancelled attempts must release their path reservation")
            XCTAssertTrue(try AppTransferStore.exists(artifact))
        }
    }

    func testCancelPublishedReplacementRestoresPreviousExternalVersion() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source, payload: "new", version: "2")
        try makeApp(target, payload: "old", version: "1")
        let oldIdentity = try DataPathIdentity.capture(target)
        do {
            _ = try await w.service(hook: { point, _ in if point == .destinationPublished { throw Interrupted() } })
                .moveAndLink(appToMove: item(source, status: AppStatus.pendingMoveOut), destinationURL: target,
                             isRunning: false, progressHandler: nil)
            XCTFail("Expected interruption before the local entry switches")
        } catch is Interrupted {}
        let pending = try XCTUnwrap(w.store.records().first)
        XCTAssertFalse(pending.isSwitchComplete)
        _ = try await w.service().cancelTransfer(operationID: pending.id)
        XCTAssertEqual(try DataPathIdentity.capture(target), oldIdentity)
        XCTAssertEqual(try payload(target), "old")
        XCTAssertEqual(try payload(source), "new")
        XCTAssertTrue(try w.store.records().isEmpty)
    }

    func testReplacementOfRetainedCopyIsNeverDeletedOnRetry() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.external.appendingPathComponent("App.app"), target = w.local.appendingPathComponent("App.app")
        try makeApp(source, payload: "original")
        let partial = try await w.service(hook: { point, _ in if point == .beforeCleanup { throw Interrupted() } })
            .moveBack(app: item(source), localDestinationURL: target, progressHandler: nil)
        let movedAway = w.external.appendingPathComponent("Saved.app")
        try FileManager.default.moveItem(at: source, to: movedAway)
        try makeApp(source, payload: "replacement")
        let result = try await w.service().retryTransfer(operationID: partial.transferResult.operationID)
        XCTAssertTrue(result.isSwitchComplete)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(try payload(source), "replacement")
        XCTAssertEqual(try payload(movedAway), "original")
        XCTAssertEqual(try payload(target), "original")
    }

    func testOwnUpdateProtectionIsRemovedOnRestoreAndUnknownUserLockIsPreserved() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source, sparkle: true)
        let moved = try await w.service().moveAndLink(appToMove: item(source), destinationURL: target,
                                                    isRunning: false, progressHandler: nil)
        XCTAssertTrue(moved.isComplete)
        XCTAssertNotEqual(try SignatureSnapshot.info(at: target).st_flags & UInt32(UF_IMMUTABLE), 0)
        let restored = try await w.service().moveBack(app: item(target), localDestinationURL: source, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
        for url in try SignatureSnapshot.items(in: source) {
            XCTAssertEqual(try SignatureSnapshot.info(at: url).st_flags & UInt32(UF_IMMUTABLE), 0)
        }
        let userLocked = w.local.appendingPathComponent("UserLocked.app")
        try makeApp(userLocked)
        let lockedFile = userLocked.appendingPathComponent("Contents/Resources/payload")
        let priorFlags = try SignatureSnapshot.info(at: lockedFile).st_flags
        XCTAssertEqual(lchflags(lockedFile.path, priorFlags | UInt32(UF_IMMUTABLE)), 0)
        do {
            _ = try await w.service().moveAndLink(appToMove: item(userLocked), destinationURL: w.external.appendingPathComponent("UserLocked.app"),
                                                isRunning: false, progressHandler: nil)
            XCTFail("Unknown locked metadata must not be silently rewritten")
        } catch {}
        XCTAssertNotEqual(try SignatureSnapshot.info(at: lockedFile).st_flags & UInt32(UF_IMMUTABLE), 0)
    }

    func testDamagedUnrelatedProtectionRecordsDoNotBlockRoundTripOrSigning() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let protection = AppUpdateProtectionStore(transferStore: w.store)
        let damagedApp = w.local.appendingPathComponent("Damaged.app")
        try makeApp(damagedApp)
        try protection.protect(damagedApp)
        let damagedRecord = try XCTUnwrap(protection.captureForExchange(at: damagedApp))
        let damaged = try writeDamagedProtectionRecord(in: w, path: damagedRecord.path,
            identity: damagedRecord.identity, id: damagedRecord.id)

        let protectedApp = w.local.appendingPathComponent("Protected.app")
        try makeSignableApp(protectedApp, identifier: "example.protected")
        try protection.protect(protectedApp)
        let oldProtectedIdentity = try DataPathIdentity.capture(protectedApp)
        let signedProtected = try await signer(w).sign(appURL: protectedApp, bundleIdentifier: "example.protected")
        XCTAssertTrue(signedProtected.committed)
        XCTAssertNil(signedProtected.cleanupWarning)
        XCTAssertFalse(try oldProtectedIdentity.matchesFilesystemObject(DataPathIdentity.capture(protectedApp)))
        XCTAssertNotEqual(try SignatureSnapshot.info(at: protectedApp).st_flags & UInt32(UF_IMMUTABLE), 0)
        let rebound = try XCTUnwrap(protection.captureForExchange(at: protectedApp))
        XCTAssertTrue(try rebound.identity.matchesFilesystemObject(DataPathIdentity.capture(protectedApp)))

        let local = w.local.appendingPathComponent("Independent.app"), external = w.external.appendingPathComponent("Independent.app")
        try makeSignableApp(local, identifier: "example.independent.protection")
        let moved = try await w.service().moveAndLink(appToMove: item(local), destinationURL: external,
            isRunning: false, progressHandler: nil)
        XCTAssertTrue(moved.isComplete, moved.pendingMessage ?? "")
        let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
        let signed = try await signer(w).sign(appURL: local, bundleIdentifier: "example.independent.protection")
        XCTAssertTrue(signed.committed)
        XCTAssertNil(signed.cleanupWarning)
        XCTAssertEqual(try payload(local), "payload")
        XCTAssertFalse(try AppTransferStore.exists(external))
        XCTAssertTrue(try w.store.records().isEmpty)
        XCTAssertTrue(try SignatureOperationStore(backupDirectoryURL: w.root.appendingPathComponent("SignatureBackups")).records().isEmpty)
        XCTAssertEqual(try Data(contentsOf: damaged.url), damaged.bytes)
        let inspection = try w.service().pendingTransferInspection()
        XCTAssertEqual(inspection.issues.map(\.url), [damaged.url])
        XCTAssertEqual(inspection.issues.first?.knownPaths, [damagedApp.path])
        XCTAssertFalse(inspection.issues.isEmpty, "Keep incomplete-operation diagnostics for automatic maintenance")
        try assertNoStages(w)
    }

    func testUnrelatedDamagedProtectionPreservesUserLocksThroughRealTransferCancellation() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let protection = AppUpdateProtectionStore(transferStore: w.store)
        let damaged = try writeDamagedProtectionRecord(in: w,
            path: w.root.appendingPathComponent("Unrelated.app").path, identity: nil)
        let source = w.local.appendingPathComponent("Protected.app"), target = w.external.appendingPathComponent("Protected.app")
        try makeApp(source)
        let userLocked = source.appendingPathComponent("Contents/Resources/payload")
        let userFlags = try SignatureSnapshot.info(at: userLocked).st_flags | UInt32(UF_IMMUTABLE)
        XCTAssertEqual(lchflags(userLocked.path, userFlags), 0)
        try protection.protect(source)
        let token = try XCTUnwrap(protection.captureForExchange(at: source))
        XCTAssertFalse(token.entries.contains { $0.relativePath == "Contents/Resources/payload" })
        var sawSuspendedProtection = false
        do {
            _ = try await w.service(hook: { point, _ in
                if point == .stageCreated {
                    sawSuspendedProtection = true
                    XCTAssertEqual(try SignatureSnapshot.info(at: source).st_flags & UInt32(UF_IMMUTABLE), 0)
                    XCTAssertEqual(try SignatureSnapshot.info(at: userLocked).st_flags, userFlags)
                    throw Interrupted()
                }
            }).moveAndLink(appToMove: item(source), destinationURL: target, isRunning: false, progressHandler: nil)
            XCTFail("Expected the controlled interruption after protection suspension")
        } catch is Interrupted {}
        XCTAssertTrue(sawSuspendedProtection)
        let record = try XCTUnwrap(w.store.records().first)
        _ = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL)).cancelTransfer(operationID: record.id)
        XCTAssertNotEqual(try SignatureSnapshot.info(at: source).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(try SignatureSnapshot.info(at: userLocked).st_flags, userFlags)
        XCTAssertEqual(try protection.captureForExchange(at: source), token)
        XCTAssertFalse(try AppTransferStore.exists(target))
        XCTAssertEqual(try Data(contentsOf: damaged.url), damaged.bytes)
    }

    func testDamagedProtectionAssociationsRejectRelatedMovesAndSigningBeforeIntent() async throws {
        for association in ["path", "identity", "replaced-installation"] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
            try makeSignableApp(source, identifier: "example.related.protection")
            let identity = try DataPathIdentity.capture(source)
            if association == "replaced-installation" {
                try FileManager.default.moveItem(at: source, to: w.local.appendingPathComponent("PreviousInstallation.app"))
                try makeSignableApp(source, identifier: "example.related.protection")
                XCTAssertFalse(try identity.matchesFilesystemObject(DataPathIdentity.capture(source)))
            }
            let lockedFile = source.appendingPathComponent("Contents/Resources/payload")
            let flags = try SignatureSnapshot.info(at: lockedFile).st_flags | UInt32(UF_IMMUTABLE)
            XCTAssertEqual(lchflags(lockedFile.path, flags), 0)
            let damaged = try writeDamagedProtectionRecord(in: w,
                path: association == "identity" ? nil : source.path,
                identity: association == "path" ? nil : identity)
            let before = try SignatureSnapshot.fingerprint(of: source)
            do {
                _ = try await w.service().moveAndLink(appToMove: item(source), destinationURL: target,
                    isRunning: false, progressHandler: nil)
                XCTFail("A damaged \(association) association must not authorize an application transfer")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(damaged.url.path), error.localizedDescription)
            }
            do {
                _ = try await signer(w).sign(appURL: source, bundleIdentifier: "example.related.protection")
                XCTFail("A damaged \(association) association must not authorize signing")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(damaged.url.path), error.localizedDescription)
            }
            XCTAssertTrue(try w.store.records().isEmpty, "A preflight conflict must not leave new transfer intent")
            XCTAssertTrue(try SignatureOperationStore(backupDirectoryURL: w.root.appendingPathComponent("SignatureBackups")).records().isEmpty)
            XCTAssertFalse(try AppTransferStore.exists(target))
            XCTAssertEqual(try SignatureSnapshot.info(at: lockedFile).st_flags, flags)
            XCTAssertEqual(try SignatureSnapshot.fingerprint(of: source), before)
            XCTAssertEqual(try Data(contentsOf: damaged.url), damaged.bytes)
            XCTAssertEqual(try w.service().pendingTransferInspection().issues.map(\.url), [damaged.url])
            try assertNoStages(w)
        }
    }

    func testCancellationCannotLoseKnownSuspendedProtectionWhenItsRecordBecomesUnreadable() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        let protection = AppUpdateProtectionStore(transferStore: w.store)
        try protection.protect(source)
        let token = try XCTUnwrap(protection.captureForExchange(at: source))
        let protectionURL = w.store.directoryURL.appendingPathComponent("update-protection")
            .appendingPathComponent(token.id.uuidString + ".plist")
        let originalRecord = try Data(contentsOf: protectionURL)
        do {
            _ = try await w.service(hook: { point, _ in if point == .copied { throw Interrupted() } })
                .moveAndLink(appToMove: item(source), destinationURL: target, isRunning: false, progressHandler: nil)
            XCTFail("Expected a pause while the source's owned protection is suspended")
        } catch is Interrupted {}
        let pending = try XCTUnwrap(w.store.records().first)
        XCTAssertTrue(pending.sourceProtectionSuspended)
        XCTAssertEqual(try SignatureSnapshot.info(at: source).st_flags & UInt32(UF_IMMUTABLE), 0)
        let damaged = Data("record truncated after source suspension".utf8)
        try damaged.write(to: protectionURL)
        do {
            _ = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
                .cancelTransfer(operationID: pending.id)
            XCTFail("An operation that actually suspended protection cannot treat an unreadable provenance file as no protection")
        } catch {}
        XCTAssertNotEqual(try w.store.record(pending.id).phase, .cancelled)
        XCTAssertEqual(try Data(contentsOf: protectionURL), damaged)
        XCTAssertEqual(try payload(source), "payload")
        try originalRecord.write(to: protectionURL)
        _ = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
            .cancelTransfer(operationID: pending.id)
        XCTAssertNotEqual(try SignatureSnapshot.info(at: source).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(try protection.captureForExchange(at: source), token)
        XCTAssertFalse(try AppTransferStore.exists(target))
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testProtectedReplacementCancellationRetainsJournalUntilOriginalDestinationRecordIsReadable() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source, payload: "new application", version: "2")
        try makeApp(target, payload: "old application", version: "1")
        let protection = AppUpdateProtectionStore(transferStore: w.store)
        try protection.protect(target)
        let token = try XCTUnwrap(protection.captureForExchange(at: target))
        let oldIdentity = try DataPathIdentity.capture(target)
        let recordURL = w.store.directoryURL.appendingPathComponent("update-protection")
            .appendingPathComponent(token.id.uuidString + ".plist")
        let originalRecord = try Data(contentsOf: recordURL)
        let oldFlags = try flagSnapshot(target)
        do {
            _ = try await w.service(hook: { point, _ in
                if point == .destinationPublished { throw Interrupted() }
            }).moveAndLink(appToMove: item(source, status: AppStatus.pendingMoveOut), destinationURL: target,
                isRunning: false, progressHandler: nil)
            XCTFail("Expected a pause after the replacement was published but before the local entry switched")
        } catch is Interrupted {}
        let pending = try XCTUnwrap(w.store.records().first)
        XCTAssertEqual(pending.protectionRecovery?.existingDestination, token)
        XCTAssertNil(pending.protectionRecovery?.source)
        XCTAssertEqual(try payload(target), "new application")
        XCTAssertTrue(try oldIdentity.matchesFilesystemObject(DataPathIdentity.capture(pending.candidateURL)))
        let damaged = Data("old destination protection record fully truncated".utf8)
        try damaged.write(to: recordURL)
        do {
            _ = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
                .cancelTransfer(operationID: pending.id)
            XCTFail("The known original destination protection must not disappear from cancellation obligations")
        } catch {}
        XCTAssertNotEqual(try w.store.record(pending.id).phase, .cancelled)
        XCTAssertEqual(try w.store.record(pending.id).protectionRecovery?.existingDestination, token)
        XCTAssertTrue(try oldIdentity.matchesFilesystemObject(DataPathIdentity.capture(target)))
        XCTAssertEqual(try payload(target), "old application")
        XCTAssertEqual(try payload(source), "new application")
        XCTAssertEqual(try Data(contentsOf: recordURL), damaged)
        XCTAssertEqual(try SignatureSnapshot.info(at: target).st_flags & UInt32(UF_IMMUTABLE), 0,
                       "No protection bits may be guessed from an unreadable authority file")
        try originalRecord.write(to: recordURL)
        _ = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
            .cancelTransfer(operationID: pending.id)
        XCTAssertEqual(try flagSnapshot(target), oldFlags)
        XCTAssertEqual(try protection.captureForExchange(at: target), token)
        XCTAssertEqual(try payload(source), "new application")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testProtectionRecoveryIntentWriteFailureLeavesBothOriginalApplicationsLocked() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
        try makeApp(source, payload: "new", version: "2")
        try makeApp(target, payload: "old", version: "1")
        let protection = AppUpdateProtectionStore(transferStore: w.store)
        try protection.protect(source)
        try protection.protect(target)
        let sourceToken = try XCTUnwrap(protection.captureForExchange(at: source))
        let destinationToken = try XCTUnwrap(protection.captureForExchange(at: target))
        let sourceFlags = try flagSnapshot(source), targetFlags = try flagSnapshot(target)
        var attemptedIntent = false
        let failingStore = AppTransferStore(directoryURL: w.store.directoryURL, beforeRecordWrite: { record in
            attemptedIntent = true
            XCTAssertEqual(record.protectionRecovery?.source, sourceToken)
            XCTAssertEqual(record.protectionRecovery?.existingDestination, destinationToken)
            XCTAssertEqual(try self.flagSnapshot(source), sourceFlags)
            XCTAssertEqual(try self.flagSnapshot(target), targetFlags)
            throw POSIXError(.EIO)
        })
        do {
            _ = try await w.service(storeOverride: failingStore).moveAndLink(
                appToMove: item(source, status: AppStatus.pendingMoveOut), destinationURL: target,
                isRunning: false, progressHandler: nil)
            XCTFail("No flags may change when the initial recovery intent cannot be persisted")
        } catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
        XCTAssertTrue(attemptedIntent)
        XCTAssertEqual(try flagSnapshot(source), sourceFlags)
        XCTAssertEqual(try flagSnapshot(target), targetFlags)
        XCTAssertEqual(try protection.captureForExchange(at: source), sourceToken)
        XCTAssertEqual(try protection.captureForExchange(at: target), destinationToken)
        XCTAssertEqual(try payload(source), "new")
        XCTAssertEqual(try payload(target), "old")
        XCTAssertTrue(try w.store.records().isEmpty)
        try assertNoStages(w)
    }

    func testDurableProtectionTokensRestoreBothSidesAfterUnlockWithoutAnyStatusSave() async throws {
        for interruption in [AppTransferHooks.Checkpoint.sourceProtectionSuspended, .destinationProtectionSuspended] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
            try makeApp(source, payload: "new", version: "2")
            try makeApp(target, payload: "old", version: "1")
            let protection = AppUpdateProtectionStore(transferStore: w.store)
            let userLockedFiles = [source, target].map { $0.appendingPathComponent("Contents/Resources/payload") }
            for file in userLockedFiles {
                let flags = try SignatureSnapshot.info(at: file).st_flags | UInt32(UF_IMMUTABLE)
                XCTAssertEqual(lchflags(file.path, flags), 0)
            }
            try protection.protect(source)
            try protection.protect(target)
            let sourceToken = try XCTUnwrap(protection.captureForExchange(at: source))
            let destinationToken = try XCTUnwrap(protection.captureForExchange(at: target))
            let sourceFlags = try flagSnapshot(source), targetFlags = try flagSnapshot(target)
            var failWrites = false
            var failedWrites = 0
            var observedBoundary = false
            let failingStore = AppTransferStore(directoryURL: w.store.directoryURL, beforeRecordWrite: { _ in
                if failWrites { failedWrites += 1; throw POSIXError(.EIO) }
            })
            do {
                _ = try await w.service(hook: { point, record in
                    if point == interruption {
                        observedBoundary = true
                        let durable = try w.store.record(record.id)
                        XCTAssertEqual(durable.protectionRecovery?.source, sourceToken)
                        XCTAssertEqual(durable.protectionRecovery?.existingDestination, destinationToken)
                        XCTAssertFalse(durable.sourceProtectionSuspended, "The test must precede the former after-unlock status save")
                        XCTAssertEqual(try SignatureSnapshot.info(at: source).st_flags & UInt32(UF_IMMUTABLE), 0)
                        let expectedTarget: UInt32 = point == .destinationProtectionSuspended ? 0 : UInt32(UF_IMMUTABLE)
                        XCTAssertEqual(try SignatureSnapshot.info(at: target).st_flags & UInt32(UF_IMMUTABLE), expectedTarget)
                        for file in userLockedFiles {
                            XCTAssertNotEqual(try SignatureSnapshot.info(at: file).st_flags & UInt32(UF_IMMUTABLE), 0)
                        }
                        failWrites = true
                        throw Interrupted()
                    }
                }, storeOverride: failingStore).moveAndLink(
                    appToMove: item(source, status: AppStatus.pendingMoveOut), destinationURL: target,
                    isRunning: false, progressHandler: nil)
                XCTFail("Expected interruption with no successful record write after the flag changes")
            } catch is Interrupted {}
            XCTAssertTrue(observedBoundary)
            XCTAssertGreaterThan(failedWrites, 0, "Even error handling must be unable to persist an after-unlock status")
            let pending = try XCTUnwrap(w.store.records().first)
            XCTAssertFalse(pending.sourceProtectionSuspended)
            XCTAssertEqual(pending.protectionRecovery?.source, sourceToken)
            XCTAssertEqual(pending.protectionRecovery?.existingDestination, destinationToken)
            _ = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
                .cancelTransfer(operationID: pending.id)
            XCTAssertEqual(try flagSnapshot(source), sourceFlags)
            XCTAssertEqual(try flagSnapshot(target), targetFlags)
            XCTAssertEqual(try payload(source), "new")
            XCTAssertEqual(try payload(target), "old")
            XCTAssertTrue(try w.store.records().isEmpty)
            try assertNoStages(w)
        }
    }

    func testLegacyV3RecordsWithoutProtectionTokensRemainCancellable() async throws {
        for protected in [false, true] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app"), target = w.external.appendingPathComponent("App.app")
            try makeApp(source, payload: "new", version: "2")
            try makeApp(target, payload: "old", version: "1")
            let protection = AppUpdateProtectionStore(transferStore: w.store)
            if protected {
                try protection.protect(source)
                try protection.protect(target)
            }
            let sourceFlags = try flagSnapshot(source), targetFlags = try flagSnapshot(target)
            do {
                _ = try await w.service(hook: { point, _ in if point == .copied { throw Interrupted() } })
                    .moveAndLink(appToMove: item(source, status: AppStatus.pendingMoveOut), destinationURL: target,
                        isRunning: false, progressHandler: nil)
                XCTFail("Expected a cancellable transfer")
            } catch is Interrupted {}
            let record = try XCTUnwrap(w.store.records().first)
            let recordURL = w.store.directoryURL.appendingPathComponent(record.id.uuidString + ".plist")
            var legacy = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: recordURL), format: nil) as? [String: Any])
            legacy.removeValue(forKey: "protectionRecovery")
            try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0).write(to: recordURL)
            XCTAssertNil(try w.store.record(record.id).protectionRecovery)
            _ = try await w.service(storeOverride: AppTransferStore(directoryURL: w.store.directoryURL))
                .cancelTransfer(operationID: record.id)
            XCTAssertEqual(try flagSnapshot(source), sourceFlags)
            XCTAssertEqual(try flagSnapshot(target), targetFlags)
            XCTAssertEqual(try payload(source), "new")
            XCTAssertEqual(try payload(target), "old")
            XCTAssertTrue(try w.store.records().isEmpty)
            try assertNoStages(w)
        }
    }

    func testProtectionRelocationAndForgetKeepPerRecordFailureBoundaries() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let protection = AppUpdateProtectionStore(transferStore: w.store)
        let unrelated = try writeDamagedProtectionRecord(in: w,
            path: w.root.appendingPathComponent("Other.app").path, identity: nil)
        let source = w.local.appendingPathComponent("App.app"), moved = w.local.appendingPathComponent("Moved.app")
        try makeApp(source)
        try protection.protect(source)
        let token = try XCTUnwrap(protection.captureForExchange(at: source))
        try protection.suspendForExchange(token, at: source)
        try FileManager.default.moveItem(at: source, to: moved)
        try protection.commitSameObjectMove(token, to: moved)
        XCTAssertNotEqual(try SignatureSnapshot.info(at: moved).st_flags & UInt32(UF_IMMUTABLE), 0)
        let rebound = try XCTUnwrap(protection.captureForExchange(at: moved))
        XCTAssertEqual(rebound.id, token.id)
        XCTAssertEqual(rebound.path, moved.path)
        XCTAssertEqual(try Data(contentsOf: unrelated.url), unrelated.bytes)

        let related = try writeDamagedProtectionRecord(in: w, path: rebound.path, identity: rebound.identity, id: rebound.id)
        XCTAssertThrowsError(try protection.suspendForExchange(rebound, at: moved))
        XCTAssertThrowsError(try protection.commitSameObjectMove(rebound, to: moved))
        XCTAssertThrowsError(try protection.commitExchange(rebound, to: moved))
        XCTAssertThrowsError(try protection.forget(path: moved.path, identity: rebound.identity))
        XCTAssertEqual(try Data(contentsOf: related.url), related.bytes)
        XCTAssertNotEqual(try SignatureSnapshot.info(at: moved).st_flags & UInt32(UF_IMMUTABLE), 0)

        let truncated = Data("unreadable record with no association fields".utf8)
        try truncated.write(to: related.url)
        XCTAssertThrowsError(try protection.commitSameObjectMove(rebound, to: moved), "Explicit id recovery cannot ignore an unreadable file")
        XCTAssertThrowsError(try protection.commitExchange(rebound, to: moved))
        try protection.forget(path: moved.path, identity: rebound.identity)
        XCTAssertEqual(try Data(contentsOf: related.url), truncated, "An unknown bad record is retained, never silently forgotten")

        // Restore only this fixture's authentic record, then show ordinary
        // source cleanup removes that record while retaining the bad neighbor.
        try PropertyListEncoder().encode(rebound).write(to: related.url)
        try protection.suspendForExchange(rebound, at: moved)
        try protection.forget(path: moved.path, identity: rebound.identity)
        XCTAssertFalse(try AppTransferStore.exists(related.url))
        XCTAssertEqual(try Data(contentsOf: unrelated.url), unrelated.bytes)
        XCTAssertTrue(try protection.inventory().records.isEmpty)
        XCTAssertEqual(try protection.inventory().issues.map(\.url), [unrelated.url])
    }

    func testProtectionInventoryDoesNotFollowSymlinksOrBlockOnFIFO() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let app = w.local.appendingPathComponent("Independent.app"), target = w.external.appendingPathComponent("Independent.app")
        try makeSignableApp(app, identifier: "example.special.protection")
        let directory = w.store.directoryURL.appendingPathComponent("update-protection")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = try DataPathIdentity.capture(app)
        let record = AppUpdateProtectionRelocation(id: UUID(), path: app.path, identity: identity,
            entries: [.init(relativePath: "", identity: identity)])
        let bytes = try PropertyListEncoder().encode(record)
        let outside = w.root.appendingPathComponent("record-outside-protection.plist")
        try bytes.write(to: outside)
        let link = directory.appendingPathComponent(record.id.uuidString + ".plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let fifo = directory.appendingPathComponent(UUID().uuidString + ".plist")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let inventory = try AppUpdateProtectionStore(transferStore: w.store).inventory()
        XCTAssertTrue(inventory.records.isEmpty)
        XCTAssertEqual(Set(inventory.issues.map(\.url)), [link, fifo])
        XCTAssertTrue(inventory.issues.allSatisfy { $0.path == nil && $0.identity == nil })
        let moved = try await w.service().moveAndLink(appToMove: item(app), destinationURL: target,
            isRunning: false, progressHandler: nil)
        XCTAssertTrue(moved.isComplete, moved.pendingMessage ?? "")
        let restored = try await w.service().moveBack(app: item(target), localDestinationURL: app, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
        let signed = try await signer(w).sign(appURL: app, bundleIdentifier: "example.special.protection")
        XCTAssertTrue(signed.committed)
        XCTAssertNil(signed.cleanupWarning)
        XCTAssertEqual(try SignatureSnapshot.info(at: link).st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try SignatureSnapshot.info(at: fifo).st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertEqual(Set(try w.service().pendingTransferInspection().issues.map(\.url)), [link, fifo])
    }

    private func pendingRestoreWithRetainedExternalCopy(in workspace: Workspace,
        dock: @escaping AppMigrationService.DockShortcutUpdater = { _, _ in 0 }) async throws
        -> (local: URL, external: URL, record: AppTransferRecord) {
        let local = workspace.local.appendingPathComponent("App.app")
        let external = workspace.external.appendingPathComponent("App.app")
        try makeApp(local, payload: "confirmed application", version: "dev")
        let moved = try await workspace.service().moveAndLink(appToMove: item(local), destinationURL: external,
            isRunning: false, progressHandler: nil)
        XCTAssertTrue(moved.isComplete, moved.warnings.joined(separator: "\n"))
        var interruptedSource = false
        let restored = try await workspace.service(hook: { point, _ in
            if point == .beforeCleanup && !interruptedSource {
                interruptedSource = true
                throw Interrupted()
            }
        }, dock: dock).moveBack(app: item(external), localDestinationURL: local, progressHandler: nil).transferResult
        XCTAssertTrue(interruptedSource)
        XCTAssertTrue(restored.isSwitchComplete)
        XCTAssertFalse(restored.isComplete)
        let record = try workspace.store.record(restored.operationID)
        let source = try XCTUnwrap(record.cleanupItems.first { $0.role == .source })
        XCTAssertEqual(source.path, external.path)
        XCTAssertFalse(source.completed)
        XCTAssertTrue(try source.identity.matchesFilesystemObject(DataPathIdentity.capture(external)))
        XCTAssertTrue(record.signatureFactsCommitted)
        return (local, external, record)
    }

    private func item(_ url: URL, status: String = AppStatus.local) -> AppItem { .init(name: url.lastPathComponent, path: url, status: status) }
    private func payload(_ url: URL) throws -> String { try String(contentsOf: url.appendingPathComponent("Contents/Resources/payload")) }

    private func flagSnapshot(_ url: URL) throws -> [String: UInt32] {
        try Dictionary(uniqueKeysWithValues: SignatureSnapshot.items(in: url).map { item in
            (String(item.path.dropFirst(url.path.count)), try SignatureSnapshot.info(at: item).st_flags)
        })
    }

    private func signer(_ workspace: Workspace) -> CodeSigner {
        CodeSigner(backupDirectoryURL: workspace.root.appendingPathComponent("SignatureBackups"), allowAdministratorPrompt: false,
            requireStopped: { _, _ in }, applicationTransferStore: workspace.store)
    }

    private func makeSignableApp(_ url: URL, identifier: String) throws {
        try makeApp(url, identifier: identifier)
        let executable = url.appendingPathComponent("Contents/MacOS/App")
        let native = try XCTUnwrap(Bundle.main.url(forResource: "StubLauncherBinary", withExtension: nil))
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: native, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func writeDamagedProtectionRecord(in workspace: Workspace, path: String?, identity: DataPathIdentity?, id: UUID = UUID()) throws -> (url: URL, bytes: Data) {
        var object: [String: Any] = ["id": id.uuidString, "entries": "incomplete entry list"]
        object["path"] = path
        if let identity {
            object["identity"] = try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(identity), format: nil)
        }
        let bytes = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        let directory = workspace.store.directoryURL.appendingPathComponent("update-protection")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(id.uuidString + ".plist")
        try bytes.write(to: url)
        return (url, bytes)
    }

    private func makeApp(_ url: URL, payload: String = "payload", version: String = "1",
                         identifier: String = "example.transfer", sparkle: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url.appendingPathComponent("Contents/MacOS/App"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent("Contents/MacOS/App").path)
        var plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "App", "CFBundleName": "App",
            "CFBundlePackageType": "APPL", "CFBundleVersion": version, "CFBundleShortVersionString": version]
        if sparkle { plist["SUFeedURL"] = "https://example.invalid/feed.xml" }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(payload.utf8).write(to: url.appendingPathComponent("Contents/Resources/payload"))
    }

    // MARK: - Issue #77: v1.9.0 `chflags -R uchg` protection

    /// 1.9.0 locked the external copy of a self-updating app and recorded nothing.
    /// Build exactly that end state: whole tree immutable, local portal intact,
    /// no 1.9.1 provenance record.
    private func installV1_9_0LockedState(in workspace: Workspace, local: URL, external: URL) async throws {
        try makeApp(local, payload: "wechat-payload", identifier: "com.tencent.xinWeChat", sparkle: true)
        let moved = try await workspace.service().moveAndLink(appToMove: item(local), destinationURL: external,
            isRunning: false, progressHandler: nil)
        XCTAssertTrue(moved.isComplete, moved.pendingMessage ?? "")
        for url in try SignatureSnapshot.items(in: external) {
            _ = lchflags(url.path, try SignatureSnapshot.info(at: url).st_flags & ~UInt32(UF_IMMUTABLE))
        }
        let protectionDirectory = workspace.store.directoryURL.appendingPathComponent("update-protection")
        if FileManager.default.fileExists(atPath: protectionDirectory.path) {
            try FileManager.default.removeItem(at: protectionDirectory)
        }
        for url in try SignatureSnapshot.items(in: external) {
            let flags = try SignatureSnapshot.info(at: url).st_flags | UInt32(UF_IMMUTABLE)
            XCTAssertEqual(lchflags(url.path, flags), 0)
        }
        XCTAssertNil(try AppUpdateProtectionStore(transferStore: workspace.store).captureForExchange(at: external))
    }

    private func immutablePaths(in root: URL) throws -> [String] {
        try SignatureSnapshot.items(in: root).filter {
            try SignatureSnapshot.info(at: $0).st_flags & UInt32(UF_IMMUTABLE) != 0
        }.map(\.path)
    }

    func testV1_9_0LockedRestoreAdoptsProvenanceAndCompletesWithoutJournal() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("WeChat.app")
        let external = w.external.appendingPathComponent("WeChat.app")
        try await installV1_9_0LockedState(in: w, local: local, external: external)
        XCTAssertGreaterThan(try immutablePaths(in: external).count, 1)

        let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
        XCTAssertEqual(try payload(local), "wechat-payload")
        XCTAssertFalse(try AppTransferStore.exists(external))
        XCTAssertTrue(try w.store.records().isEmpty)
        // Adoption leaves no record behind, and the restored copy keeps no lock.
        XCTAssertTrue(try AppUpdateProtectionStore(transferStore: w.store).inventory().records.isEmpty)
        XCTAssertTrue(try immutablePaths(in: local).isEmpty)
    }

    /// The update lock is AppPorts' own protection, and older versions wrote it
    /// with `chflags -R uchg` without recording anything. Any attempt to prove
    /// which bits are "ours" blocks real restores: an app that was updated or
    /// repaired after being locked keeps some flags and loses others, so a tree
    /// can end up locked only at its root or only in places. A move therefore
    /// clears the immutable bit over the whole tree, whatever shape it has.
    func testEveryLockShapeIsClearedOnRestore() async throws {
        for shape in ["wholeTree", "rootOnly", "nestedOnly", "partial"] {
            let w = try Workspace(); defer { w.cleanup() }
            let local = w.local.appendingPathComponent("WeChat.app")
            let external = w.external.appendingPathComponent("WeChat.app")
            try await installV1_9_0LockedState(in: w, local: local, external: external)
            let items = try SignatureSnapshot.items(in: external)
            switch shape {
            case "rootOnly":
                for url in items { _ = lchflags(url.path, try SignatureSnapshot.info(at: url).st_flags & ~UInt32(UF_IMMUTABLE)) }
                _ = lchflags(external.path, try SignatureSnapshot.info(at: external).st_flags | UInt32(UF_IMMUTABLE))
            case "nestedOnly":
                _ = lchflags(external.path, try SignatureSnapshot.info(at: external).st_flags & ~UInt32(UF_IMMUTABLE))
            case "partial":
                for url in items { _ = lchflags(url.path, try SignatureSnapshot.info(at: url).st_flags & ~UInt32(UF_IMMUTABLE)) }
                for url in [external, external.appendingPathComponent("Contents")] {
                    _ = lchflags(url.path, try SignatureSnapshot.info(at: url).st_flags | UInt32(UF_IMMUTABLE))
                }
            default: break
            }
            XCTAssertGreaterThan(try immutablePaths(in: external).count, 0, "fixture must be locked: \(shape)")

            do {
                let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
                XCTAssertTrue(restored.transferResult.isComplete, "\(shape): \(restored.warnings)")
                XCTAssertEqual(try payload(local), "wechat-payload", shape)
                XCTAssertFalse(try AppTransferStore.exists(external), "\(shape): external copy removed")
                XCTAssertTrue(try immutablePaths(in: local).isEmpty, "\(shape): restored copy carries no lock")
            } catch {
                XCTFail("\(shape): a locked tree must restore, not be refused: \(error.localizedDescription)")
            }
        }
    }

    /// Flags other than the immutable bit are still never attributed to AppPorts,
    /// so the verified copier keeps failing closed instead of silently dropping
    /// them during a move.
    func testNonImmutableFlagsStillFailClosed() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("WeChat.app")
        let external = w.external.appendingPathComponent("WeChat.app")
        try await installV1_9_0LockedState(in: w, local: local, external: external)
        let appFlags = try SignatureSnapshot.info(at: external).st_flags | UInt32(UF_APPEND)
        XCTAssertEqual(lchflags(external.path, appFlags), 0)
        let before = try SignatureSnapshot.fingerprint(of: external)
        do {
            _ = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
            XCTFail("A non-immutable flag must not be cleared or copied blindly")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: external), before, "tree untouched")
    }

    func testAdoptedLegacyLockIsReappliedBySearchExclusion() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("WeChat.app")
        let external = w.external.appendingPathComponent("WeChat.app")
        try await installV1_9_0LockedState(in: w, local: local, external: external)
        let search = AppSearchRecordStore(fileURL: w.root.appendingPathComponent("search.json"))
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 }, transferStore: w.store,
            signatureFactStore: w.facts, runningApplications: { [] })
        try AppPortalMaintenance.rememberEntries(at: local, explicitOperation: true, store: search)
        let result = try await service.excludeFromSearch(app: item(external, status: AppStatus.linked),
            externalRoot: w.external, localEntries: [local], store: search)
        XCTAssertFalse(try AppTransferStore.exists(external))
        XCTAssertGreaterThan(try immutablePaths(in: result.destination).count, 1)
    }

    func testJournalWithoutManifestsIsRetiredAutomatically() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let local = w.local.appendingPathComponent("WeChat.app")
        let external = w.external.appendingPathComponent("WeChat.app")
        try makeApp(local, payload: "original")
        _ = try await w.service().moveAndLink(appToMove: item(local), destinationURL: external,
            isRunning: false, progressHandler: nil)
        do {
            _ = try await w.service(hook: { point, _ in if point == .copied { throw Interrupted() } })
                .moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
            XCTFail("Expected the interrupted restore")
        } catch is Interrupted {}
        let pending = try XCTUnwrap(w.store.records().first)
        // Reproduce the old remove() order: manifests gone, record left behind.
        for name in try FileManager.default.contentsOfDirectory(atPath: w.store.directoryURL.path) where name.hasSuffix(".manifest") {
            try FileManager.default.removeItem(at: w.store.directoryURL.appendingPathComponent(name))
        }
        guard case .terminal = w.service().retryDisposition(for: pending) else {
            return XCTFail("A record without manifests can never advance again")
        }
        // Maintenance closes it out by itself; nothing is deleted.
        XCTAssertEqual(w.service().retireUnrecoverableTransfers().count, 1)
        XCTAssertTrue(try w.store.records().isEmpty)
        XCTAssertTrue(try AppTransferStore.exists(external), "the external copy is kept")
        // The path is free again, so the restore can simply be retried.
        let restored = try await w.service().moveBack(app: item(external), localDestinationURL: local, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.warnings.joined(separator: "\n"))
        XCTAssertEqual(try payload(local), "original")
    }

    func testLostVerifiedCandidateIsArchivedBeforeNewMigration() async throws {
        for replace in [false, true] {
            let w = try Workspace(); defer { w.cleanup() }
            let source = w.local.appendingPathComponent("App.app")
            let destination = w.external.appendingPathComponent("App.app")
            try makeApp(source)
            do {
                _ = try await w.service(hook: { point, _ in if point == .verified { throw Interrupted() } })
                    .moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false,
                                 lockExternal: false, progressHandler: nil)
                XCTFail("Expected interruption")
            } catch is Interrupted {}
            let record = try XCTUnwrap(w.store.records().first)
            XCTAssertTrue(record.hasCandidateBaseline)
            // Move aside rather than remove, so inode reuse cannot mimic identity.
            let retained = w.root.appendingPathComponent("Retained.app")
            try FileManager.default.moveItem(at: record.candidateURL, to: retained)
            if replace { try makeApp(record.candidateURL, payload: "replacement") }
            XCTAssertTrue(w.service().retryDisposition(for: record).isTerminal)
            let result = try await w.service().moveAndLink(appToMove: item(source), destinationURL: destination,
                isRunning: false, lockExternal: false, progressHandler: nil)
            XCTAssertTrue(result.isComplete)
            XCTAssertTrue(try w.store.records().isEmpty)
            XCTAssertEqual(try payload(retained), "payload")
            if replace { XCTAssertEqual(try payload(record.candidateURL), "replacement") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.store.directoryURL
                .appendingPathComponent("archived/" + record.id.uuidString + ".plist").path))
        }
    }

    func testPublishedCandidateIsNotRetiredWithEmptyStage() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        do {
            _ = try await w.service(hook: { point, _ in if point == .destinationPublished { throw Interrupted() } })
                .moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false,
                             lockExternal: false, progressHandler: nil)
            XCTFail("Expected interruption")
        } catch is Interrupted {}
        let record = try XCTUnwrap(w.store.records().first)
        XCTAssertFalse(try AppTransferStore.exists(record.candidateURL))
        XCTAssertFalse(w.service().retryDisposition(for: record).isTerminal)
        XCTAssertTrue(w.service().retireUnrecoverableTransfers().isEmpty)
        let result = try await w.service().retryTransfer(operationID: record.id)
        XCTAssertTrue(result.isComplete)
    }

    func testOfflineVolumeDoesNotRetireMissingCandidate() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        do {
            _ = try await w.service(hook: { point, _ in if point == .verified { throw Interrupted() } })
                .moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false,
                             lockExternal: false, progressHandler: nil)
            XCTFail("Expected interruption")
        } catch is Interrupted {}
        let record = try XCTUnwrap(w.store.records().first)
        let offline = w.root.appendingPathComponent("Offline")
        try FileManager.default.moveItem(at: w.external, to: offline)
        // An empty directory at the old mount point is not the original volume.
        try FileManager.default.createDirectory(at: w.external, withIntermediateDirectories: false)
        XCTAssertFalse(w.service().retryDisposition(for: record).isTerminal)
        XCTAssertTrue(w.service().retireUnrecoverableTransfers().isEmpty)
        try FileManager.default.removeItem(at: w.external)
        try FileManager.default.moveItem(at: offline, to: w.external)
        let result = try await w.service().retryTransfer(operationID: record.id)
        XCTAssertTrue(result.isComplete)
    }

    func testUnreadableSourceDoesNotRetireTransfer() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        do {
            _ = try await w.service(hook: { point, _ in if point == .verified { throw Interrupted() } })
                .moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false,
                             lockExternal: false, progressHandler: nil)
            XCTFail("Expected interruption")
        } catch is Interrupted {}
        let record = try XCTUnwrap(w.store.records().first)
        XCTAssertEqual(chmod(w.local.path, 0), 0)
        defer { _ = chmod(w.local.path, 0o755) }
        XCTAssertFalse(w.service().retryDisposition(for: record).isTerminal)
        XCTAssertTrue(w.service().retireUnrecoverableTransfers().isEmpty)
        XCTAssertEqual(try w.store.records().count, 1)
    }

    func testLostRestoreCandidateIsRetiredWithoutDeletingApplications() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        _ = try await w.service().moveAndLink(appToMove: item(source), destinationURL: destination,
            isRunning: false, lockExternal: false, progressHandler: nil)
        do {
            _ = try await w.service(hook: { point, _ in if point == .verified { throw Interrupted() } })
                .moveBack(app: item(destination), localDestinationURL: source, progressHandler: nil)
            XCTFail("Expected interruption")
        } catch is Interrupted {}
        let record = try XCTUnwrap(w.store.records().first)
        try FileManager.default.moveItem(at: record.candidateURL, to: w.root.appendingPathComponent("Retained.app"))
        let lock = OperationLock(fileURL: w.store.operationLockURL)
        XCTAssertTrue(lock.tryAcquire())
        XCTAssertTrue(w.service().retireUnrecoverableTransfers().isEmpty, "Must not archive during another operation")
        lock.release()
        XCTAssertEqual(w.service().retireUnrecoverableTransfers().count, 1)
        XCTAssertEqual(try payload(destination), "payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let restored = try await w.service().moveBack(app: item(destination), localDestinationURL: source, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete)
    }

    func testExchangedEntryWithoutCommitIsNeverArchived() async throws {
        let w = try Workspace(); defer { w.cleanup() }
        let source = w.local.appendingPathComponent("App.app")
        let destination = w.external.appendingPathComponent("App.app")
        try makeApp(source)
        do {
            _ = try await w.service(hook: { point, _ in if point == .entrySwitched { throw Interrupted() } })
                .moveAndLink(appToMove: item(source), destinationURL: destination, isRunning: false,
                             lockExternal: false, progressHandler: nil)
        } catch is Interrupted {}
        XCTAssertFalse(try w.store.records().isEmpty)
        XCTAssertTrue(w.service().retireUnrecoverableTransfers().isEmpty)
        let record = try XCTUnwrap(w.store.records().first)
        let result = try await w.service().retryTransfer(operationID: record.id)
        XCTAssertTrue(result.isComplete)
    }

    func testProtectionRecordsWrittenBeforeProvenanceStillDecodeAsManaged() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let protection = AppUpdateProtectionStore(transferStore: w.store)
        let app = w.local.appendingPathComponent("Plain.app")
        try makeApp(app)
        try protection.protect(app)
        let record = try XCTUnwrap(protection.captureForExchange(at: app))
        XCTAssertEqual(record.origin, .managed)
        XCTAssertNil(record.adoptedLegacyLock)

        // Rewrite the same record without the field, exactly as 1.9.1 wrote it.
        let url = w.store.directoryURL.appendingPathComponent("update-protection")
            .appendingPathComponent(record.id.uuidString + ".plist")
        var object = try XCTUnwrap(PropertyListSerialization.propertyList(from: try Data(contentsOf: url), format: nil) as? [String: Any])
        object["adoptedLegacyLock"] = nil
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0).write(to: url)
        let inventory = try protection.inventory()
        XCTAssertTrue(inventory.issues.isEmpty)
        XCTAssertEqual(inventory.records.first?.origin, .managed)
    }

    private func assertNoStages(_ workspace: Workspace, file: StaticString = #filePath, line: UInt = #line) throws {
        for directory in [workspace.local, workspace.external] {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(names.contains { $0.hasPrefix(".appports-transfer-") || $0.hasPrefix(".appports-entry-") }, file: file, line: line)
        }
    }
}
