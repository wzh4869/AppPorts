import Darwin
import Foundation

extension ShipItUpdateRecovery {
    private struct OwnedPath: Codable {
        let url: URL
        let identity: DataPathIdentity
    }

    private struct Rollback: Codable {
        let candidate: Candidate
        let parentIdentity: DataPathIdentity
        let source: OwnedPath
        let version: SignatureAppVersion
        let stage: URL
        let targetBefore: DataPathIdentity?
        var stageIdentity: DataPathIdentity?
        var installedIdentity: DataPathIdentity?
        var cleanup: [OwnedPath]?
        var cleanupComplete: Bool?
        var rejectedUpdate: DataPathIdentity?
    }

    struct PendingRollback {
        let candidate: Candidate
        let automatic: Bool
    }

    func rollbackURL(_ candidate: Candidate) -> URL {
        directory.appendingPathComponent(candidate.key + ".rollback.json")
    }

    func rollbackIntentURL(_ candidate: Candidate) -> URL {
        directory.appendingPathComponent(candidate.key + ".rollback-intent.json")
    }

    func hasRollbackRequest(_ candidate: Candidate) -> Bool {
        [rollbackIntentURL(candidate), rollbackURL(candidate)].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Save the user's choice before waiting for an operation slot or locating the old app.
    func requestRollback(_ candidate: Candidate) throws {
        try operationLock.recheckWriterAdmission()
        guard try records.records().contains(candidate.record),
              try hasRollbackRequest(candidate) || self.candidate(for: candidate.record) == candidate else { throw RollbackError.changed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DurableFileIO.write(try JSONEncoder().encode(candidate), to: rollbackIntentURL(candidate))
    }

    func pendingRollbacks() throws -> [PendingRollback] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let current = try records.records()
        var candidates: [String: PendingRollback] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            do {
                let candidate: Candidate
                let expected: URL
                var automatic = false
                if url.lastPathComponent.hasSuffix(".rollback-intent.json") {
                    candidate = try JSONDecoder().decode(Candidate.self, from: SignatureRecordFile.data(at: url, maxBytes: 1_048_576))
                    expected = rollbackIntentURL(candidate)
                } else if url.lastPathComponent.hasSuffix(".rollback.json") {
                    let saved = try JSONDecoder().decode(Rollback.self, from: SignatureRecordFile.data(at: url, maxBytes: 1_048_576))
                    candidate = saved.candidate
                    automatic = saved.rejectedUpdate != nil
                    expected = rollbackURL(candidate)
                } else { continue }
                guard url.standardizedFileURL.path == expected.standardizedFileURL.path,
                      current.contains(candidate.record) else { continue }
                if candidates[candidate.key]?.automatic != true {
                    candidates[candidate.key] = PendingRollback(candidate: candidate, automatic: automatic)
                }
            } catch {
                AppLogger.shared.logError("读取 ShipIt 回退记录失败", error: error)
            }
        }
        return candidates.values.sorted { $0.candidate.key < $1.candidate.key }
    }

    /// Called under the installation lock after the same download failed two independent checks.
    func prepareAutomaticRollback(_ candidate: Candidate, rejected: DataPathIdentity) throws {
        try requireRollbackLocation(candidate)
        guard !hasRollbackRequest(candidate),
              rejected.matchesFilesystemObject(try DataPathIdentity.capture(candidate.request.updateBundleURL)) else { throw RollbackError.changed }
        _ = try loadOrPrepareRollback(candidate, rejected: rejected)
    }

