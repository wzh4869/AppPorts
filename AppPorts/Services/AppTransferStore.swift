import Darwin
import Foundation

struct AppTransferRecordIssue: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let appName: String
    let message: String
    /// Diagnostic paths can prevent a conflicting new operation. They never
    /// authorize resuming, deleting, or adopting a filesystem object.
    let knownPaths: [String]
}

/// The application operation's journal and manifests. Completed operations are
/// removed after their owned copies have actually been deleted.
final class AppTransferStore: @unchecked Sendable {
    struct Inventory: Sendable {
        var records: [AppTransferRecord]
        let issues: [AppTransferRecordIssue]
    }

    static let shared = AppTransferStore()
    let directoryURL: URL
    let operationLockURL: URL
    private let lock = NSRecursiveLock()
    private let beforeRecordWrite: ((AppTransferRecord) throws -> Void)?

    init(directoryURL: URL? = nil, beforeRecordWrite: ((AppTransferRecord) throws -> Void)? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts", isDirectory: true)
        self.directoryURL = (directoryURL ?? support.appendingPathComponent("app-transfers", isDirectory: true))
            .standardizedFileURL
        self.operationLockURL = directoryURL == nil ? OperationLock.defaultFileURL
            : self.directoryURL.appendingPathComponent("operation.lock")
        self.beforeRecordWrite = beforeRecordWrite
    }

