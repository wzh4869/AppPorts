import CryptoKit
import Darwin
import Foundation

struct SignatureOperationResult: Sendable {
    let applicationURL: URL?
    let operationID: UUID?
    let committed: Bool
    let cleanupWarning: String?
}

struct SignatureRecoveryRequirements: Equatable, Sendable {
    let applicationURL: URL
    let originalApplicationURL: URL
    let originalIdentity: DataPathIdentity
    let originalFingerprint: String
    let bundleIdentifier: String
    let isSandboxed: Bool
    let applicationGroups: [String]
    let keychainAccessGroups: [String]
}

struct SignatureMaterial: Identifiable, Sendable {
    enum Kind: String, Sendable { case temporaryOperation, historicalSnapshot, retiredSnapshot, orphanSnapshot, legacyRecord, unreadableRecord, unclaimedTemporary }
    let id: String
    let kind: Kind
    let url: URL
    let appURL: URL?
    let appName: String
    let bundleIdentifier: String?
    let sizeBytes: Int64?
    let detail: String
    let canResume: Bool
    let canCancel: Bool
    let canRestore: Bool
    let canDelete: Bool
    var canRemoveRecord = false

    /// A failed directory read describes the directory itself, never unknown
    /// children or an authority to resume, restore, or remove them.
    static func unreadableDirectory(at url: URL, detail: String) -> Self {
        .init(id: "unreadable-directory:" + url.path, kind: .unreadableRecord, url: url,
            appURL: nil, appName: url.lastPathComponent, bundleIdentifier: nil, sizeBytes: nil,
            detail: "记录无法读取：".localized + detail,
            canResume: false, canCancel: false, canRestore: false, canDelete: false)
    }
}

/// A record read cannot follow a substituted symlink or block on a special
/// file. Directory inventories retain the caller's lexical parent path.
enum SignatureRecordFile {
    static func children(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            .map { directory.appendingPathComponent($0) }
    }

    static func data(at url: URL, maxBytes: Int64 = 256 * 1024 * 1024) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw CodeSigner.SigningError.snapshotInvalid }
        guard before.st_size <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let limit = Int(min(maxBytes, Int64(Int.max - 1))) + 1
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit) ?? Data()
        guard Int64(data.count) <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let current = try SignatureSnapshot.info(at: url)
        guard Int64(data.count) == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              current.st_dev == before.st_dev, current.st_ino == before.st_ino else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        return data
    }
}

struct SignatureOperationRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case sign, restore }
    enum Phase: String, Codable, Sendable { case preparing, prepared, switching, committed, cleaning, cancelling, abandoned }
    var schemaVersion = 1
    let id: UUID
    let kind: Kind
    let createdAt: Date
    var applicationPath: String
    let applicationIdentity: DataPathIdentity
    let applicationParentIdentity: DataPathIdentity
    let version: SignatureAppVersion
    let originalFingerprint: String
    var directoryPath: String
    var directoryIdentity: DataPathIdentity?
    var candidateIdentity: DataPathIdentity?
    var candidateFingerprint: String?
    var phase: Phase
    var pendingFact: SignatureFact?
    var oldApplicationManifest: SignatureRemovalManifest?
    var cleanupManifest: SignatureRemovalManifest?
    var cleanupStarted = false
    var legacyRecordPath: String?
    var originalSourcePath: String?
    var originalBackup: SignatureOriginalBackupIntent?
    var recoveryRequirements: SignatureRecoveryRequirementsRecord?
    var updateProtection: AppUpdateProtectionRelocation?
    var unconfirmedCommand: ShellCommandProcessReference?
    var warning: String?

    var applicationURL: URL { URL(fileURLWithPath: applicationPath) }
    var directoryURL: URL { URL(fileURLWithPath: directoryPath) }
    var candidateURL: URL { directoryURL.appendingPathComponent(applicationURL.lastPathComponent) }

    func resolvingApplicationLocation(mountedVolumes: [URL]? = nil) throws -> Self {
        guard schemaVersion == 3, let location = originalBackup?.backup.applicationParentLocation else { return self }
        guard location.identity.matchesFilesystemObject(applicationParentIdentity) else { throw CodeSigner.SigningError.snapshotInvalid }
        let parent = try location.resolve(mountedVolumes: mountedVolumes)
        guard parent.path != applicationURL.deletingLastPathComponent().path else { return self }
        var record = self
        record.applicationPath = parent.appendingPathComponent(applicationURL.lastPathComponent).path
        record.directoryPath = parent.appendingPathComponent(".AppPorts-signature-" + id.uuidString).path
        if record.pendingFact?.applicationPath == applicationPath { record.pendingFact?.applicationPath = record.applicationPath }
        return record
    }
}