    func rollback(_ candidate: Candidate, automatic: Bool = false, report: @escaping Reporter = { _ in }) async throws -> String {
        if !automatic { try requestRollback(candidate) }
        var lock: OperationLock? = operationLock.freshInstance()
        guard lock?.tryAcquire() == true else { throw RollbackError.busy }
        defer { lock?.release() }
        try lock?.recheckWriterAdmission()
        let lease = try ApplicationLaunchGate.acquire(bundleIdentifier: candidate.request.bundleIdentifier,
                                                      migrating: true, directory: launchLocks)
        defer { withExtendedLifetime(lease) {} }
        if automatic && !FileManager.default.fileExists(atPath: rollbackURL(candidate).path) { throw RollbackError.changed }
        try requireRollbackLocation(candidate)
        var saved = try loadOrPrepareRollback(candidate)
        if automatic && saved.rejectedUpdate == nil { throw RollbackError.changed }
        if saved.cleanupComplete == true {
            try requireRestoredApplication(saved)
            try finishRollbackRecords(candidate)
            return saved.version.shortVersion ?? saved.version.buildVersion ?? ""
        }
        await report(.waiting)
        let activity = try await busy(candidate.request.bundleIdentifier, candidate.request.targetBundleURL)
        guard activity != .updaterRunning else {
            throw RollbackError.busy
        }
        if saved.rejectedUpdate != nil {
            guard activity == .idle else { throw RollbackError.busy }
            if saved.source.url != candidate.request.targetBundleURL,
               try await busy(candidate.request.bundleIdentifier, saved.source.url) != .idle { throw RollbackError.busy }
            try checkRejectedDownload(saved)
        }
        try await stopInstaller(candidate.request.bundleIdentifier)
        if saved.rejectedUpdate == nil {
            await quit(candidate.request.bundleIdentifier, candidate.request.targetBundleURL)
            if saved.source.url != candidate.request.targetBundleURL {
                await quit(candidate.request.bundleIdentifier, saved.source.url)
            }
        }
        guard try await busy(candidate.request.bundleIdentifier, candidate.request.targetBundleURL) == .idle else {
            throw RollbackError.applicationRunning
        }
        await report(.rollingBack)
        try restorePreviousApplication(&saved)
        await report(.refreshing)
        // Portal refresh takes the existing global lock itself.
        lock?.release()
        lock = nil
        try await refresh(candidate.record)
        let reacquired = operationLock.freshInstance()
        guard reacquired.tryAcquire() else { throw RollbackError.busy }
        lock = reacquired
        try requireRollbackLocation(candidate)
        try requireRestoredApplication(saved)
        if saved.rejectedUpdate != nil {
            guard try await busy(candidate.request.bundleIdentifier, candidate.request.targetBundleURL) == .idle else { throw RollbackError.busy }
            try checkRejectedDownload(saved)
        }
        await report(.cleaning)
        try clearRollbackInstallerState(candidate)
        try cleanRollback(&saved)
        return saved.version.shortVersion ?? saved.version.buildVersion ?? ""
    }