    func records() throws -> [AppTransferRecord] {
        lock.lock(); defer { lock.unlock() }
        return try recordURLs().map { try decodeRecord(recordData(at: $0), at: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func inventory() throws -> Inventory {
        lock.lock(); defer { lock.unlock() }
        var records: [AppTransferRecord] = []
        var issues: [AppTransferRecordIssue] = []
        for url in try recordURLs() {
            var data: Data?
            do {
                let bytes = try recordData(at: url)
                data = bytes
                records.append(try decodeRecord(bytes, at: url))
            } catch {
                let object = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                var paths = ["sourcePath", "destinationPath", "stagePath", "portalStagePath"].compactMap { object?[$0] as? String }
                if let activation = object?["successorActivation"] as? [String: Any], let path = activation["path"] as? String {
                    paths.append(path)
                }
                for predecessor in object?["predecessorActivations"] as? [[String: Any]] ?? [] {
                    if let activation = predecessor["activation"] as? [String: Any], let path = activation["path"] as? String {
                        paths.append(path)
                    }
                }
                paths += object?["unclaimedPaths"] as? [String] ?? []
                for item in object?["cleanupItems"] as? [[String: Any]] ?? [] {
                    paths += [item["path"] as? String, item["originalPath"] as? String].compactMap { $0 }
                }
                for item in object?["legacyPortals"] as? [[String: Any]] ?? [] {
                    paths += [item["path"] as? String, item["externalPath"] as? String].compactMap { $0 }
                }
                let knownPaths = Set(paths.filter { $0.hasPrefix("/") && !$0.contains("\0") }
                    .map { URL(fileURLWithPath: $0).standardizedFileURL.path }.filter { $0 != "/" }).sorted()
                issues.append(.init(url: url, appName: object?["appName"] as? String ?? url.lastPathComponent,
                    message: "无法读取这条应用转移记录。已保留记录和材料；其他无冲突的操作可继续。".localized + "\n" + error.localizedDescription,
                    knownPaths: knownPaths))
            }
        }
        return Inventory(records: records.sorted { $0.createdAt < $1.createdAt }, issues: issues)
    }

    func record(_ id: UUID) throws -> AppTransferRecord {
        lock.lock(); defer { lock.unlock() }
        let url = recordURL(id)
        return try decodeRecord(recordData(at: url), at: url)
    }

    private func recordURLs() throws -> [URL] {
        guard try Self.exists(directoryURL) else { return [] }
        guard try SignatureSnapshot.info(at: directoryURL).st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).sorted().compactMap { name in
            let url = directoryURL.appendingPathComponent(name)
            return url.pathExtension == "plist" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil ? url : nil
        }
    }

    private func recordData(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        let current = try SignatureSnapshot.info(at: url)
        guard current.st_dev == opened.st_dev, current.st_ino == opened.st_ino,
              current.st_size == opened.st_size, Int64(data.count) == opened.st_size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private func decodeRecord(_ data: Data, at url: URL) throws -> AppTransferRecord {
        let record = try PropertyListDecoder().decode(AppTransferRecord.self, from: data)
        guard url.lastPathComponent == record.operationID.uuidString + ".plist" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }

    func save(_ record: AppTransferRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try recheckWriterAdmission()
        try prepareDirectory()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try beforeRecordWrite?(record)
        try DurableFileIO.write(try encoder.encode(record), to: recordURL(record.operationID))
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
    }

    func writeBaseline(_ baseline: AppTransferBaseline, named name: String, operationID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try recheckWriterAdmission()
        try prepareDirectory()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try DurableFileIO.write(try encoder.encode(baseline), to: baselineURL(operationID, name: name))
    }

    func baseline(_ name: String, operationID: UUID) throws -> AppTransferBaseline {
        lock.lock(); defer { lock.unlock() }
        return try PropertyListDecoder().decode(AppTransferBaseline.self,
            from: Data(contentsOf: baselineURL(operationID, name: name)))
    }

    func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try recheckWriterAdmission()
        // The record is the authority. Removing it first makes a retry of this
        // bookkeeping harmless: leftover manifests are ignored by every reader,
        // while a record that outlived its manifests could never be verified or
        // completed again and would keep blocking its paths forever.
        let url = recordURL(id)
        if try Self.exists(url) { try FileManager.default.removeItem(at: url) }
        try removeManifests(id)
        try DurableFileIO.syncDirectory(at: directoryURL)
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
    }

    /// Archive only bookkeeping: the journal and its manifests leave the live
    /// directory, so the operation stops owning its paths. Applications,
    /// retained copies and staging objects are deliberately left untouched and
    /// remain the user's to inspect. Callers decide when work is unrecoverable.
    @discardableResult
    func archive(_ id: UUID, incomplete: Bool = false) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        try recheckWriterAdmission()
        let recordURL = recordURL(id)
        let recordExists = try Self.exists(recordURL)
        let manifests = try manifestURLs(id)
        guard recordExists || !manifests.isEmpty else { return nil }
        let root = directoryURL.appendingPathComponent("archived", isDirectory: true)
        let archive = incomplete
            ? root.appendingPathComponent("unfinished-" + id.uuidString + "-" + UUID().uuidString, isDirectory: true)
            : root
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        if incomplete {
            let summary = ["operationID": id.uuidString, "status": "incomplete",
                           "reason": "用户选择忽略错误结束任务", "archivedAt": ISO8601DateFormatter().string(from: Date())]
            try DurableFileIO.write(try PropertyListEncoder().encode(summary), to: archive.appendingPathComponent("archive-summary.plist"))
        }
        for url in [recordURL] + manifests where try Self.exists(url) {
            try FileManager.default.moveItem(at: url, to: archive.appendingPathComponent(url.lastPathComponent))
        }
        try DurableFileIO.syncDirectory(at: archive)
        if incomplete { try DurableFileIO.syncDirectory(at: root) }
        try DurableFileIO.syncDirectory(at: directoryURL)
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
        return archive
    }

    private func manifestURLs(_ id: UUID) throws -> [URL] {
        guard try Self.exists(directoryURL) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(id.uuidString + "-") && $0.pathExtension == "manifest" }
            .sorted { $0.path < $1.path }
    }

    private func removeManifests(_ id: UUID) throws {
        for url in try manifestURLs(id) { try FileManager.default.removeItem(at: url) }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(directoryURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    func recheckWriterAdmission() throws {
        try WriterAdmission.recheck(dataDirectory: directoryURL.deletingLastPathComponent())
    }

    private func recordURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent(id.uuidString + ".plist") }
    private func baselineURL(_ id: UUID, name: String) -> URL {
        precondition(!name.contains("/") && !name.contains(".."))
        return directoryURL.appendingPathComponent(id.uuidString + "-" + name + ".manifest")
    }

    static func exists(_ url: URL) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 { return true }
        guard errno == ENOENT else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return false
    }
}

/// Update protection has provenance independent of a transfer's large copy
/// manifest. Entries that were already immutable are deliberately never owned.
struct AppUpdateProtectionRelocation: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let relativePath: String
        let identity: DataPathIdentity
    }
    let id: UUID
    let path: String
    let identity: DataPathIdentity
    let entries: [Entry]
    /// Old records written before 1.9.1 decode without this field and mean
    /// `.managed`. Only adoption of a v1.9.0 `chflags -R uchg` tree sets it.
    var adoptedLegacyLock: Bool? = nil

    /// Why AppPorts believes it may revoke the immutable bits listed above.
    var origin: AppUpdateProtectionOrigin { adoptedLegacyLock == true ? .adoptedV1_9_0 : .managed }
}