/// Keeping the only official original is a durable obligation, separate from
/// the short-lived signing workspace. Old writers reject this schema instead
/// of deleting the exchanged original without honoring that obligation.
struct SignatureOriginalBackupIntent: Codable, Equatable, Sendable {
    let recordPath: String
    let parentIdentity: DataPathIdentity
    let recordParentIdentity: DataPathIdentity
    var backup: SignatureBackup
    var snapshotIdentity: DataPathIdentity?
    var removalManifest: SignatureRemovalManifest?
    var completed = false
    var movesOriginal: Bool?
}

/// Store only the entitlement declarations and original-object binding needed
/// to repeat the dependency preflight; never archive the original application.
struct SignatureRecoveryRequirementsRecord: Codable, Equatable, Sendable {
    let originalApplicationPath: String
    let originalIdentity: DataPathIdentity
    let originalFingerprint: String
    let isSandboxed: Bool
    let applicationGroups: [String]
    let keychainAccessGroups: [String]

    init(_ requirements: SignatureRecoveryRequirements) {
        originalApplicationPath = requirements.originalApplicationURL.path
        originalIdentity = requirements.originalIdentity
        originalFingerprint = requirements.originalFingerprint
        isSandboxed = requirements.isSandboxed
        applicationGroups = requirements.applicationGroups
        keychainAccessGroups = requirements.keychainAccessGroups
    }

    func requirements(for record: SignatureOperationRecord) -> SignatureRecoveryRequirements {
        .init(applicationURL: record.applicationURL, originalApplicationURL: URL(fileURLWithPath: originalApplicationPath),
              originalIdentity: originalIdentity, originalFingerprint: originalFingerprint,
              bundleIdentifier: record.version.bundleIdentifier, isSandboxed: isSandboxed,
              applicationGroups: applicationGroups, keychainAccessGroups: keychainAccessGroups)
    }
}

struct SignatureOperationStore: Sendable {
    let directoryURL: URL

    struct UnreadableRecord: Sendable {
        let url: URL
        let applicationPath: String?
        let applicationIdentity: DataPathIdentity?
        let candidateIdentity: DataPathIdentity?
        let detail: String

        func concerns(_ app: URL, identity: DataPathIdentity) -> Bool {
            let known = [applicationIdentity, candidateIdentity].compactMap { $0 }.filter(\.isResolved)
            if !known.isEmpty { return known.contains { $0.matchesFilesystemObject(identity) } }
            guard let applicationPath, applicationPath.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: applicationPath).resolvingSymlinksInPath().standardizedFileURL.path == app.path
        }

