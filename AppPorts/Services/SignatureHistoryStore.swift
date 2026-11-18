import CryptoKit
import Foundation

/// Official originals remain available while the corresponding installation
/// needs signature restoration. Temporary signing packages have a separate journal.
struct SignatureBackup: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let signingIdentity: String
    let originalPath: String
    let backupDate: Date
    var schemaVersion: Int?
    var snapshotName: String?
    var originalFingerprint: String?
    var restorableFingerprints: [String]?
    var originalSignatureWasValid: Bool?
    var cleanup: SignatureBackupCleanup?
    var applicationIdentity: DataPathIdentity?
    var version: SignatureAppVersion?
    /// Kept before cleanup starts so a partially removed original can still be
    /// reconciled against a later official update, without trusting a hash change.
    var originalDeveloper: OriginalDeveloperIdentity?
    var originalApplicationGroups: [String]?
    var snapshotLocation: SignatureDirectoryLocation?
    var snapshotIdentity: DataPathIdentity?
    var applicationParentLocation: SignatureDirectoryLocation?
    var relocation: SignatureBackupRelocation?

    var hasFullSnapshot: Bool { schemaVersion == 2 || schemaVersion == 3 }
}

struct SignatureBackupCleanup: Codable, Equatable, Sendable {
    let parentIdentity: DataPathIdentity
    let snapshotIdentity: DataPathIdentity?
    var applicationFingerprint: String
    var removalManifest: SignatureRemovalManifest?
    var actualDeletionStarted: Bool?
}

/// The old internal original remains authoritative until the external copy and
/// its index are durable. Source removal is a separate, resumable final step.
struct SignatureBackupRelocation: Codable, Equatable, Sendable {
    let sourceName: String
    let sourceIdentity: DataPathIdentity
    let sourceParentIdentity: DataPathIdentity
    let destination: SignatureDirectoryLocation
    let destinationName: String
    var destinationIdentity: DataPathIdentity?
    var partialRemoval: SignatureRemovalManifest?
    let sourceRemoval: SignatureRemovalManifest
    var published = false
    var sourceRemovalStarted = false
}

struct SignatureMaterialDeletion: Codable, Equatable, Sendable {
    let id: UUID
    let targetPath: String
    let parentIdentity: DataPathIdentity
    let targetIdentity: DataPathIdentity
    let manifest: SignatureRemovalManifest
    let recordPath: String?
    let recordDigest: String?
    let moveToTrash: Bool
    var started = false
    var recordParentIdentity: DataPathIdentity?
    var targetLocation: SignatureDirectoryLocation?

    var targetURL: URL {
        (targetLocation?.displayURL ?? URL(fileURLWithPath: targetPath).deletingLastPathComponent())
            .appendingPathComponent(URL(fileURLWithPath: targetPath).lastPathComponent)
    }
}

struct SignatureHistoryStore: Sendable {
    let directoryURL: URL
    let cleanupDirectoryURL: URL

    struct UnreadableDeletion: Sendable {
        let url: URL
        let targetPath: String?
        let targetIdentity: DataPathIdentity?
        let recordPath: String?
        let recordDigest: String?
        let detail: String

        func concerns(_ target: URL, record: URL? = nil, recordID: String? = nil) -> Bool {
            if let targetIdentity, targetIdentity.isResolved {
                if let current = try? DataPathIdentity.capture(target), targetIdentity.matchesFilesystemObject(current) { return true }
            } else if let targetPath, targetPath.hasPrefix("/"),
                      URL(fileURLWithPath: targetPath).standardizedFileURL == target.standardizedFileURL { return true }
            guard let record, let recordPath, recordPath.hasPrefix("/"),
                  URL(fileURLWithPath: recordPath).standardizedFileURL == record.standardizedFileURL else { return false }
            return recordDigest == nil || recordDigest == recordID
        }

        var material: SignatureMaterial {
            .init(id: "unreadable-history-cleanup:" + url.path, kind: .unreadableRecord, url: url,
                appURL: nil, appName: url.lastPathComponent, bundleIdentifier: nil,
                sizeBytes: (try? SignatureSnapshot.info(at: url)).map { Int64($0.st_blocks) * 512 },
                detail: "清理记录无法读取，未据此删除任何材料：".localized + detail,
                canResume: false, canCancel: false, canRestore: false, canDelete: false)
        }
    }