/// `managed` records name bits AppPorts set itself. `adoptedV1_9_0` records name
/// bits v1.9.0 set with `chflags -R uchg` and never recorded; the transfer still
/// only ever clears the immutable bit, never other flags.
enum AppUpdateProtectionOrigin: Equatable, Sendable {
    case managed
    case adoptedV1_9_0
}

/// What the caller knows about the object it is about to move. Kept only for
/// logging: locking is AppPorts' own bookkeeping, so a move always clears it.
struct AppUpdateProtectionAdoption: Sendable {
    /// A local entry AppPorts created still resolves to this exact object.
    let managedLocalEntry: URL?
    /// The incoming source is provably the same application.
    let sameApplicationSource: URL?
}

struct AppUpdateProtectionRecordIssue: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let recordID: UUID?
    let path: String?
    let identity: DataPathIdentity?
    let detail: String

    /// Partial fields only reject a conflicting action. They cannot authorize
    /// changing flags, rebinding an installation, or deleting a record.
    func concerns(path otherPath: String, identity otherIdentity: DataPathIdentity) -> Bool {
        if identity?.matchesFilesystemObject(otherIdentity) == true { return true }
        guard let path else { return false }
        let known = URL(fileURLWithPath: path).standardizedFileURL
        let other = URL(fileURLWithPath: otherPath).standardizedFileURL
        func overlap(_ lhs: URL, _ rhs: URL) -> Bool {
            lhs.path == rhs.path || lhs.path.hasPrefix(rhs.path + "/") || rhs.path.hasPrefix(lhs.path + "/")
        }
        return overlap(known, other) || overlap(known.resolvingSymlinksInPath(), other.resolvingSymlinksInPath())
    }

    var diagnostic: AppTransferRecordIssue {
        .init(url: url, appName: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? url.lastPathComponent,
            message: "应用更新保护来源无法确认。".localized + "\n" + "操作记录读取失败：".localized + detail,
            knownPaths: path.map { [$0] } ?? [])
    }
}

final class AppUpdateProtectionStore {
    struct Inventory: Sendable {
        var records: [AppUpdateProtectionRelocation] = []
        var issues: [AppUpdateProtectionRecordIssue] = []
    }

    private typealias Entry = AppUpdateProtectionRelocation.Entry
    private typealias Record = AppUpdateProtectionRelocation
    private let transferStore: AppTransferStore
    private let directory: URL
    private let writerDataDirectory: URL