        var material: SignatureMaterial {
            .init(id: "unreadable-operation:" + url.path, kind: .unreadableRecord, url: url,
                appURL: nil, appName: url.lastPathComponent, bundleIdentifier: nil,
                sizeBytes: (try? SignatureSnapshot.info(at: url)).map { Int64($0.st_blocks) * 512 },
                detail: "操作记录读取失败：".localized + detail,
                canResume: false, canCancel: false, canRestore: false, canDelete: false)
        }
    }

    struct Inventory: Sendable {
        var records: [SignatureOperationRecord] = []
        var unreadableRecords: [UnreadableRecord] = []
    }

    /// Partial fields limit the affected installation; they never authorize a
    /// commit, cancellation, or deletion from an otherwise invalid operation.
    private struct Association: Decodable {
        let applicationPath: String?
        let applicationIdentity: DataPathIdentity?
        let candidateIdentity: DataPathIdentity?
        enum CodingKeys: String, CodingKey { case applicationPath, applicationIdentity, candidateIdentity }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            applicationPath = try? fields.decode(String.self, forKey: .applicationPath)
            applicationIdentity = try? fields.decode(DataPathIdentity.self, forKey: .applicationIdentity)
            candidateIdentity = try? fields.decode(DataPathIdentity.self, forKey: .candidateIdentity)
        }
    }

    init(backupDirectoryURL: URL) {
        directoryURL = backupDirectoryURL.deletingLastPathComponent().appendingPathComponent(
            backupDirectoryURL.standardizedFileURL == CodeSigner.defaultBackupDirectoryURL.standardizedFileURL
                ? "signature-operations" : backupDirectoryURL.lastPathComponent + "-operations")
    }

    func recordURLs() throws -> [URL] {
        guard try SignatureSnapshot.entryExists(directoryURL) else { return [] }
        guard try SignatureSnapshot.info(at: directoryURL).st_mode & S_IFMT == S_IFDIR else { throw CodeSigner.SigningError.snapshotInvalid }
        return try SignatureRecordFile.children(in: directoryURL)
            .filter { $0.pathExtension == "plist" }
    }

    func read(_ url: URL) throws -> SignatureOperationRecord {
        guard url.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        return try decode(SignatureRecordFile.data(at: url), at: url)
    }

    private func decode(_ data: Data, at url: URL) throws -> SignatureOperationRecord {
        let record = try PropertyListDecoder().decode(SignatureOperationRecord.self, from: data)
        guard (1...3).contains(record.schemaVersion),
              record.originalBackup == nil || record.schemaVersion >= 2 && record.kind == .sign,
              record.originalBackup?.backup.schemaVersion != 3 || record.schemaVersion == 3,
              record.originalBackup?.movesOriginal != true || record.schemaVersion == 3,
              url.lastPathComponent == record.id.uuidString + ".plist",
              record.applicationIdentity.isResolved, record.applicationParentIdentity.isResolved,
              record.directoryIdentity?.isResolved != false, record.candidateIdentity?.isResolved != false,
              record.applicationURL.standardizedFileURL.path == record.applicationPath,
              record.directoryURL.standardizedFileURL.path == record.directoryPath,
              record.directoryURL == record.applicationURL.deletingLastPathComponent().appendingPathComponent(".AppPorts-signature-" + record.id.uuidString),
              record.applicationPath != record.directoryPath else { throw CodeSigner.SigningError.snapshotInvalid }
        return record
    }

    func inventory() throws -> Inventory {
        var result = Inventory()
        for url in try recordURLs() {
            try Task.checkCancellation()
            var association: Association?
            do {
                let data = try SignatureRecordFile.data(at: url)
                association = try? PropertyListDecoder().decode(Association.self, from: data)
                result.records.append(try decode(data, at: url))
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.unreadableRecords.append(.init(url: url, applicationPath: association?.applicationPath,
                    applicationIdentity: association?.applicationIdentity, candidateIdentity: association?.candidateIdentity,
                    detail: error.localizedDescription))
            }
        }
        return result
    }

    func records() throws -> [SignatureOperationRecord] { try inventory().records }
    func record(id: UUID) throws -> SignatureOperationRecord { try read(directoryURL.appendingPathComponent(id.uuidString + ".plist")) }

    func write(_ record: SignatureOperationRecord) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try DurableFileIO.write(encoder.encode(record), to: directoryURL.appendingPathComponent(record.id.uuidString + ".plist"))
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
    }

    func remove(_ record: SignatureOperationRecord) throws {
        try FileManager.default.removeItem(at: directoryURL.appendingPathComponent(record.id.uuidString + ".plist"))
        try DurableFileIO.syncDirectory(at: directoryURL)
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
    }
}

