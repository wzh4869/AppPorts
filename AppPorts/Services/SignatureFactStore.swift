import CryptoKit
import Darwin
import Foundation
import Security

/// An entitlement read failure is never evidence that an application is not sandboxed.
enum SignatureSandboxStatus: Equatable, Sendable {
    case sandboxed, notSandboxed, unsigned, unavailable(String)
}

struct SignatureAppVersion: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let buildVersion: String?
    let shortVersion: String?

    static func read(at app: URL) throws -> Self {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw CodeSigner.SigningError.applicationUnavailable(app)
        }
        return .init(bundleIdentifier: identifier, buildVersion: plist["CFBundleVersion"] as? String,
                     shortVersion: plist["CFBundleShortVersionString"] as? String)
    }
}

/// Public certificate/requirement facts, not signing keys or restorable signature bytes.
struct OriginalDeveloperIdentity: Codable, Equatable, Sendable {
    let authority: String?
    let teamIdentifier: String?
    let designatedRequirement: String
    let certificateSHA256: String

    func matches(_ other: Self) -> Bool {
        // The requirement is evaluated against the selected code as well. A display
        // name alone, or an ad-hoc code claiming a Team ID, cannot pass this check.
        certificateSHA256 == other.certificateSHA256 && teamIdentifier == other.teamIdentifier
    }
}

struct SignatureInspection: Sendable {
    let sandboxStatus: SignatureSandboxStatus
    let isAdHoc: Bool
    let codeDirectoryHash: String?
    let developerIdentity: OriginalDeveloperIdentity?
    let applicationGroups: [String]
    let keychainAccessGroups: [String]
}

/// Security.framework distinguishes unsigned code from failed or malformed reads
/// without parsing a localized codesign error or waiting for a child process.
enum SignatureInspector {
    static func inspect(at app: URL) throws -> SignatureInspection {
        do {
            let info = try information(at: app)
            let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            let adHoc = flags & 0x2 != 0 // CS_ADHOC
            let raw = info[kSecCodeInfoEntitlementsDict as String]
            guard raw == nil || raw is [String: Any] else {
                throw CodeSigner.SigningError.entitlementsUnavailable("无法读取授权字典".localized)
            }
            let entitlements = raw as? [String: Any] ?? [:]
            let sandbox: SignatureSandboxStatus
            if let value = entitlements[CodeSigner.sandboxEntitlementKey] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw CodeSigner.SigningError.entitlementsUnavailable("沙盒授权格式无效".localized)
                }
                sandbox = number.boolValue ? .sandboxed : .notSandboxed
            } else {
                sandbox = .notSandboxed
            }
            func groups(_ key: String) throws -> [String] {
                guard let value = entitlements[key] else { return [] }
                guard let groups = value as? [String], groups.allSatisfy({ !$0.isEmpty }) else {
                    throw CodeSigner.SigningError.entitlementsUnavailable("应用组授权格式无效".localized)
                }
                return groups
            }
            let developer: OriginalDeveloperIdentity?
            if !adHoc, let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
               let certificate = certificates.first,
               let requirement = info[kSecCodeInfoDesignatedRequirement as String] {
                let requirement = requirement as! SecRequirement
                var description: CFString?
                let status = SecRequirementCopyString(requirement, [], &description)
                guard status == errSecSuccess, let description else { throw securityError(status, at: app) }
                developer = .init(authority: SecCertificateCopySubjectSummary(certificate) as String?,
                                  teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
                                  designatedRequirement: description as String,
                                  certificateSHA256: hex(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)))
            } else {
                developer = nil
            }
            return .init(sandboxStatus: sandbox, isAdHoc: adHoc,
                         codeDirectoryHash: (info[kSecCodeInfoUnique as String] as? Data).map { hex($0) },
                         developerIdentity: developer,
                         applicationGroups: try groups("com.apple.security.application-groups"),
                         keychainAccessGroups: try groups("keychain-access-groups"))
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(errSecCSUnsigned) {
            return .init(sandboxStatus: .unsigned, isAdHoc: false, codeDirectoryHash: nil,
                         developerIdentity: nil, applicationGroups: [], keychainAccessGroups: [])
        }
    }

    static func entitlements(at app: URL) throws -> [String: Any] {
        let info = try information(at: app)
        guard let value = info[kSecCodeInfoEntitlementsDict as String] else { return [:] }
        guard let dictionary = value as? [String: Any] else {
            throw CodeSigner.SigningError.entitlementsUnavailable("无法读取授权字典".localized)
        }
        return dictionary
    }

    static func require(_ identity: OriginalDeveloperIdentity, at app: URL) throws {
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(identity.designatedRequirement as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else { throw securityError(requirementStatus, at: app) }
        let code = try staticCode(at: app)
        // Network access is disabled by default. Do not opt into the public
        // kSecCSAllowNetworkAccess flag for an offline identity comparison.
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        guard status == errSecSuccess else { throw CodeSigner.SigningError.originalApplicationMismatch }
    }

    private static func information(at app: URL) throws -> [String: Any] {
        let code = try staticCode(at: app)
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &information)
        guard status == errSecSuccess, let information = information as? [String: Any] else { throw securityError(status, at: app) }
        // Unsigned code can return an otherwise valid general-information dictionary.
        guard information[kSecCodeInfoUnique as String] != nil else { throw securityError(errSecCSUnsigned, at: app) }
        return information
    }

    private static func staticCode(at app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw securityError(status, at: app) }
        return code
    }

    private static func securityError(_ status: OSStatus, at app: URL) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSFilePathErrorKey: app.path,
            NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?) ?? "无法读取应用签名".localized])
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// One current fact per installation. This contains no application files,
/// manifests, patches, or data from which the original signature can be restored.
struct SignatureFact: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let installationID: UUID
    var applicationPath: String
    var applicationIdentity: DataPathIdentity
    let version: SignatureAppVersion
    let originalDeveloper: OriginalDeveloperIdentity?
    /// Stable origin of this installation. A separately verified official
    /// repair updates currentFingerprint without replacing this lineage fact.
    let originalFingerprint: String
    var currentFingerprint: String
    var currentCodeDirectoryHash: String?
    var signatureWasReplaced: Bool
    var legacyBackupRecordPath: String?
    var lastOperationID: UUID
    var updatedAt: Date
}

