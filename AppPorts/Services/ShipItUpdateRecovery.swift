import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

/// Finishes a failed ShipIt installation without deleting either updater copy.
final class ShipItUpdateRecovery: @unchecked Sendable {
    enum Step: Sendable {
        case waiting, preparing, copying, verifying, switching, refreshing, finishing, rollingBack, cleaning
        var message: String {
            switch self {
            case .waiting: return "等待更新器或其他操作结束。".localized
            case .preparing: return "正在检查更新副本。".localized
            case .copying: return "正在复制新版应用。".localized
            case .verifying: return "正在校验应用完整性和签名。".localized
            case .switching: return "正在切换应用版本。".localized
            case .refreshing: return "正在刷新本机启动入口。".localized
            case .finishing: return "正在完成更新状态收尾。".localized
            case .rollingBack: return "正在恢复更新前的应用。".localized
            case .cleaning: return "正在清理本次更新的缓存和临时文件。".localized
            }
        }
    }
    typealias Reporter = @Sendable (Step) async -> Void
    enum Activity: Sendable { case idle, updaterRunning, applicationRunning }
    struct Request: Codable, Equatable, Sendable {
        let updateBundleURL: URL
        let targetBundleURL: URL
        let bundleIdentifier: String
        let launchAfterInstallation: Bool
    }

    struct Candidate: Codable, Equatable, Sendable {
        let record: AppSearchRecord
        let request: Request
        let requestBytes: Data
        let stateURL: URL
        var key: String { SHA256.hash(data: requestBytes).map { String(format: "%02x", $0) }.joined() }
    }

    struct Receipt: Codable {
        struct Replacement: Codable {
            let identity: DataPathIdentity
            let backup: URL
        }
        let candidate: Candidate
        let parentIdentity: DataPathIdentity
        let stage: URL
        var stageIdentity: DataPathIdentity?
        var ready = false
        var complete = false
        var replacement: Replacement?
        var quitRequested: Bool?
        var installerStateCleaned: Bool?
    }

    let records: AppSearchRecordStore
    let caches: URL
    let directory: URL
    let launchLocks: URL
    let operationLock: OperationLock
    let validate: @Sendable (URL, String) throws -> Void
    let busy: @Sendable (String, URL) async throws -> Activity
    let refresh: @Sendable (AppSearchRecord) async throws -> Void
    private let launch: @Sendable (URL) async throws -> Void
    let sameDeveloper: @Sendable (URL, URL) throws -> Void
    let quit: @Sendable (String, URL) async -> Void
    let clearInstallerState: @Sendable (Candidate) throws -> Void
    let stopInstaller: @Sendable (String) async throws -> Void

    init(records: AppSearchRecordStore = .shared,
         caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
         directory: URL = WriterAdmission.defaultDataDirectory.appendingPathComponent("shipit-recovery"),
         launchLocks: URL = ApplicationLaunchGate.defaultDirectory,
         operationLock: OperationLock = OperationLock(),
         validate: @escaping @Sendable (URL, String) throws -> Void = { try ShipItUpdateRecovery.validateApplication(at: $0, identifier: $1) },
         busy: @escaping @Sendable (String, URL) async throws -> Activity = { try await ShipItUpdateRecovery.activity(identifier: $0, target: $1) },
         refresh: @escaping @Sendable (AppSearchRecord) async throws -> Void = { try await ShipItUpdateRecovery.refreshPortal($0) },
         launch: @escaping @Sendable (URL) async throws -> Void = { try await ShipItUpdateRecovery.launchApplication(at: $0) },
         sameDeveloper: @escaping @Sendable (URL, URL) throws -> Void = { try ShipItUpdateRecovery.requireSameDeveloper(old: $0, new: $1) },
         quit: @escaping @Sendable (String, URL) async -> Void = { await ShipItUpdateRecovery.requestQuit(identifier: $0, target: $1) },
         clearInstallerState: @escaping @Sendable (Candidate) throws -> Void = { try ShipItInstallerState.clear(for: $0) },
         stopInstaller: @escaping @Sendable (String) async throws -> Void = { try await ShipItUpdateRecovery.stopInstallerJob($0) }) {
        self.records = records; self.caches = caches; self.directory = directory
        self.launchLocks = launchLocks; self.operationLock = operationLock
        self.validate = validate; self.busy = busy; self.refresh = refresh; self.launch = launch
        self.sameDeveloper = sameDeveloper; self.quit = quit; self.clearInstallerState = clearInstallerState
        self.stopInstaller = stopInstaller
    }