/// Temporary, bounded-by-file-count deletion evidence. It is removed with the
/// operation after cleanup; no file contents or extended-attribute bytes persist.
struct SignatureRemovalManifest: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let inode: UInt64
        let kind: UInt16
        let mode: UInt16
        let flags: UInt32
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let fingerprint: String?
    }
    let rootIdentity: DataPathIdentity
    let entries: [Entry]

    static func capture(at root: URL) throws -> Self {
        let rootIdentity = try DataPathIdentity.capture(root)
        let rootInfo = try SignatureSnapshot.info(at: root)
        let entries = try SignatureSnapshot.itemsWithInfo(in: root).map { url, info -> Entry in
            guard info.st_dev == rootInfo.st_dev else { throw TreeCopyError.mountBoundary(url.path) }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK else { throw CodeSigner.SigningError.snapshotInvalid }
            return .init(path: String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                         inode: UInt64(info.st_ino), kind: UInt16(kind), mode: info.st_mode & 0o7777,
                         flags: info.st_flags, birthSeconds: Int64(info.st_birthtimespec.tv_sec),
                         birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
                         fingerprint: kind == S_IFDIR ? nil : try SignatureSnapshot.singleNodeFingerprint(at: url, info: info))
        }
        guard try DataPathIdentity.capture(root).matchesFilesystemObject(rootIdentity) else { throw CodeSigner.SigningError.applicationChanged }
        return .init(rootIdentity: rootIdentity, entries: entries)
    }

    func verify(at root: URL, allowingPartial: Bool) throws {
        _ = try verifyAndSnapshotStats(at: root, allowingPartial: allowingPartial)
    }

    private func verifyAndSnapshotStats(at root: URL, allowingPartial: Bool) throws -> [String: stat] {
        try validateStructure()
        guard try DataPathIdentity.capture(root).matchesFilesystemObject(rootIdentity) else { throw CodeSigner.SigningError.applicationChanged }
        let rootInfo = try SignatureSnapshot.info(at: root)
        let known = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let items = try SignatureSnapshot.itemsWithInfo(in: root)
        if !allowingPartial, items.count != entries.count { throw CodeSigner.SigningError.applicationChanged }
        var statsByPath: [String: stat] = [:]
        for (url, info) in items {
            let path = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let entry = known[path] else { throw CodeSigner.SigningError.applicationChanged }
            try requireIdentity(info, entry, device: rootInfo.st_dev)
            let fingerprint = entry.fingerprint == nil ? nil : try SignatureSnapshot.singleNodeFingerprint(at: url, info: info)
            guard info.st_mode & 0o7777 == entry.mode,
                  info.st_flags == entry.flags || (allowingPartial && info.st_flags == entry.flags & ~UInt32(UF_IMMUTABLE)),
                  fingerprint == entry.fingerprint else {
                throw CodeSigner.SigningError.applicationChanged
            }
            if entry.kind == S_IFREG {
                let afterHash = try SignatureSnapshot.info(at: url)
                guard afterHash.st_dev == info.st_dev, afterHash.st_ino == info.st_ino,
                      afterHash.st_mode == info.st_mode, afterHash.st_flags == info.st_flags,
                      afterHash.st_size == info.st_size,
                      afterHash.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                      afterHash.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                      afterHash.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                      afterHash.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
                    throw CodeSigner.SigningError.applicationChanged
                }
                statsByPath[path] = afterHash
            }
        }
        return statsByPath
    }

    /// Anchored no-follow removal. Unknown entries are never recursively swept
    /// up, and every node is checked again immediately before unlinking it.
    func remove(at root: URL, allowingPartial: Bool, unlockCopiedFlags: Bool) throws {
        let verifiedStats = try verifyAndSnapshotStats(at: root, allowingPartial: allowingPartial)
        if !unlockCopiedFlags, let locked = entries.first(where: { $0.flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 }) {
            throw CodeSigner.SigningError.lockedApplication(root.appendingPathComponent(locked.path))
        }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let children = Dictionary(grouping: entries.filter { !$0.path.isEmpty }) { ($0.path as NSString).deletingLastPathComponent }
        let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Read this live descriptor: st_dev can change after reconnecting the
        // same volume, but every node in this operation must belong to it.
        let expectedDevice = parentInfo.st_dev
        func removeNode(parentFD: Int32, name: String, path: String) throws {
            guard let entry = byPath[path] else { throw CodeSigner.SigningError.snapshotInvalid }
            var observed = stat()
            if fstatat(parentFD, name, &observed, AT_SYMLINK_NOFOLLOW) != 0 {
                if allowingPartial, errno == ENOENT { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try requireIdentity(observed, entry, device: expectedDevice)
            if entry.kind == S_IFLNK {
                guard unlinkat(parentFD, name, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return
            }
            let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try requireIdentity(opened, entry, device: expectedDevice)
            if entry.kind == S_IFREG {
                guard let expectedStat = verifiedStats[path],
                      opened.st_dev == expectedStat.st_dev,
                      opened.st_ino == expectedStat.st_ino,
                      (opened.st_mode & 0o7777) == (expectedStat.st_mode & 0o7777),
                      opened.st_size == expectedStat.st_size,
                      opened.st_mtimespec.tv_sec == expectedStat.st_mtimespec.tv_sec,
                      opened.st_mtimespec.tv_nsec == expectedStat.st_mtimespec.tv_nsec,
                      opened.st_ctimespec.tv_sec == expectedStat.st_ctimespec.tv_sec,
                      opened.st_ctimespec.tv_nsec == expectedStat.st_ctimespec.tv_nsec else {
                    throw CodeSigner.SigningError.applicationChanged
                }
            }
            if opened.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                guard unlockCopiedFlags, opened.st_nlink == 1 || entry.kind == S_IFDIR,
                      fchflags(fd, opened.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else { throw CodeSigner.SigningError.lockedApplication(root.appendingPathComponent(path)) }
            }
            if entry.kind == S_IFDIR {
                for child in children[path] ?? [] { try removeNode(parentFD: fd, name: (child.path as NSString).lastPathComponent, path: child.path) }
            }
            guard fstatat(parentFD, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try requireIdentity(observed, entry, device: expectedDevice)
            guard unlinkat(parentFD, name, entry.kind == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try removeNode(parentFD: parent, name: root.lastPathComponent, path: "")
    }

    private func validateStructure() throws {
        let paths = Set(entries.map(\.path))
        guard !entries.isEmpty, paths.count == entries.count, paths.contains("") else { throw CodeSigner.SigningError.snapshotInvalid }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        for entry in entries {
            guard [S_IFDIR, S_IFREG, S_IFLNK].contains(mode_t(entry.kind)), entry.inode > 0,
                  (entry.kind == S_IFDIR) == (entry.fingerprint == nil) else { throw CodeSigner.SigningError.snapshotInvalid }
            if entry.path.isEmpty { continue }
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  byPath[(entry.path as NSString).deletingLastPathComponent]?.kind == S_IFDIR else {
                throw CodeSigner.SigningError.snapshotInvalid
            }
        }
    }

    private func requireIdentity(_ info: stat, _ entry: Entry, device: dev_t) throws {
        guard info.st_dev == device else { throw TreeCopyError.mountBoundary(entry.path) }
        guard UInt64(info.st_ino) == entry.inode, UInt16(info.st_mode & S_IFMT) == entry.kind,
              Int64(info.st_birthtimespec.tv_sec) == entry.birthSeconds,
              Int64(info.st_birthtimespec.tv_nsec) == entry.birthNanoseconds else { throw CodeSigner.SigningError.applicationChanged }
    }
}