    struct DeletionInventory: Sendable {
        var deletions: [SignatureMaterialDeletion] = []
        var unreadableRecords: [UnreadableDeletion] = []
        var unavailableDirectory: SignatureMaterial?
    }

    struct RecordInventory: Sendable {
        var children: [URL] = []
        var unavailableDirectories: [SignatureMaterial] = []
        var records: [URL] { children.filter { $0.pathExtension == "plist" } }
    }

    private struct DeletionAssociation: Decodable {
        let targetPath: String?
        let targetIdentity: DataPathIdentity?
        let recordPath: String?
        let recordDigest: String?
        enum CodingKeys: String, CodingKey { case targetPath, targetIdentity, recordPath, recordDigest }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            targetPath = try? fields.decode(String.self, forKey: .targetPath)
            targetIdentity = try? fields.decode(DataPathIdentity.self, forKey: .targetIdentity)
            recordPath = try? fields.decode(String.self, forKey: .recordPath)
            recordDigest = try? fields.decode(String.self, forKey: .recordDigest)
        }
    }

    init(backupDirectoryURL: URL) {
        directoryURL = backupDirectoryURL
        cleanupDirectoryURL = SignatureOperationStore(backupDirectoryURL: backupDirectoryURL).directoryURL
            .appendingPathComponent("history-cleanup")
    }

    func recordURL(bundleIdentifier: String) throws -> URL {
        let url = directoryURL.appendingPathComponent(bundleIdentifier + ".plist")
        guard !bundleIdentifier.isEmpty, url.deletingLastPathComponent().standardizedFileURL.path == directoryURL.standardizedFileURL.path else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        return url
    }

    func read(bundleIdentifier: String) throws -> SignatureBackup? {
        let url = try recordURL(bundleIdentifier: bundleIdentifier)
        guard try SignatureSnapshot.entryExists(url) else { return nil }
        let backup = try read(at: url)
        guard backup.bundleIdentifier == bundleIdentifier else { throw CodeSigner.SigningError.snapshotInvalid }
        return backup
    }

    func read(at url: URL) throws -> SignatureBackup {
        guard containsRecord(url), try SignatureSnapshot.info(at: url).st_mode & S_IFMT == S_IFREG else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        return try PropertyListDecoder().decode(SignatureBackup.self, from: SignatureRecordFile.data(at: url))
    }

    func write(_ backup: SignatureBackup, to url: URL? = nil) throws {
        let url = try url ?? recordURL(bundleIdentifier: backup.bundleIdentifier)
        guard containsRecord(url) else { throw CodeSigner.SigningError.snapshotInvalid }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try DurableFileIO.write(encoder.encode(backup), to: url)
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
    }

    /// XML history stores dates at whole-second precision; the binary operation
    /// journal retains fractional seconds. Compare the exact history-format
    /// representation so a committed write can be recognized after a restart.
    func containsPersisted(_ backup: SignatureBackup, at url: URL) throws -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let persisted = try PropertyListDecoder().decode(SignatureBackup.self, from: encoder.encode(backup))
        return try read(at: url) == persisted
    }

    func snapshotURL(for backup: SignatureBackup) -> URL? {
        guard let name = backup.snapshotName, name.hasPrefix("original-"), name.hasSuffix(".app"),
              URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
        if backup.schemaVersion == 3 {
            return backup.snapshotLocation?.displayURL.appendingPathComponent(name)
        }
        return directoryURL.appendingPathComponent(name)
    }

    func snapshotParent(for backup: SignatureBackup) throws -> URL {
        if backup.schemaVersion == 3 {
            guard let location = backup.snapshotLocation else { throw CodeSigner.SigningError.snapshotInvalid }
            return try location.resolve()
        }
        guard backup.schemaVersion == 2,
              directoryURL.standardizedFileURL == directoryURL.resolvingSymlinksInPath().standardizedFileURL,
              try SignatureSnapshot.info(at: directoryURL).st_mode & S_IFMT == S_IFDIR else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        return directoryURL
    }

    func verifiedSnapshot(for backup: SignatureBackup) throws -> URL {
        guard backup.hasFullSnapshot else { throw CodeSigner.SigningError.legacyBackupIncomplete }
        do {
            _ = try snapshotParent(for: backup)
            guard let snapshot = snapshotURL(for: backup), let fingerprint = backup.originalFingerprint,
                  try SignatureSnapshot.info(at: snapshot).st_mode & S_IFMT == S_IFDIR,
                  try backup.schemaVersion != 3 || backup.snapshotIdentity?.matchesFilesystemObject(DataPathIdentity.capture(snapshot)) == true,
                  try SignatureSnapshot.fingerprint(of: snapshot) == fingerprint else { throw CodeSigner.SigningError.snapshotInvalid }
            return snapshot
        } catch is CancellationError { throw CancellationError() }
        catch { throw CodeSigner.SigningError.snapshotInvalid }
    }

    /// Absence is meaningful only on the original, available storage. An
    /// offline external volume never authorizes dropping its recovery index.
    func snapshotIsMissing(for backup: SignatureBackup) throws -> Bool {
        if backup.schemaVersion == nil || backup.schemaVersion == 1 {
            return backup.snapshotName == nil
        }
        guard backup.hasFullSnapshot, let snapshot = snapshotURL(for: backup) else { return false }
        let parent = try snapshotParent(for: backup)
        guard backup.schemaVersion == 3 || isOnlineLocalSnapshotParent(parent) else { return false }
        return try !SignatureSnapshot.entryExists(snapshot)
    }

    func belongs(_ backup: SignatureBackup, to app: URL, currentFingerprint: String? = nil, fact: SignatureFact? = nil,
                 recordURL: URL? = nil) throws -> Bool {
        guard backup.bundleIdentifier == CodeSigner.bundleIdentifier(at: app) else { return false }
        let identity = try DataPathIdentity.capture(app)
        if let saved = backup.applicationIdentity {
            let recordPath = try (recordURL ?? self.recordURL(bundleIdentifier: backup.bundleIdentifier)).path
            guard saved.matchesFilesystemObject(identity)
                || (fact?.applicationIdentity.matchesFilesystemObject(identity) == true
                    && fact?.legacyBackupRecordPath == recordPath) else { return false }
        } else {
            guard let recorded = try? CodeSigner.resolveAppURL(at: URL(fileURLWithPath: backup.originalPath)),
                  try DataPathIdentity.capture(recorded).matchesFilesystemObject(identity) else { return false }
        }
        if let version = backup.version, try SignatureAppVersion.read(at: app) != version { return false }
        if let currentFingerprint, backup.hasFullSnapshot,
           backup.restorableFingerprints?.contains(currentFingerprint) != true { return false }
        return true
    }

    /// Each historical branch is independent. A bad retired directory must not
    /// conceal a readable root record or prevent selecting that exact record.
    func recordInventory() throws -> RecordInventory {
        var inventory = RecordInventory()
        for parent in [directoryURL, directoryURL.appendingPathComponent("retired")] {
            try Task.checkCancellation()
            do {
                guard try SignatureSnapshot.entryExists(parent) else { continue }
                guard try SignatureSnapshot.info(at: parent).st_mode & S_IFMT == S_IFDIR else {
                    throw CodeSigner.SigningError.snapshotInvalid
                }
                inventory.children += try SignatureRecordFile.children(in: parent)
            } catch is CancellationError { throw CancellationError() }
            catch { inventory.unavailableDirectories.append(.unreadableDirectory(at: parent, detail: error.localizedDescription)) }
        }
        return inventory
    }

    func records() throws -> [URL] { try recordInventory().records }

    func materials() throws -> [SignatureMaterial] {
        let inventory = try recordInventory()
        let records = inventory.records
        let deletionInventory = try deletionInventory()
        let pendingDeletions = deletionInventory.deletions
        let deletingPaths = Set(pendingDeletions.map { $0.targetURL.path })
        var materials = inventory.unavailableDirectories
        var referenced = Set<String>()
        for record in records {
            try Task.checkCancellation()
            if deletingPaths.contains(record.path) { continue }
            let id: String
            do { id = try materialID(for: record) }
            catch is CancellationError { throw CancellationError() }
            catch {
                materials.append(unreadableMaterial(at: record, detail: error.localizedDescription))
                continue
            }
            let backup: SignatureBackup
            do { backup = try read(at: record) }
            catch is CancellationError { throw CancellationError() }
            catch {
                let protected = hasPendingDeletion(for: record, snapshot: nil, recordID: id, inventory: deletionInventory)
                let regular = (try? SignatureSnapshot.info(at: record).st_mode & S_IFMT) == S_IFREG
                materials.append(unreadableMaterial(at: record, id: id, detail: error.localizedDescription,
                    canRemoveRecord: regular && !protected))
                continue
            }
            let snapshot = snapshotURL(for: backup)
            if let snapshot { referenced.insert(snapshot.path) }
            let target = snapshot ?? record
            if deletingPaths.contains(target.path) { continue }
            // Older records have no durable evidence for the original's parent
            // volume. Missing or unreadable paths never mean space was freed.
            let storageAvailable = backup.schemaVersion != 3 || (try? snapshotParent(for: backup)) != nil
            let exists = storageAvailable ? try? SignatureSnapshot.entryExists(target) : nil
            let isDirectory = exists == true && (try? SignatureSnapshot.info(at: target).st_mode & S_IFMT) == S_IFDIR
            let legacy = !backup.hasFullSnapshot || snapshot == nil
            let cleanup = backup.cleanup != nil || backup.relocation != nil
            let protected = hasPendingDeletion(for: record, snapshot: snapshot, recordID: id, inventory: deletionInventory)
            // A missing file in an online local backup directory is not an
            // available copy. Keep its historical metadata for provenance,
            // while removing the stale row from the physical-copy inventory.
            if let snapshot, backup.schemaVersion != 3, exists == false, !cleanup, !protected,
               isOnlineLocalSnapshotParent(snapshot.deletingLastPathComponent()) {
                continue
            }
            let missingAfterDeletion = exists == false && backup.cleanup?.actualDeletionStarted == true
                && backup.cleanup?.removalManifest != nil && backup.cleanup?.snapshotIdentity != nil
            let canResume = backup.relocation != nil || cleanup && snapshot != nil && (isDirectory || missingAfterDeletion)
            let detail: String
            if snapshot != nil && !isDirectory {
                detail = "历史原件当前无法核实；位置可能离线或已改变。可选择官方原件，或仅移除记录。".localized
            } else if backup.relocation != nil { detail = "正在将原包迁到外盘，可继续未完成的操作。".localized }
            else if cleanup { detail = "原件已恢复或备份已确认冗余，清理尚未完成".localized }
            else if legacy { detail = "旧版身份记录不包含可恢复的应用；可选择同版本官方原件".localized }
            else { detail = "历史签名恢复原件；恢复时将核对当前安装、版本和内容".localized }
            materials.append(.init(id: id,
                kind: legacy ? .legacyRecord : record.deletingLastPathComponent().lastPathComponent == "retired" ? .retiredSnapshot : .historicalSnapshot,
                url: target, appURL: URL(fileURLWithPath: backup.originalPath),
                appName: URL(fileURLWithPath: backup.originalPath).lastPathComponent, bundleIdentifier: backup.bundleIdentifier,
                sizeBytes: exists == true ? try? allocatedBytes(at: target) : nil, detail: detail,
                canResume: canResume && !protected, canCancel: false, canRestore: isDirectory && !legacy && !cleanup && !protected,
                canDelete: !cleanup && snapshot != nil && isDirectory && !protected,
                canRemoveRecord: (legacy || !isDirectory) && !protected && backup.relocation == nil))
        }
        for url in inventory.children
            where url.pathExtension == "app" && !referenced.contains(url.path) && !deletingPaths.contains(url.path) {
            try Task.checkCancellation()
            do {
                let isDirectory = try SignatureSnapshot.info(at: url).st_mode & S_IFMT == S_IFDIR
                let protected = deletionInventory.unavailableDirectory != nil
                    || deletionInventory.unreadableRecords.contains { $0.concerns(url) }
                materials.append(.init(id: try materialID(for: url), kind: .orphanSnapshot, url: url, appURL: nil,
                    appName: url.lastPathComponent, bundleIdentifier: CodeSigner.bundleIdentifier(at: url),
                    sizeBytes: try? allocatedBytes(at: url), detail: "未关联的历史原件，无法证明冗余；可明确删除此原件".localized,
                    canResume: false, canCancel: false, canRestore: false, canDelete: isDirectory && !protected))
            } catch is CancellationError { throw CancellationError() }
            catch { materials.append(unreadableMaterial(at: url, detail: error.localizedDescription)) }
        }
        for deletion in pendingDeletions {
            materials.append(.init(id: "history-cleanup:" + deletion.id.uuidString, kind: .historicalSnapshot,
                url: deletion.targetURL, appURL: nil,
                appName: URL(fileURLWithPath: deletion.targetPath).lastPathComponent, bundleIdentifier: nil,
                sizeBytes: try? allocatedBytes(at: deletion.targetURL),
                detail: deletion.moveToTrash ? "移入废纸篓尚未完成；完成后仍占存储空间".localized : "已授权删除历史签名原件，清理尚未完成".localized,
                canResume: true, canCancel: false, canRestore: false, canDelete: false))
        }
        materials += deletionInventory.unreadableRecords.map(\.material)
        if let unavailable = deletionInventory.unavailableDirectory { materials.append(unavailable) }
        return materials
    }

    private func isOnlineLocalSnapshotParent(_ parent: URL) -> Bool {
        do {
            guard try SignatureSnapshot.info(at: parent).st_mode & S_IFMT == S_IFDIR,
                  parent.standardizedFileURL == parent.resolvingSymlinksInPath().standardizedFileURL else { return false }
            var fresh = parent
            fresh.removeAllCachedResourceValues()
            let values = try fresh.resourceValues(forKeys: [.volumeIsInternalKey, .volumeUUIDStringKey])
            return values.volumeIsInternal == true && values.volumeUUIDString != nil
        } catch { return false }
    }

    private func unreadableMaterial(at url: URL, id: String? = nil, detail: String,
                                    canRemoveRecord: Bool = false) -> SignatureMaterial {
        .init(id: id ?? "unreadable-history:" + url.path, kind: .unreadableRecord, url: url,
            appURL: nil, appName: url.deletingPathExtension().lastPathComponent, bundleIdentifier: nil,
            sizeBytes: (try? SignatureSnapshot.info(at: url)).map { Int64($0.st_blocks) * 512 },
            detail: "记录无法读取：".localized + detail,
            canResume: false, canCancel: false, canRestore: false, canDelete: false, canRemoveRecord: canRemoveRecord)
    }

    func hasPendingDeletion(for record: URL, snapshot: URL?) throws -> Bool {
        hasPendingDeletion(for: record, snapshot: snapshot, recordID: try? materialID(for: record), inventory: try deletionInventory())
    }

    private func hasPendingDeletion(for record: URL, snapshot: URL?, recordID: String?, inventory: DeletionInventory) -> Bool {
        let paths = Set([record.path, snapshot?.path].compactMap { $0 })
        return inventory.unavailableDirectory != nil
            || inventory.deletions.contains { paths.contains($0.targetURL.path) || $0.recordPath == record.path }
            || inventory.unreadableRecords.contains { $0.concerns(snapshot ?? record, record: record, recordID: recordID) }
    }

    func selectedRecord(materialID: String) throws -> (URL, SignatureBackup)? {
        guard let url = try selectedRecordURL(materialID: materialID) else { return nil }
        return (url, try read(at: url))
    }

    /// Bad siblings cannot conceal a selected record. An unreadable selected
    /// file has no stable ID and therefore grants no metadata-removal right.
    func selectedRecordURL(materialID: String) throws -> URL? {
        for url in try records() {
            try Task.checkCancellation()
            if (try? self.materialID(for: url)) == materialID { return url }
        }
        return nil
    }

    /// Revalidate this selected record without scanning any application tree.
    func canRemoveRecord(at record: URL, materialID: String) throws -> Bool {
        guard containsRecord(record), try SignatureSnapshot.info(at: record).st_mode & S_IFMT == S_IFREG,
              try self.materialID(for: record) == materialID else { return false }
        let backup = try? read(at: record)
        let snapshot = backup.flatMap { snapshotURL(for: $0) }
        guard !(try hasPendingDeletion(for: record, snapshot: snapshot)) else { return false }
        guard let backup else { return true }
        guard backup.relocation == nil else { return false }
        guard backup.hasFullSnapshot, let snapshot else { return true }
        return (try? SignatureSnapshot.info(at: snapshot).st_mode & S_IFMT) != S_IFDIR
    }

    func materialID(for url: URL) throws -> String {
        let identity = try DataPathIdentity.capture(url)
        let base = url.path + ":" + String(identity.device ?? 0) + ":" + String(identity.inode ?? 0)
        let data = try SignatureSnapshot.info(at: url).st_mode & S_IFMT == S_IFREG ? SignatureRecordFile.data(at: url) : Data()
        guard try DataPathIdentity.capture(url).matchesFilesystemObject(identity) else { throw CodeSigner.SigningError.applicationChanged }
        return "history:" + SHA256.hash(data: Data(base.utf8) + data).map { String(format: "%02x", $0) }.joined()
    }

    func allocatedBytes(at url: URL) throws -> Int64 {
        try SignatureSnapshot.items(in: url).reduce(Int64(0)) { value, path in
            value + Int64(try SignatureSnapshot.info(at: path).st_blocks) * 512
        }
    }

    func writeDeletion(_ deletion: SignatureMaterialDeletion) throws {
        try FileManager.default.createDirectory(at: cleanupDirectoryURL, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try DurableFileIO.write(encoder.encode(deletion), to: cleanupDirectoryURL.appendingPathComponent(deletion.id.uuidString + ".plist"))
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
    }

    func deletionInventory() throws -> DeletionInventory {
        var result = DeletionInventory()
        let urls: [URL]
        do {
            guard try SignatureSnapshot.entryExists(cleanupDirectoryURL) else { return result }
            guard try SignatureSnapshot.info(at: cleanupDirectoryURL).st_mode & S_IFMT == S_IFDIR else {
                throw CodeSigner.SigningError.snapshotInvalid
            }
            urls = try SignatureRecordFile.children(in: cleanupDirectoryURL)
        } catch is CancellationError { throw CancellationError() }
        catch {
            result.unavailableDirectory = .unreadableDirectory(at: cleanupDirectoryURL, detail: error.localizedDescription)
            return result
        }
        for url in urls where url.pathExtension == "plist" {
            try Task.checkCancellation()
            var association: DeletionAssociation?
            do {
                let data = try SignatureRecordFile.data(at: url)
                association = try? PropertyListDecoder().decode(DeletionAssociation.self, from: data)
                result.deletions.append(try decodeDeletion(data, at: url))
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.unreadableRecords.append(.init(url: url, targetPath: association?.targetPath,
                    targetIdentity: association?.targetIdentity, recordPath: association?.recordPath,
                    recordDigest: association?.recordDigest, detail: error.localizedDescription))
            }
        }
        return result
    }

    func deletions() throws -> [SignatureMaterialDeletion] {
        let inventory = try deletionInventory()
        // A failed directory enumeration is not evidence that no deletion is
        // pending. Only the display inventory may keep going past that fault.
        guard inventory.unavailableDirectory == nil else { throw CodeSigner.SigningError.snapshotInvalid }
        return inventory.deletions
    }

    private func decodeDeletion(_ data: Data, at url: URL) throws -> SignatureMaterialDeletion {
        let deletion = try PropertyListDecoder().decode(SignatureMaterialDeletion.self, from: data)
        let target = URL(fileURLWithPath: deletion.targetPath).standardizedFileURL
        guard url.lastPathComponent == deletion.id.uuidString + ".plist", target.path == deletion.targetPath,
              deletion.parentIdentity.isResolved, deletion.targetIdentity.isResolved,
              deletion.recordParentIdentity?.isResolved != false,
              deletion.manifest.rootIdentity.matchesFilesystemObject(deletion.targetIdentity),
              (deletion.targetLocation.map { $0.identity.matchesFilesystemObject(deletion.parentIdentity)
                  && $0.path == target.deletingLastPathComponent().path
                  && target.lastPathComponent.hasPrefix("original-") && target.pathExtension == "app" }
                ?? (target.deletingLastPathComponent() == directoryURL.standardizedFileURL
                    || target.deletingLastPathComponent() == directoryURL.appendingPathComponent("retired").standardizedFileURL)),
              deletion.recordPath.map({ containsRecord(URL(fileURLWithPath: $0)) }) != false else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        return deletion
    }

    func removeDeletion(_ deletion: SignatureMaterialDeletion) throws {
        let url = cleanupDirectoryURL.appendingPathComponent(deletion.id.uuidString + ".plist")
        guard try decodeDeletion(SignatureRecordFile.data(at: url), at: url) == deletion else {
            throw CodeSigner.SigningError.applicationChanged
        }
        try FileManager.default.removeItem(at: url)
        try DurableFileIO.syncDirectory(at: cleanupDirectoryURL)
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
    }

    func containsRecord(_ url: URL) -> Bool {
        url.pathExtension == "plist" && (url.deletingLastPathComponent().standardizedFileURL.path == directoryURL.standardizedFileURL.path
            || url.deletingLastPathComponent().standardizedFileURL.path == directoryURL.appendingPathComponent("retired").standardizedFileURL.path)
    }
}