    var cacheDirectory: URL { caches }

    func monitoredBundleIdentifiers() throws -> Set<String> {
        Set(try records.records().filter { !$0.isRestored && $0.expectsLocalEntry }
            .compactMap(\.targetBundleIdentifier).filter(Self.validIdentifier))
    }

    func candidates() throws -> [Candidate] {
        var result: [Candidate] = []
        for record in try records.records() {
            do {
                guard let candidate = try candidate(for: record) else { continue }
                if hasRollbackRequest(candidate) { continue }
                let receipt = receiptURL(candidate)
                if FileManager.default.fileExists(atPath: receipt.path) {
                    let saved = try JSONDecoder().decode(Receipt.self, from: Self.smallFile(receipt))
                    if saved.complete && saved.installerStateCleaned == true { continue }
                } else if try SignatureSnapshot.entryExists(candidate.request.targetBundleURL), !Self.isNewer(candidate) { continue }
                result.append(candidate)
            } catch {
                AppLogger.shared.logContext("跳过无法检查的 ShipIt 更新记录",
                    details: [("bundle_id", record.targetBundleIdentifier), ("error", error.localizedDescription)], level: "TRACE")
            }
        }
        return result
    }

    /// A missing target alone is not an update failure (unplug, Finder deletion, normal swap).
    func candidate(for record: AppSearchRecord) throws -> Candidate? {
        guard !record.isRestored, record.expectsLocalEntry,
              let identifier = record.targetBundleIdentifier, Self.validIdentifier(identifier),
              let uuid = record.volumeUUID, !uuid.isEmpty else { return nil }
        let local = URL(fileURLWithPath: record.localPath)
        let target = URL(fileURLWithPath: record.externalPath)
        guard AppPortalMaintenance.entries(at: local).contains(where: { $0.externalURL == target }),
              FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path),
              target.pathExtension == "app", Self.canonical(target.deletingLastPathComponent()) == target.deletingLastPathComponent(),
              try Self.volume(at: target.deletingLastPathComponent()) == uuid else { return nil }
        let cache = caches.appendingPathComponent(identifier + ".ShipIt")
        let state = cache.appendingPathComponent("ShipItState.plist")
        guard FileManager.default.fileExists(atPath: state.path) else { return nil }
        let bytes = try Self.smallFile(state)
        guard let request = try? JSONDecoder().decode(Request.self, from: bytes),
              request.bundleIdentifier == identifier,
              request.targetBundleURL.isFileURL, request.updateBundleURL.isFileURL,
              request.targetBundleURL.standardizedFileURL.path == target.path,
              request.updateBundleURL.pathExtension == "app",
              Self.canonical(request.updateBundleURL).path.hasPrefix(Self.canonical(cache).path + "/update."),
              Self.canonical(request.updateBundleURL).path == request.updateBundleURL.standardizedFileURL.path else { return nil }
        let log = cache.appendingPathComponent("ShipIt_stderr.log")
        guard FileManager.default.fileExists(atPath: log.path),
              let text = String(data: try Self.smallFile(log), encoding: .utf8),
              let attempt = text.components(separatedBy: "Detected this as an install request").last,
              attempt.contains("ShipIt quitting"),
              (attempt.contains("Installation error:") || attempt.contains("Too many attempts to install, aborting update")
                  || attempt.contains("Error aborting installation:")),
              // Resumed installs may report only an OSStatus on the final error line.
              // Bind its target using the same attempt's earlier move/rollback messages.
              (attempt.contains(target.path) || attempt.contains(request.targetBundleURL.absoluteString)),
              try Self.modified(log) >= Self.modified(state) else { return nil }
        return Candidate(record: record, request: request, requestBytes: bytes, stateURL: state)
    }

    /// Caller owns the foreground operation token; this worker owns the filesystem locks.
    @discardableResult
    func recover(_ candidate: Candidate, report: @escaping Reporter = { _ in }) async throws -> Bool {
        await report(.waiting)
        guard operationLock.tryAcquire() else { return false }
        defer { operationLock.release() }
        guard !hasRollbackRequest(candidate) else { return false }
        try operationLock.recheckWriterAdmission()
        guard try candidateStillMatches(candidate) else { return false }
        let activity = try await busy(candidate.request.bundleIdentifier, candidate.request.targetBundleURL)
        guard activity != .updaterRunning else { return false }
        await report(.preparing)
        if FileManager.default.fileExists(atPath: receiptURL(candidate).path) {
            var saved = try JSONDecoder().decode(Receipt.self, from: Self.smallFile(receiptURL(candidate)))
            if saved.quitRequested == true, activity == .applicationRunning, try !ownsInstalledTarget(candidate) { return false }
            if saved.complete {
                guard saved.installerStateCleaned != true, try ownsInstalledTarget(candidate) else { return false }
                try validate(candidate.request.targetBundleURL, candidate.request.bundleIdentifier)
                try clearInstallerState(candidate)
                saved.installerStateCleaned = true
                try save(saved)
                return true
            }
        }
        let result = try await installWithLaunchProtection(candidate, report: report)
        // Portal refresh uses the same global lock through AppMigrationService.
        operationLock.release()
        guard result else { return false }
        await report(.refreshing)
        try await refresh(candidate.record)
        guard operationLock.tryAcquire(), try candidateStillMatches(candidate),
              try ownsInstalledTarget(candidate) else { return false }
        guard try await busy(candidate.request.bundleIdentifier, candidate.request.targetBundleURL) != .updaterRunning else { return false }
        await report(.finishing)
        try clearInstallerState(candidate)
        if candidate.request.launchAfterInstallation {
            switch try await busy(candidate.request.bundleIdentifier, candidate.request.targetBundleURL) {
            case .updaterRunning: return false
            case .applicationRunning: break
            case .idle: try await launch(candidate.request.targetBundleURL)
            }
        }
        try finish(candidate)
        AppLogger.shared.logContext("已自动完成 ShipIt 更新恢复", details: [("bundle_id", candidate.request.bundleIdentifier)])
        return true
    }

    private func installWithLaunchProtection(_ candidate: Candidate, report: @escaping Reporter) async throws -> Bool {
        let lease = try ApplicationLaunchGate.acquire(bundleIdentifier: candidate.request.bundleIdentifier,
                                                      migrating: true, directory: launchLocks)
        defer { withExtendedLifetime(lease) {} }
        return try await install(candidate, report: report)
    }

    func ownsInstalledTarget(_ candidate: Candidate) throws -> Bool {
        guard FileManager.default.fileExists(atPath: receiptURL(candidate).path),
              try SignatureSnapshot.entryExists(candidate.request.targetBundleURL) else { return false }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Self.smallFile(receiptURL(candidate)))
        guard receipt.candidate == candidate, receipt.ready,
              let identity = receipt.stageIdentity else { return false }
        return identity.matchesFilesystemObject(try DataPathIdentity.capture(candidate.request.targetBundleURL))
    }

    private func install(_ candidate: Candidate, report: @escaping Reporter) async throws -> Bool {
        let target = candidate.request.targetBundleURL
        let parent = target.deletingLastPathComponent()
        let url = receiptURL(candidate)
        var receipt: Receipt
        if FileManager.default.fileExists(atPath: url.path) {
            receipt = try JSONDecoder().decode(Receipt.self, from: Self.smallFile(url))
            guard receipt.candidate == candidate, !receipt.complete else { return false }
        } else {
            receipt = Receipt(candidate: candidate, parentIdentity: try DataPathIdentity.capture(parent),
                              stage: parent.appendingPathComponent(".appports-shipit-\(UUID().uuidString).app"))
            if try SignatureSnapshot.entryExists(target) {
                guard Self.isNewer(candidate) else { return false }
                try validate(target, candidate.request.bundleIdentifier)
                try validate(candidate.request.updateBundleURL, candidate.request.bundleIdentifier)
                try sameDeveloper(target, candidate.request.updateBundleURL)
                receipt.replacement = .init(identity: try DataPathIdentity.capture(target),
                    backup: parent.appendingPathComponent(".appports-shipit-backup-\(UUID().uuidString).app"))
            }
            try save(receipt)
        }
        guard receipt.stage.deletingLastPathComponent().path == parent.path,
              receipt.stage.lastPathComponent.hasPrefix(".appports-shipit-"), receipt.stage.pathExtension == "app",
              receipt.parentIdentity.matchesFilesystemObject(try DataPathIdentity.capture(parent)) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if try SignatureSnapshot.entryExists(target) {
            // Rename can succeed before its completion is recorded. Only our exact staged inode resumes.
            if receipt.ready, let identity = receipt.stageIdentity,
               identity.matchesFilesystemObject(try DataPathIdentity.capture(target)) {
                try validate(target, candidate.request.bundleIdentifier)
                try preserveReplacedApplication(receipt)
                return true
            }
            guard let old = receipt.replacement,
                  old.identity.matchesFilesystemObject(try DataPathIdentity.capture(target)), Self.isNewer(candidate) else { return false }
        }
        try validate(candidate.request.updateBundleURL, candidate.request.bundleIdentifier)
        if !receipt.ready {
            if try SignatureSnapshot.entryExists(receipt.stage) {
                guard let identity = receipt.stageIdentity,
                      identity.matchesFilesystemObject(try DataPathIdentity.capture(receipt.stage)) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try SignatureSnapshot.remove(receipt.stage)
            }
            try FileManager.default.createDirectory(at: receipt.stage, withIntermediateDirectories: false)
            receipt.stageIdentity = try DataPathIdentity.capture(receipt.stage)
            try save(receipt)
            await report(.copying)
            try SignatureSnapshot.copyContents(from: candidate.request.updateBundleURL, into: receipt.stage)
            await report(.verifying)
            try validate(receipt.stage, candidate.request.bundleIdentifier)
            try DurableFileIO.syncTree(at: receipt.stage)
            receipt.ready = true
            try save(receipt)
        }
        try validate(receipt.stage, candidate.request.bundleIdentifier)
        if let old = receipt.replacement {
            guard try SignatureSnapshot.entryExists(target),
                  old.identity.matchesFilesystemObject(try DataPathIdentity.capture(target)), Self.isNewer(candidate) else { return false }
            try validate(target, candidate.request.bundleIdentifier)
            try sameDeveloper(target, receipt.stage)
        }
        if try await busy(candidate.request.bundleIdentifier, target) == .applicationRunning {
            guard receipt.replacement != nil else { return false }
            if receipt.quitRequested != true {
                receipt.quitRequested = true
                try save(receipt)
                await quit(candidate.request.bundleIdentifier, target)
            }
        }
        guard try candidateStillMatches(candidate),
              receipt.parentIdentity.matchesFilesystemObject(try DataPathIdentity.capture(parent)),
              let identity = receipt.stageIdentity,
              identity.matchesFilesystemObject(try DataPathIdentity.capture(receipt.stage)),
              try await busy(candidate.request.bundleIdentifier, target) == .idle else { return false }
        await report(.switching)
        try Task.checkCancellation()
        try operationLock.recheckWriterAdmission()
        guard try candidateStillMatches(candidate) else { return false }
        let flags: UInt32
        if let old = receipt.replacement {
            guard old.identity.matchesFilesystemObject(try DataPathIdentity.capture(target)), Self.isNewer(candidate) else { return false }
            flags = UInt32(RENAME_SWAP)
        } else { flags = UInt32(RENAME_EXCL) }
        guard renamex_np(receipt.stage.path, target.path, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try preserveReplacedApplication(receipt)
        return true
    }

    private func preserveReplacedApplication(_ receipt: Receipt) throws {
        guard let old = receipt.replacement else { return }
        guard old.backup.deletingLastPathComponent() == receipt.stage.deletingLastPathComponent(),
              old.backup.lastPathComponent.hasPrefix(".appports-shipit-backup-"), old.backup.pathExtension == "app" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if try SignatureSnapshot.entryExists(old.backup) {
            guard old.identity.matchesFilesystemObject(try DataPathIdentity.capture(old.backup)) else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        guard old.identity.matchesFilesystemObject(try DataPathIdentity.capture(receipt.stage)) else { throw CocoaError(.fileReadUnknown) }
        guard renamex_np(receipt.stage.path, old.backup.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isNewer(_ candidate: Candidate) -> Bool {
        guard let old = try? SignatureAppVersion.read(at: candidate.request.targetBundleURL),
              let new = try? SignatureAppVersion.read(at: candidate.request.updateBundleURL),
              old.bundleIdentifier == candidate.request.bundleIdentifier, new.bundleIdentifier == old.bundleIdentifier,
              (try? SignatureSnapshot.info(at: candidate.request.targetBundleURL).st_mode & S_IFMT) == S_IFDIR else { return false }
        for pair in [(new.shortVersion, old.shortVersion), (new.buildVersion, old.buildVersion)] {
            guard let left = pair.0, let right = pair.1,
                  let comparison = compareVersion(left, right) else { return false }
            if comparison != .orderedSame { return comparison == .orderedDescending }
        }
        return false
    }

    static func compareVersion(_ left: String, _ right: String) -> ComparisonResult? {
        func parts(_ value: String) -> ([Int], String?)? {
            let core = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let parts = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, !first.isEmpty,
                  first.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
            let suffix = parts.count == 2 ? String(parts[1]) : nil
            guard suffix == nil || suffix?.isEmpty == false else { return nil }
            let numbers = first.split(separator: ".").compactMap { Int($0) }
            guard numbers.count == first.split(separator: ".").count else { return nil }
            return (numbers, suffix)
        }
        guard let a = parts(left), let b = parts(right) else { return nil }
        for index in 0..<max(a.0.count, b.0.count) {
            let x = index < a.0.count ? a.0[index] : 0, y = index < b.0.count ? b.0[index] : 0
            if x != y { return x > y ? .orderedDescending : .orderedAscending }
        }
        switch (a.1, b.1) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?): return x.compare(y, options: .numeric)
        }
    }

    private func candidateStillMatches(_ candidate: Candidate) throws -> Bool {
        try !hasRollbackRequest(candidate) && records.records().contains(candidate.record) && self.candidate(for: candidate.record) == candidate
    }

    private func receiptURL(_ candidate: Candidate) -> URL { directory.appendingPathComponent(candidate.key + ".json") }

    private func save(_ receipt: Receipt) throws {
        try operationLock.recheckWriterAdmission()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DurableFileIO.write(try JSONEncoder().encode(receipt), to: receiptURL(receipt.candidate))
    }

    private func finish(_ candidate: Candidate) throws {
        // Keep the lock through launch and completion, so another worker cannot defer bookkeeping.
        var receipt = try JSONDecoder().decode(Receipt.self, from: Self.smallFile(receiptURL(candidate)))
        receipt.complete = true
        receipt.installerStateCleaned = true
        try save(receipt)
    }

    static func smallFile(_ url: URL) throws -> Data {
        let info = try SignatureSnapshot.info(at: url)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        return try SignatureRecordFile.data(at: url)
    }

    private static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
    private static func volume(at url: URL) throws -> String? {
        var fresh = url; fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }
    private static func modified(_ url: URL) throws -> Date {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
    }
    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }
    }

    static func validateApplication(at app: URL, identifier: String) throws {
        guard validIdentifier(identifier), try SignatureAppVersion.read(at: app).bundleIdentifier == identifier,
              try SignatureSnapshot.info(at: app).st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadCorruptFile) }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"\(identifier)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    static func activity(identifier: String, target: URL) async throws -> Activity {
        // ShipIt is not an NSRunningApplication. Wait for all same-user installers conservatively.
        let result = try await ProcessCommandRunner().run(executable: "/usr/bin/pgrep",
            arguments: ["-u", String(getuid()), "-x", "ShipIt"], timeout: 5)
        guard !result.timedOut, result.runningProcess == nil, [0, 1].contains(result.status) else {
            throw CocoaError(.executableRuntimeMismatch)
        }
        if result.status == 0 { return .updaterRunning }
        return await MigrationApplicationState.isRunning(appURL: target, bundleIdentifier: identifier) ? .applicationRunning : .idle
    }

    static func requireSameDeveloper(old: URL, new: URL) throws {
        guard let identity = try SignatureInspector.inspect(at: old).developerIdentity else { throw CocoaError(.fileReadCorruptFile) }
        try SignatureInspector.require(identity, at: new)
    }

    @MainActor
    static func requestQuit(identifier: String, target: URL) async {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == identifier && $0.bundleURL?.standardizedFileURL.path == target.standardizedFileURL.path
        }
        for app in apps { _ = app.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while apps.contains(where: { !$0.isTerminated }), ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
        }
    }

    static func refreshPortal(_ record: AppSearchRecord) async throws {
        let local = URL(fileURLWithPath: record.localPath), external = URL(fileURLWithPath: record.externalPath)
        // A user-deleted entry stays deleted. An existing stub already launches by the same path.
        guard AppPortalMaintenance.entries(at: local).contains(where: { $0.externalURL == external }) else { return }
        let plist = NSDictionary(contentsOf: local.appendingPathComponent("Contents/Info.plist"))
        guard plist?["CFBundleExecutable"] as? String == "launcher" else { return }
        guard AppMigrationService().refreshStubPortal(at: local, from: external, force: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @MainActor
    static func launchApplication(at app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