    private struct Association: Decodable {
        let id: UUID?
        let path: String?
        let identity: DataPathIdentity?
        enum CodingKeys: String, CodingKey { case id, path, identity }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try? fields.decode(UUID.self, forKey: .id)
            path = try? fields.decode(String.self, forKey: .path)
            identity = try? fields.decode(DataPathIdentity.self, forKey: .identity)
        }
    }

    init(transferStore: AppTransferStore = .shared) {
        self.transferStore = transferStore
        directory = transferStore.directoryURL.appendingPathComponent("update-protection", isDirectory: true)
        writerDataDirectory = transferStore.directoryURL.deletingLastPathComponent()
    }

    func captureForExchange(at root: URL) throws -> AppUpdateProtectionRelocation? {
        try transferStore.withLock { try matchingRecord(root) }
    }

    func suspendForExchange(_ relocation: AppUpdateProtectionRelocation, at root: URL) throws {
        try transferStore.withLock {
            guard root.standardizedFileURL.path == relocation.path,
                  try matchingRecord(root) == relocation else {
                throw AppTransferTransaction.failure("应用更新保护记录已改变，未改写锁。".localized, at: root)
            }
            try setProtection(false, record: relocation, root: root)
        }
    }

    /// A signature receipt proves the unchanged parent and original/candidate
    /// objects before calling this after a volume remount. Only path hints move;
    /// the previously owned protection bits never acquire new authority.
    func rebaseExchangePath(_ relocation: AppUpdateProtectionRelocation, to root: URL,
                            parentIdentity: DataPathIdentity) throws -> AppUpdateProtectionRelocation {
        try transferStore.withLock {
            try WriterAdmission.recheck(dataDirectory: writerDataDirectory)
            guard try DataPathIdentity.capture(root.deletingLastPathComponent()).matchesFilesystemObject(parentIdentity) else {
                throw CodeSigner.SigningError.applicationChanged
            }
            let identity = try DataPathIdentity.capture(root)
            let rebound = Record(id: relocation.id, path: root.path, identity: relocation.identity,
                                 entries: relocation.entries, adoptedLegacyLock: relocation.adoptedLegacyLock)
            let current = try currentRecord(relocation, at: root, identity: identity)
            guard current == relocation || current == rebound
                || ((current.path == relocation.path || current.path == root.path) && current.identity.matchesFilesystemObject(identity)) else {
                throw CodeSigner.SigningError.applicationChanged
            }
            if current.path != root.path {
                let relocated = Record(id: current.id, path: root.path, identity: current.identity,
                                       entries: current.entries, adoptedLegacyLock: current.adoptedLegacyLock)
                try DurableFileIO.write(try PropertyListEncoder().encode(relocated), to: recordURL(relocated))
            }
            return rebound
        }
    }

    /// A same-volume rename preserves every filesystem object. Rebind only the
    /// previously recorded bits; never adopt immutable flags found at the new path.
    func commitSameObjectMove(_ relocation: AppUpdateProtectionRelocation, to root: URL) throws {
        try transferStore.withLock {
            try WriterAdmission.recheck(dataDirectory: writerDataDirectory)
            let identity = try DataPathIdentity.capture(root)
            let rebound = Record(id: relocation.id, path: root.standardizedFileURL.path,
                                 identity: identity, entries: relocation.entries,
                                 adoptedLegacyLock: relocation.adoptedLegacyLock)
            let current = try currentRecord(relocation, at: root, identity: identity)
            guard relocation.identity.matchesFilesystemObject(identity),
                  current == relocation || current == rebound else {
                throw AppTransferTransaction.failure("应用更新保护来源无法确认。".localized, at: root)
            }
            if current != rebound {
                try DurableFileIO.write(try PropertyListEncoder().encode(rebound), to: recordURL(rebound))
            }
            try setProtection(true, record: rebound, root: root)
        }
    }

    /// The caller persists this token before suspension and invokes this only
    /// after its own verified same-path exchange. A bundle ID is not authority.
    func commitExchange(_ relocation: AppUpdateProtectionRelocation, to root: URL) throws {
        try transferStore.withLock {
            try WriterAdmission.recheck(dataDirectory: writerDataDirectory)
            guard root.standardizedFileURL.path == relocation.path else {
                throw AppTransferTransaction.failure("应用更新保护来源无法确认。".localized, at: root)
            }
            let identity = try DataPathIdentity.capture(root)
            let current = try currentRecord(relocation, at: root, identity: identity)
            if current.identity.matchesFilesystemObject(identity) {
                try setProtection(true, record: current, root: root)
                return
            }
            guard current == relocation else {
                throw AppTransferTransaction.failure("应用更新保护已属于另一次安装，未改写。".localized, at: root)
            }
            let entries = try relocation.entries.compactMap { entry -> Entry? in
                let url = entry.relativePath.isEmpty ? root : root.appendingPathComponent(entry.relativePath)
                guard try AppTransferStore.exists(url) else { return nil }
                return Entry(relativePath: entry.relativePath, identity: try DataPathIdentity.capture(url))
            }
            let rebound = Record(id: relocation.id, path: relocation.path, identity: identity,
                                 entries: entries, adoptedLegacyLock: relocation.adoptedLegacyLock)
            try DurableFileIO.write(try PropertyListEncoder().encode(rebound), to: recordURL(rebound))
            try setProtection(true, record: rebound, root: root)
        }
    }

    /// Persist intent before setting flags. A process interruption during this
    /// loop still leaves an exact list of bits AppPorts is allowed to revoke.
    func protect(_ root: URL) throws {
        try transferStore.withLock {
            try WriterAdmission.recheck(dataDirectory: writerDataDirectory)
            guard !FileCopier.isNetworkVolume(at: root) else { return }
            if let record = try matchingRecord(root) {
                try setProtection(true, record: record, root: root)
                return
            }
            let identity = try DataPathIdentity.capture(root)
            let entries = try SignatureSnapshot.items(in: root).compactMap { url -> Entry? in
                let info = try SignatureSnapshot.info(at: url)
                guard info.st_flags & UInt32(UF_IMMUTABLE) == 0 else { return nil }
                return Entry(relativePath: String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                             identity: try DataPathIdentity.capture(url))
            }
            let record = Record(id: UUID(), path: root.standardizedFileURL.path, identity: identity, entries: entries)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try DurableFileIO.write(try PropertyListEncoder().encode(record), to: recordURL(record))
            try setProtection(true, record: record, root: root)
        }
    }

    /// Keep the fact while a location operation is in flight, so cancellation
    /// can reapply exactly these bits without adopting a user's existing lock.
    @discardableResult
    func suspend(_ root: URL) throws -> Bool {
        try transferStore.withLock {
            guard let record = try matchingRecord(root) else { return false }
            try setProtection(false, record: record, root: root)
            return true
        }
    }

    /// The update lock is AppPorts' own protection, and 1.9.0 wrote it with
    /// `chflags -R uchg` without recording anything. Every attempt to tell those
    /// bits from a user's own lock ends up blocking ordinary restores, because a
    /// bundle that was updated or repaired after 1.9.0 locked it keeps some flags
    /// and loses others. So a move clears the immutable bit over the whole tree
    /// and records exactly what it found first.
    ///
    /// The record still matters: it is written before any flag changes, so an
    /// interruption can reapply the same bits, and cancellation restores them.
    /// Only `UF_IMMUTABLE` is ever cleared — no other flag is touched.
    @discardableResult
    func adoptLegacyLock(_ root: URL, evidence: AppUpdateProtectionAdoption) throws -> AppUpdateProtectionRelocation? {
        try transferStore.withLock {
            try WriterAdmission.recheck(dataDirectory: writerDataDirectory)
            if let existing = try matchingRecord(root) { return existing }
            guard !FileCopier.isNetworkVolume(at: root) else { return nil }
            // Record every locked node; an unlocked tree produces none and needs no
            // record at all.
            let identity = try DataPathIdentity.capture(root)
            let entries = try unlockableEntries(at: root)
            guard !entries.isEmpty else { return nil }
            let record = Record(id: UUID(), path: root.standardizedFileURL.path, identity: identity,
                                entries: entries, adoptedLegacyLock: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try DurableFileIO.write(try PropertyListEncoder().encode(record), to: recordURL(record))
            AppLogger.shared.logContext("已记录迁移前的应用更新保护",
                details: [("path", record.path), ("entry_count", String(entries.count)),
                          ("local_entry", evidence.managedLocalEntry?.path ?? "-")], level: "WARN")
            return record
        }
    }

    /// Every node carrying `UF_IMMUTABLE`, whatever the rest of the tree looks
    /// like. Flags other than the immutable bit are never attributed, so they are
    /// simply left alone; the verified copier still fails closed on them.
    private func unlockableEntries(at root: URL) throws -> [Entry] {
        let rootPath = root.standardizedFileURL.path
        var entries: [Entry] = []
        for url in try SignatureSnapshot.items(in: root) {
            let info = try SignatureSnapshot.info(at: url)
            guard info.st_flags & UInt32(UF_IMMUTABLE) != 0 else { continue }
            let relative = url.standardizedFileURL.path == rootPath ? ""
                : String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            entries.append(Entry(relativePath: relative, identity: try DataPathIdentity.capture(url)))
        }
        return entries
    }

    func resume(_ root: URL, requiringRecord: Bool = false) throws {
        try transferStore.withLock {
            guard let record = try matchingRecord(root) else {
                if requiringRecord {
                    throw AppTransferTransaction.failure("应用更新保护来源无法确认。".localized, at: root)
                }
                return
            }
            try setProtection(true, record: record, root: root)
        }
    }

    func forget(path: String, identity: DataPathIdentity) throws {
        try transferStore.withLock {
            try WriterAdmission.recheck(dataDirectory: writerDataDirectory)
            guard try AppTransferStore.exists(directory) else { return }
            let inventory = try inventory()
            try rejectIssues(inventory.issues, path: path, identity: identity)
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            for record in inventory.records where record.path == path && record.identity.matchesFilesystemObject(identity) {
                // Re-read by the exact id before deleting bookkeeping; a corrupt
                // or replaced file must not be discarded as the old valid record.
                guard try read(record.id) == record else {
                    throw AppTransferTransaction.failure("应用更新保护记录已改变，未改写锁。".localized, at: recordURL(record))
                }
                try FileManager.default.removeItem(at: recordURL(record))
            }
            try DurableFileIO.syncDirectory(at: directory)
        }
    }

    private func matchingRecord(_ root: URL) throws -> Record? {
        let identity = try DataPathIdentity.capture(root)
        let inventory = try inventory()
        try rejectIssues(inventory.issues, path: root.path, identity: identity)
        return inventory.records.first { $0.path == root.standardizedFileURL.path && $0.identity.matchesFilesystemObject(identity) }
    }

    func inventory() throws -> Inventory {
        try transferStore.withLock {
            guard try AppTransferStore.exists(directory) else { return .init() }
            guard try SignatureSnapshot.info(at: directory).st_mode & S_IFMT == S_IFDIR else {
                throw AppTransferTransaction.failure("应用更新保护来源无法确认。".localized, at: directory)
            }
            var inventory = Inventory()
            for url in try SignatureRecordFile.children(in: directory) where url.pathExtension == "plist" {
                try Task.checkCancellation()
                var association: Association?
                do {
                    let data = try SignatureRecordFile.data(at: url)
                    association = try? PropertyListDecoder().decode(Association.self, from: data)
                    inventory.records.append(try decode(data, at: url))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let path = association?.path.flatMap { Self.normalizedPath($0) }
                    inventory.issues.append(.init(url: url, recordID: association?.id, path: path,
                        identity: association?.identity, detail: error.localizedDescription))
                }
            }
            return inventory
        }
    }

    private func currentRecord(_ relocation: Record, at root: URL, identity: DataPathIdentity) throws -> Record {
        let inventory = try inventory()
        try rejectIssues(inventory.issues, path: relocation.path, identity: relocation.identity, recordID: relocation.id)
        try rejectIssues(inventory.issues, path: root.path, identity: identity, recordID: relocation.id)
        guard let record = inventory.records.first(where: { $0.id == relocation.id }) else {
            throw AppTransferTransaction.failure("应用更新保护来源无法确认。".localized, at: recordURL(relocation))
        }
        return record
    }

    private func rejectIssues(_ issues: [AppUpdateProtectionRecordIssue], path: String, identity: DataPathIdentity,
                              recordID: UUID? = nil) throws {
        for issue in issues {
            let matchesID = recordID.map { issue.recordID == $0 || issue.url.lastPathComponent == $0.uuidString + ".plist" } ?? false
            if matchesID || issue.concerns(path: path, identity: identity) {
                throw AppTransferTransaction.failure("应用更新保护来源无法确认。".localized, at: issue.url)
            }
        }
    }

    private func read(_ id: UUID) throws -> Record {
        let url = directory.appendingPathComponent(id.uuidString + ".plist")
        return try decode(SignatureRecordFile.data(at: url), at: url)
    }

    private func decode(_ data: Data, at url: URL) throws -> Record {
        let record = try PropertyListDecoder().decode(Record.self, from: data)
        guard url.lastPathComponent == record.id.uuidString + ".plist",
              Self.normalizedPath(record.path) == record.path, record.identity.isResolved,
              Set(record.entries.map(\.relativePath)).count == record.entries.count,
              record.entries.allSatisfy({ entry in
                  let parts = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                  return entry.identity.isResolved && !entry.relativePath.contains("\0")
                      && (entry.relativePath.isEmpty
                          ? entry.identity.matchesFilesystemObject(record.identity)
                          : parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
              }) else {
            throw AppTransferTransaction.failure("应用更新保护来源无法确认。".localized, at: url)
        }
        return record
    }

    private static func normalizedPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized == "/" ? nil : normalized
    }

    private func setProtection(_ protected: Bool, record: Record, root: URL) throws {
        try WriterAdmission.recheck(dataDirectory: writerDataDirectory)
        guard try record.identity.matchesFilesystemObject(DataPathIdentity.capture(root)) else {
            throw AppTransferTransaction.failure("应用对象已改变，未改写更新保护。".localized, at: root)
        }
        // Unlock root first; lock children first. Never follow a link or erase
        // any flag besides the immutable bit recorded as our own.
        let entries = protected ? record.entries.reversed().map { $0 } : record.entries
        for entry in entries {
            let url = entry.relativePath.isEmpty ? root : root.appendingPathComponent(entry.relativePath)
            guard try entry.identity.matchesFilesystemObject(DataPathIdentity.capture(url)) else {
                throw AppTransferTransaction.failure("更新保护对象已改变，请检查此路径。".localized, at: url)
            }
            let info = try SignatureSnapshot.info(at: url)
            let flags = protected ? info.st_flags | UInt32(UF_IMMUTABLE) : info.st_flags & ~UInt32(UF_IMMUTABLE)
            if flags != info.st_flags, lchflags(url.path, flags) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
        }
    }

    private func recordURL(_ record: Record) -> URL { directory.appendingPathComponent(record.id.uuidString + ".plist") }
}