    private func loadOrPrepareRollback(_ candidate: Candidate, rejected: DataPathIdentity? = nil) throws -> Rollback {
        let url = rollbackURL(candidate)
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Rollback.self, from: SignatureRecordFile.data(at: url, maxBytes: 1_048_576))
            guard saved.candidate == candidate,
                  saved.stage.deletingLastPathComponent() == candidate.request.targetBundleURL.deletingLastPathComponent(),
                  saved.stage.lastPathComponent.hasPrefix(".appports-shipit-rollback-"), saved.stage.pathExtension == "app" else { throw RollbackError.changed }
            if saved.cleanupComplete == true { try requireRestoredApplication(saved) }
            else { try requireSavedSource(saved) }
            return saved
        }
        guard try self.candidate(for: candidate.record) == candidate else { throw RollbackError.changed }
        let old = try previousApplication(candidate)
        try validate(old, candidate.request.bundleIdentifier)
        let version = try SignatureAppVersion.read(at: old)
        if rejected != nil {
            let update = try SignatureAppVersion.read(at: candidate.request.updateBundleURL)
            guard version.bundleIdentifier == update.bundleIdentifier, Self.isNewer(update: update, than: version) else { throw RollbackError.oldApplicationMissing }
        }
        let parent = candidate.request.targetBundleURL.deletingLastPathComponent()
        let targetBefore = try SignatureSnapshot.entryExists(candidate.request.targetBundleURL)
            ? DataPathIdentity.capture(candidate.request.targetBundleURL) : nil
        let saved = Rollback(candidate: candidate, parentIdentity: try DataPathIdentity.capture(parent),
            source: OwnedPath(url: old, identity: try DataPathIdentity.capture(old)),
            version: version,
            stage: parent.appendingPathComponent(".appports-shipit-rollback-\(UUID().uuidString).app"),
            targetBefore: targetBefore, rejectedUpdate: rejected)
        try saveRollback(saved)
        return saved
    }

    private func checkRejectedDownload(_ saved: Rollback) throws {
        guard let rejected = saved.rejectedUpdate else { return }
        let app = saved.candidate.request.updateBundleURL
        if try !SignatureSnapshot.entryExists(app), saved.cleanup != nil { return }
        if try SignatureSnapshot.entryExists(app), rejected.matchesFilesystemObject(try DataPathIdentity.capture(app)) {
            do { try verifyIncoming(saved.candidate, replacing: saved.installedIdentity == nil ? saved.source.url : saved.candidate.request.targetBundleURL) }
            catch let failure as RejectedUpdate where failure.identity == rejected { return }
        }
        // A replacement download may reuse the same request. Release an untouched automatic intent.
        if saved.stageIdentity == nil && saved.cleanup == nil {
            try operationLock.recheckWriterAdmission()
            try SignatureSnapshot.remove(rollbackURL(saved.candidate))
            throw RollbackError.newDownload
        }
        throw RollbackError.changed
    }

    private func previousApplication(_ candidate: Candidate) throws -> URL {
        if let receipt = try installationReceipt(candidate), let old = receipt.replacement {
            for path in [old.backup, receipt.stage, candidate.request.targetBundleURL] {
                if try SignatureSnapshot.entryExists(path),
                   old.identity.matchesFilesystemObject(try DataPathIdentity.capture(path)) { return path }
            }
        }
        let target = candidate.request.targetBundleURL
        if try SignatureSnapshot.entryExists(target), try !ownsInstalledTarget(candidate) {
            let original = try SignatureAppVersion.read(at: target)
            let update = try SignatureAppVersion.read(at: candidate.request.updateBundleURL)
            if Self.isNewer(update: update, than: original) { return target }
        }
        for path in try nativeTemporaryApplications(candidate, movedFromTarget: true) {
            if try SignatureSnapshot.entryExists(path), (try? validate(path, candidate.request.bundleIdentifier)) != nil { return path }
        }
        throw RollbackError.oldApplicationMissing
    }

    private func restorePreviousApplication(_ saved: inout Rollback) throws {
        let target = saved.candidate.request.targetBundleURL
        guard saved.parentIdentity.matchesFilesystemObject(try DataPathIdentity.capture(target.deletingLastPathComponent())) else {
            throw RollbackError.changed
        }
        if let installed = saved.installedIdentity {
            guard installed.matchesFilesystemObject(try DataPathIdentity.capture(target)) else { throw RollbackError.changed }
            try requireRestoredApplication(saved)
            return
        }
        if let staged = saved.stageIdentity, try SignatureSnapshot.entryExists(target),
           staged.matchesFilesystemObject(try DataPathIdentity.capture(target)) {
            saved.installedIdentity = staged
            try requireRestoredApplication(saved)
            try saveRollback(saved)
            return
        }
        guard saved.source.identity.matchesFilesystemObject(try DataPathIdentity.capture(saved.source.url)) else { throw RollbackError.changed }
        try validate(saved.source.url, saved.candidate.request.bundleIdentifier)
        if saved.source.url == target {
            saved.installedIdentity = saved.source.identity
        } else {
            if try SignatureSnapshot.entryExists(saved.stage) {
                guard let identity = saved.stageIdentity,
                      identity.matchesFilesystemObject(try DataPathIdentity.capture(saved.stage)) else { throw RollbackError.changed }
                try SignatureSnapshot.remove(saved.stage)
            }
            try FileManager.default.createDirectory(at: saved.stage, withIntermediateDirectories: false)
            saved.stageIdentity = try DataPathIdentity.capture(saved.stage)
            try saveRollback(saved)
            try SignatureSnapshot.copyContents(from: saved.source.url, into: saved.stage)
            try validate(saved.stage, saved.candidate.request.bundleIdentifier)
            try DurableFileIO.syncTree(at: saved.stage)
            try Task.checkCancellation()
            try operationLock.recheckWriterAdmission()
            let exists = try SignatureSnapshot.entryExists(target)
            if exists {
                guard let before = saved.targetBefore,
                      before.matchesFilesystemObject(try DataPathIdentity.capture(target)),
                      try ownsInstalledTarget(saved.candidate) else { throw RollbackError.changed }
            } else if saved.targetBefore != nil { throw RollbackError.changed }
            guard renamex_np(saved.stage.path, target.path, UInt32(exists ? RENAME_SWAP : RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            saved.installedIdentity = saved.stageIdentity
        }
        try requireRestoredApplication(saved)
        try saveRollback(saved)
    }

    private func requireRestoredApplication(_ saved: Rollback) throws {
        let target = saved.candidate.request.targetBundleURL
        guard let identity = saved.installedIdentity,
              identity.matchesFilesystemObject(try DataPathIdentity.capture(target)),
              try SignatureAppVersion.read(at: target) == saved.version else { throw RollbackError.changed }
        try validate(target, saved.candidate.request.bundleIdentifier)
    }

    private func requireSavedSource(_ saved: Rollback) throws {
        if saved.source.url == saved.candidate.request.targetBundleURL { return }
        if isNativeTemporaryApplication(saved.source.url, identifier: saved.candidate.request.bundleIdentifier) { return }
        if let receipt = try installationReceipt(saved.candidate), let old = receipt.replacement,
           [old.backup, receipt.stage].contains(saved.source.url),
           old.identity.matchesFilesystemObject(saved.source.identity) { return }
        throw RollbackError.changed
    }

    private func cleanRollback(_ saved: inout Rollback) throws {
        if saved.cleanup == nil {
            saved.cleanup = try rollbackCleanupPaths(saved.candidate, saved: saved).compactMap { path in
                guard try SignatureSnapshot.entryExists(path) else { return nil }
                guard path == path.resolvingSymlinksInPath().standardizedFileURL else { throw RollbackError.changed }
                return OwnedPath(url: path, identity: try DataPathIdentity.capture(path))
            }
            try saveRollback(saved)
        }
        let allowed = try rollbackCleanupPaths(saved.candidate, saved: saved)
        for owned in saved.cleanup ?? [] {
            try requireRestoredApplication(saved)
            if try !SignatureSnapshot.entryExists(owned.url) { continue }
            guard allowed.contains(owned.url) else { throw RollbackError.changed }
            if let rejected = saved.rejectedUpdate {
                try requireRollbackLocation(saved.candidate)
                if owned.url == saved.candidate.request.updateBundleURL, !owned.identity.matchesFilesystemObject(rejected) { throw RollbackError.changed }
            }
            guard owned.identity.matchesFilesystemObject(try DataPathIdentity.capture(owned.url)) else { throw RollbackError.changed }
            try SignatureSnapshot.remove(owned.url)
        }
        if saved.rejectedUpdate != nil {
            // rmdir removes only empty, per-attempt containers. Keep shared logs and other downloads.
            let download = saved.candidate.request.updateBundleURL.deletingLastPathComponent()
            if download.deletingLastPathComponent() == saved.candidate.stateURL.deletingLastPathComponent(),
               download.lastPathComponent.hasPrefix("update.") { _ = rmdir(download.path) }
            let native = saved.source.url.deletingLastPathComponent()
            if isNativeTemporaryRoot(native, identifier: saved.candidate.request.bundleIdentifier) { _ = rmdir(native.path) }
        }
        saved.cleanupComplete = true
        try saveRollback(saved)
        try finishRollbackRecords(saved.candidate)
    }

    private func finishRollbackRecords(_ candidate: Candidate) throws {
        let receipt = directory.appendingPathComponent(candidate.key + ".json")
        if try SignatureSnapshot.entryExists(receipt) { try SignatureSnapshot.remove(receipt) }
        let intent = rollbackIntentURL(candidate)
        if try SignatureSnapshot.entryExists(intent) { try SignatureSnapshot.remove(intent) }
        try SignatureSnapshot.remove(rollbackURL(candidate))
    }

    private func rollbackCleanupPaths(_ candidate: Candidate, saved: Rollback) throws -> Set<URL> {
        if let rejected = saved.rejectedUpdate {
            var paths: Set<URL> = [candidate.stateURL]
            func include(_ url: URL, identities: [DataPathIdentity?]) throws {
                guard try SignatureSnapshot.entryExists(url) else { return }
                let actual = try DataPathIdentity.capture(url)
                guard identities.contains(where: { $0?.matchesFilesystemObject(actual) == true }) else { throw RollbackError.changed }
                paths.insert(url)
            }
            try include(candidate.request.updateBundleURL, identities: [rejected])
            try include(saved.stage, identities: [saved.targetBefore, saved.stageIdentity])
            if let receipt = try installationReceipt(candidate) {
                try include(receipt.stage, identities: [receipt.stageIdentity, receipt.replacement?.identity])
                if let old = receipt.replacement { try include(old.backup, identities: [old.identity]) }
            }
            if saved.source.url != candidate.request.targetBundleURL { try include(saved.source.url, identities: [saved.source.identity]) }
            return paths
        }
        var paths: Set<URL> = [caches.appendingPathComponent(candidate.request.bundleIdentifier + ".ShipIt"), saved.stage]
        if let receipt = try installationReceipt(candidate) {
            paths.insert(receipt.stage)
            if let old = receipt.replacement { paths.insert(old.backup) }
        }
        if saved.source.url != candidate.request.targetBundleURL {
            if isNativeTemporaryApplication(saved.source.url, identifier: candidate.request.bundleIdentifier) {
                paths.insert(saved.source.url.deletingLastPathComponent())
            } else { paths.insert(saved.source.url) }
        }
        // The signed old bundle names the Electron download cache; never guess a data directory.
        let config = candidate.request.targetBundleURL.appendingPathComponent("Contents/Resources/app-update.yml")
        if let data = try? SignatureRecordFile.data(at: config, maxBytes: 1_048_576), data.count < 32_768,
           let text = String(data: data, encoding: .utf8),
           let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("updaterCacheDirName:") }) {
            let name = line.dropFirst("updaterCacheDirName:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw RollbackError.changed }
            paths.insert(caches.appendingPathComponent(name))
        }
        // Preserve this set before deleting the log, so interruption can finish the same cleanup.
        if saved.cleanup == nil {
            for app in try nativeTemporaryApplications(candidate, movedFromTarget: false) {
                paths.insert(app.deletingLastPathComponent())
            }
        } else {
            for owned in saved.cleanup ?? [] where isNativeTemporaryRoot(owned.url, identifier: candidate.request.bundleIdentifier) {
                paths.insert(owned.url)
            }
        }
        paths.remove(candidate.request.targetBundleURL)
        return paths
    }

    private func installationReceipt(_ candidate: Candidate) throws -> Receipt? {
        let url = directory.appendingPathComponent(candidate.key + ".json")
        guard try SignatureSnapshot.entryExists(url) else { return nil }
        let value = try JSONDecoder().decode(Receipt.self, from: SignatureRecordFile.data(at: url, maxBytes: 1_048_576))
        let parent = candidate.request.targetBundleURL.deletingLastPathComponent()
        guard value.candidate == candidate, value.stage.deletingLastPathComponent() == parent,
              value.stage.lastPathComponent.hasPrefix(".appports-shipit-") else { throw RollbackError.changed }
        if let old = value.replacement {
            guard old.backup.deletingLastPathComponent() == parent,
                  old.backup.lastPathComponent.hasPrefix(".appports-shipit-backup-") else { throw RollbackError.changed }
        }
        return value
    }

    private func nativeTemporaryApplications(_ candidate: Candidate, movedFromTarget: Bool) throws -> [URL] {
        let log = candidate.stateURL.deletingLastPathComponent().appendingPathComponent("ShipIt_stderr.log")
        guard let attempt = try Self.latestInstallationAttempt(in: log)?.details else { throw RollbackError.changed }
        let expression = try NSRegularExpression(pattern: "(?:Moving bundle|Moved bundle contents across volumes) from (file://\\S+) to (file://\\S+)")
        let target = candidate.request.targetBundleURL.standardizedFileURL
        return expression.matches(in: attempt, range: NSRange(attempt.startIndex..., in: attempt)).compactMap { match in
            guard let a = Range(match.range(at: 1), in: attempt), let b = Range(match.range(at: 2), in: attempt),
                  let from = URL(string: String(attempt[a])), let to = URL(string: String(attempt[b])) else { return nil }
            if from.standardizedFileURL.path == target.path, isNativeTemporaryApplication(to, identifier: candidate.request.bundleIdentifier) { return to.standardizedFileURL }
            if !movedFromTarget, to.standardizedFileURL.path == target.path,
               isNativeTemporaryApplication(from, identifier: candidate.request.bundleIdentifier) { return from.standardizedFileURL }
            return nil
        }
    }

    private func isNativeTemporaryApplication(_ url: URL, identifier: String) -> Bool {
        url.pathExtension == "app" && isNativeTemporaryRoot(url.deletingLastPathComponent(), identifier: identifier)
    }

    private func isNativeTemporaryRoot(_ url: URL, identifier: String) -> Bool {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            && url.lastPathComponent.hasPrefix(identifier + ".ShipIt.")
    }

    private func requireRollbackLocation(_ candidate: Candidate) throws {
        if try SignatureSnapshot.entryExists(candidate.stateURL),
           try Self.smallFile(candidate.stateURL) != candidate.requestBytes { throw RollbackError.changed }
        let parent = candidate.request.targetBundleURL.deletingLastPathComponent()
        guard try records.records().contains(candidate.record), !candidate.record.isRestored,
              candidate.request.targetBundleURL.path == candidate.record.externalPath,
              parent == parent.resolvingSymlinksInPath().standardizedFileURL,
              try parent.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == candidate.record.volumeUUID,
              AppPortalMaintenance.entries(at: URL(fileURLWithPath: candidate.record.localPath)).contains(where: {
                  $0.externalURL.standardizedFileURL.path == candidate.request.targetBundleURL.standardizedFileURL.path
              }) else { throw RollbackError.changed }
    }

    private func clearRollbackInstallerState(_ candidate: Candidate) throws {
        if try SignatureSnapshot.entryExists(candidate.stateURL) { try clearInstallerState(candidate) }
    }

    private func saveRollback(_ value: Rollback) throws {
        try operationLock.recheckWriterAdmission()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DurableFileIO.write(try JSONEncoder().encode(value), to: rollbackURL(value.candidate))
    }

    static func stopInstallerJob(_ identifier: String) async throws {
        let runner = ProcessCommandRunner()
        let service = "gui/\(getuid())/\(identifier).ShipIt"
        let current = try await runner.run(executable: "/bin/launchctl", arguments: ["print", service], timeout: 5)
        guard !current.timedOut else { throw RollbackError.busy }
        if current.status == 0 {
            let stopped = try await runner.run(executable: "/bin/launchctl", arguments: ["bootout", service], timeout: 5)
            guard stopped.status == 0, !stopped.timedOut else { throw RollbackError.busy }
        }
    }

    enum RollbackError: LocalizedError {
        case busy, applicationRunning, oldApplicationMissing, changed, newDownload
        var errorDescription: String? {
            switch self {
            case .busy: return "更新器或其他操作仍在运行，请稍后重试回退。".localized
            case .applicationRunning: return "应用尚未退出，请退出后重试回退。".localized
            case .oldApplicationMissing: return "找不到可核验的完整旧版，无法回退更新。".localized
            case .changed: return "应用位置或更新现场已变化，已停止回退并保留必要副本。".localized
            case .newDownload: return ShipItUpdateRecovery.Step.preparing.message
            }
        }
    }
}