struct SignatureFactRelocation: Codable, Equatable, Sendable {
    let fact: SignatureFact
}

/// Small records live outside signature-backups; the retired login script
/// cannot interpret these files as an instruction to rewrite an application.
struct SignatureFactStore: Sendable {
    let directoryURL: URL
    private let backupDirectoryURL: URL
    private let applicationTransferStore: AppTransferStore

    struct UnreadableRecord: Sendable {
        let url: URL
        let applicationPath: String?
        let applicationIdentity: DataPathIdentity?
        let detail: String
        let sizeBytes: Int64?

        func concerns(_ app: URL, identity: DataPathIdentity) -> Bool {
            // A resolved identity can distinguish a replaced installation even
            // when an old record still names the same path. A surviving path is
            // only a conservative fallback when identity fields are unreadable.
            if let applicationIdentity, applicationIdentity.isResolved {
                return applicationIdentity.matchesFilesystemObject(identity)
            }
            guard let applicationPath, applicationPath.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: applicationPath).resolvingSymlinksInPath().standardizedFileURL.path == app.path
        }

        var material: SignatureMaterial {
            .init(id: "unreadable-fact:" + url.path, kind: .unreadableRecord, url: url,
                appURL: nil, appName: url.lastPathComponent, bundleIdentifier: nil, sizeBytes: sizeBytes,
                detail: "记录无法读取：".localized + detail,
                canResume: false, canCancel: false, canRestore: false, canDelete: false)
        }
    }

    struct Inventory: Sendable {
        var facts: [SignatureFact] = []
        var unreadableRecords: [UnreadableRecord] = []
    }

    /// These fields can only associate a failure with an installation. They
    /// never provide developer identity, recovery authority, or deletion rights.
    private struct Association: Decodable {
        let applicationPath: String?
        let applicationIdentity: DataPathIdentity?
        enum CodingKeys: String, CodingKey { case applicationPath, applicationIdentity }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            applicationPath = try? fields.decode(String.self, forKey: .applicationPath)
            applicationIdentity = try? fields.decode(DataPathIdentity.self, forKey: .applicationIdentity)
        }
    }

    init(backupDirectoryURL: URL? = nil, applicationTransferStore: AppTransferStore? = nil) {
        let backup = backupDirectoryURL ?? CodeSigner.defaultBackupDirectoryURL
        self.backupDirectoryURL = backup
        self.applicationTransferStore = applicationTransferStore ?? (backup.standardizedFileURL == CodeSigner.defaultBackupDirectoryURL.standardizedFileURL ? .shared
            : AppTransferStore(directoryURL: backup.deletingLastPathComponent().appendingPathComponent(backup.lastPathComponent + "-app-transfers")))
        directoryURL = backup.deletingLastPathComponent().appendingPathComponent(backup.standardizedFileURL == CodeSigner.defaultBackupDirectoryURL.standardizedFileURL ? "signature-facts" : backup.lastPathComponent + "-facts")
    }

    func facts() throws -> [SignatureFact] {
        try inventory().facts
    }

    func inventory() throws -> Inventory {
        guard try SignatureSnapshot.entryExists(directoryURL) else { return .init() }
        guard try SignatureSnapshot.info(at: directoryURL).st_mode & S_IFMT == S_IFDIR else { throw CodeSigner.SigningError.snapshotInvalid }
        // Preserve the store's spelling of ancestor symlinks. Foundation's
        // URL enumerator can rewrite /var to /private/var and change row IDs.
        let urls = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            .filter { $0.hasSuffix(".plist") }.sorted().map { directoryURL.appendingPathComponent($0) }
        var inventory = Inventory()
        for url in urls {
            try Task.checkCancellation()
            var association: Association?
            do {
                let data = try recordData(at: url)
                association = try? PropertyListDecoder().decode(Association.self, from: data)
                inventory.facts.append(try decodeFact(data, at: url))
            } catch is CancellationError { throw CancellationError() }
            catch {
                inventory.unreadableRecords.append(.init(url: url, applicationPath: association?.applicationPath,
                    applicationIdentity: association?.applicationIdentity, detail: error.localizedDescription,
                    sizeBytes: (try? SignatureSnapshot.info(at: url)).map { Int64($0.st_blocks) * 512 }))
            }
        }
        return inventory
    }

    func currentFact(at app: URL, inspection: SignatureInspection? = nil, verifyContent: Bool = false) throws -> SignatureFact? {
        let app = try CodeSigner.resolveAppURL(at: app)
        let identity = try DataPathIdentity.capture(app)
        let inventory = try inventory()
        guard !inventory.unreadableRecords.contains(where: { $0.concerns(app, identity: identity) }) else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        let matches = inventory.facts.filter { $0.applicationIdentity.matchesFilesystemObject(identity) }
        guard !matches.isEmpty else { return nil }
        let version = try SignatureAppVersion.read(at: app)
        let inspection = try inspection ?? SignatureInspector.inspect(at: app)
        guard let hash = inspection.codeDirectoryHash,
              let fact = matches.first(where: { $0.currentCodeDirectoryHash == hash && $0.version == version }) else { return nil }
        if verifyContent, try SignatureSnapshot.fingerprint(of: app) != fact.currentFingerprint { return nil }
        return fact
    }

    func write(_ fact: SignatureFact) throws {
        let inventory = try inventory()
        try writeCommitted(fact)
        // A replaced installation/version cannot accumulate generations at this path.
        // Invalid records are retained for inspection, never guessed to be redundant.
        for previous in inventory.facts where previous.installationID != fact.installationID && previous.applicationPath == fact.applicationPath {
            let url = directoryURL.appendingPathComponent(previous.installationID.uuidString + ".plist")
            guard try decodeFact(recordData(at: url), at: url) == previous else { throw CodeSigner.SigningError.applicationChanged }
            try FileManager.default.removeItem(at: url)
        }
        try DurableFileIO.syncDirectory(at: directoryURL)
    }

    /// The committed application's one small fact is part of bookkeeping that
    /// must finish even after cancellation. Do not scan other records or payloads
    /// here; pruning and old-package cleanup can run on a non-cancelled retry.
    private func writeCommitted(_ fact: SignatureFact) throws {
        try WriterAdmission.recheck(dataDirectory: backupDirectoryURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let destination = directoryURL.appendingPathComponent(fact.installationID.uuidString + ".plist")
        // A pending operation may reconcile a valid record, but cannot overwrite
        // a damaged record merely because its filename contains the expected ID.
        guard fact.schemaVersion == 1 else { throw CodeSigner.SigningError.snapshotInvalid }
        if try SignatureSnapshot.entryExists(destination) {
            guard let existing = try? decodeFact(recordData(at: destination), at: destination) else {
                throw CodeSigner.SigningError.snapshotInvalid
            }
            if existing == fact { return }
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try DurableFileIO.write(encoder.encode(fact), to: destination)
        NotificationCenter.default.post(name: .signatureMaterialsDidChange, object: nil)
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
    }

    /// Called under the existing operation lock after an observed exchange.
    /// The recorded full-content baseline was verified before that exchange;
    /// current identity, version and code hash prevent publishing it for a later
    /// installation. This deliberately has no cancellation checks or tree reads.
    @discardableResult
    func finishCommittedMetadata(_ record: SignatureOperationRecord) throws -> SignatureFact? {
        guard let fact = try activePendingFact(record) else { return nil }
        let destination = directoryURL.appendingPathComponent(fact.installationID.uuidString + ".plist")
        if try SignatureSnapshot.entryExists(destination) {
            guard let existing = try? decodeFact(recordData(at: destination), at: destination) else {
                throw CodeSigner.SigningError.snapshotInvalid
            }
            if existing.lastOperationID != fact.lastOperationID,
               existing.applicationIdentity.matchesFilesystemObject(fact.applicationIdentity) {
                return nil // a later fact for the actual installation wins
            }
        }
        try writeCommitted(fact)
        try extendLegacyAssociation(record, fact: fact)
        return fact
    }

    /// Recover only required identity bookkeeping, not signing or old-package
    /// cleanup. Callers already hold the signature/application mutation lock.
    func reconcileCommittedMetadata(at appURL: URL, transferStore: AppTransferStore? = nil) throws {
        let app = try CodeSigner.resolveAppURL(at: appURL)
        let identity = try DataPathIdentity.capture(app)
        let operations = SignatureOperationStore(backupDirectoryURL: backupDirectoryURL)
        for url in try operations.recordURLs() {
            try Task.checkCancellation()
            // Unreadable records stay visible in the material inventory. They
            // cannot contribute identity or become a global mutation barrier.
            guard let stored = try? operations.read(url),
                  stored.candidateIdentity?.matchesFilesystemObject(identity) == true,
                  [.switching, .committed, .cleaning].contains(stored.phase) else { continue }
            var record = try stored.resolvingApplicationLocation()
            guard record.applicationPath == app.path else { continue }
            guard record.originalBackup?.completed != false else {
                // Relocation must not orphan the still-required official package.
                throw OperationBlockage.pendingSignature(record, reason: .originalRetention)
            }
            guard let fact = try activePendingFact(record) else { continue }
            if let current = try currentFact(at: app, verifyContent: true), current.lastOperationID != record.id {
                continue
            }
            guard try SignatureSnapshot.fingerprint(of: app) == fact.currentFingerprint,
                  try DataPathIdentity.capture(app).matchesFilesystemObject(identity) else { continue }
            if try SignatureSnapshot.entryExists(record.directoryURL) {
                guard let directory = record.directoryIdentity,
                      try DataPathIdentity.capture(record.directoryURL).matchesFilesystemObject(directory) else {
                    throw CodeSigner.SigningError.applicationChanged
                }
            } else if !record.cleanupStarted { throw CodeSigner.SigningError.applicationChanged }
            if try SignatureSnapshot.entryExists(record.candidateURL) {
                guard try DataPathIdentity.capture(record.candidateURL).matchesFilesystemObject(record.applicationIdentity) else {
                    throw CodeSigner.SigningError.applicationChanged
                }
            } else {
                guard [.committed, .cleaning].contains(record.phase), record.cleanupStarted else {
                    throw CodeSigner.SigningError.applicationChanged
                }
            }
            // Complete the durable exchange receipt before allowing another
            // operation to replace or copy away this exact installed object.
            if record.phase == .switching {
                try DurableFileIO.syncDirectory(at: app.deletingLastPathComponent())
                record.phase = .committed
                try operations.write(record)
            }
            _ = try finishCommittedMetadata(record)
        }
        try AppTransferTransaction.reconcileSignatureFacts(at: app,
            store: transferStore ?? applicationTransferStore, facts: self)
    }

    private func activePendingFact(_ record: SignatureOperationRecord) throws -> SignatureFact? {
        guard [.switching, .committed, .cleaning].contains(record.phase),
              let candidate = record.candidateIdentity, let fact = record.pendingFact,
              fact.lastOperationID == record.id, fact.applicationPath == record.applicationPath,
              fact.version == record.version, fact.currentFingerprint == record.candidateFingerprint,
              fact.applicationIdentity.matchesFilesystemObject(candidate) else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        guard try DataPathIdentity.capture(record.applicationURL).matchesFilesystemObject(candidate) else { return nil }
        guard try DataPathIdentity.capture(record.applicationURL.deletingLastPathComponent()).matchesFilesystemObject(record.applicationParentIdentity) else {
            throw CodeSigner.SigningError.applicationChanged
        }
        guard try SignatureAppVersion.read(at: record.applicationURL) == fact.version,
              try SignatureInspector.inspect(at: record.applicationURL).codeDirectoryHash == fact.currentCodeDirectoryHash else { return nil }
        return fact
    }

    private func extendLegacyAssociation(_ record: SignatureOperationRecord, fact: SignatureFact) throws {
        guard record.kind == .sign, let path = record.legacyRecordPath else { return }
        let history = SignatureHistoryStore(backupDirectoryURL: backupDirectoryURL)
        let url = URL(fileURLWithPath: path)
        // History that no longer decodes or matches remains a visible material;
        // it cannot veto a new explicit signature or be relabelled as valid.
        guard var backup = try? history.read(at: url),
              backup.bundleIdentifier == record.version.bundleIdentifier, backup.hasFullSnapshot,
              backup.restorableFingerprints?.contains(record.originalFingerprint) == true
                || (backup.applicationIdentity?.matchesFilesystemObject(fact.applicationIdentity) == true
                    && backup.restorableFingerprints?.contains(fact.currentFingerprint) == true) else { return }
        backup.restorableFingerprints = [backup.originalFingerprint, fact.currentFingerprint].compactMap { $0 }
        backup.applicationIdentity = fact.applicationIdentity
        backup.version = fact.version
        try history.write(backup, to: url)
    }

    private func recordData(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size < 1_048_576 else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try source.read(upToCount: 1_048_576) ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let current = try SignatureSnapshot.info(at: url)
        guard Int64(data.count) == info.st_size, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        return data
    }

    private func decodeFact(_ data: Data, at url: URL) throws -> SignatureFact {
        let fact = try PropertyListDecoder().decode(SignatureFact.self, from: data)
        guard fact.schemaVersion == 1, url.lastPathComponent == fact.installationID.uuidString + ".plist" else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        return fact
    }

    /// Capture before copying and persist this token in the application transfer.
    /// The destination is admitted only through that explicit verified relationship.
    func captureRelocation(from appURL: URL, transferStore: AppTransferStore? = nil) throws -> SignatureFactRelocation? {
        try reconcileCommittedMetadata(at: appURL, transferStore: transferStore)
        return try currentFact(at: appURL, verifyContent: true).map { .init(fact: $0) }
    }

    /// Idempotent after a verified application switch; never looks up by bundle ID.
    func commitRelocation(_ relocation: SignatureFactRelocation, to appURL: URL) throws {
        let app = try CodeSigner.resolveAppURL(at: appURL)
        let identity = try DataPathIdentity.capture(app)
        let version = try SignatureAppVersion.read(at: app)
        guard version == relocation.fact.version,
              try SignatureSnapshot.fingerprint(of: app) == relocation.fact.currentFingerprint,
              try SignatureInspector.inspect(at: app).codeDirectoryHash == relocation.fact.currentCodeDirectoryHash,
              let current = try facts().first(where: { $0.installationID == relocation.fact.installationID }) else {
            throw CodeSigner.SigningError.applicationChanged
        }
        if current.applicationIdentity.matchesFilesystemObject(identity), current.applicationPath == app.path,
           current.currentFingerprint == relocation.fact.currentFingerprint { return }
        guard current == relocation.fact else { throw CodeSigner.SigningError.applicationChanged }
        var moved = current
        moved.applicationPath = app.path
        moved.applicationIdentity = identity
        moved.updatedAt = Date()
        try write(moved)
    }
}
