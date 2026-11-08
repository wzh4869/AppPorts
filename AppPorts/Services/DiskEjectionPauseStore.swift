import Darwin
import Foundation

enum DiskEjectionError: LocalizedError {
    case unavailable, busy, paused, invalidState, finder(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法确认外置物理磁盘，请连接磁盘后重试。".localized
        case .busy: return "应用操作正在进行，请稍后重试。".localized
        case .paused: return "此磁盘的自动挂载已暂停。请重新插入设备以恢复自动挂载。".localized
        case .invalidState: return "无法读取弹出状态，已暂停自动恢复。请重试或检查日志。".localized
        case .finder(let detail): return "无法请求 Finder 弹出磁盘。请检查自动化权限后重试。".localized + "\n" + detail
        }
    }
}

/// All writes and reconciliation are made while holding the dataset's OperationLock.
/// This separate document does not change the migration ledger's schema.
struct DiskEjectionPauseStore: Sendable {
    struct ImagePause: Codable, Equatable, Sendable {
        let imagePath: String
        let volumeUUIDs: Set<String>
        let mountPaths: Set<String>
    }

    struct Pause: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let displayName: String
        let connectionID: String
        let volumeUUIDs: Set<String>
        let containerUUIDs: Set<String>
        let mountPaths: Set<String>

        init(disk: ExternalDiskInventory.Disk) {
            id = UUID()
            displayName = disk.displayName
            connectionID = disk.connectionID
            volumeUUIDs = disk.volumeUUIDs
            containerUUIDs = disk.containerUUIDs
            mountPaths = disk.mountPaths
        }
    }

    struct Snapshot: Sendable {
        let pauses: [Pause]
        var images: [ImagePause] = []

        func blocksImage(_ record: AppLibraryImageService.Record) -> Bool {
            blocks(volumeUUIDs: [record.volumeUUID, record.backingVolumeUUID],
                   paths: [record.imagePath, record.libraryPath ?? record.mountPath])
        }

        func blocks(volumeUUIDs: [String?] = [], paths: [String] = [], containerUUID: String? = nil) -> Bool {
            let uuids = Set(volumeUUIDs.compactMap { $0?.uppercased() })
            return images.contains { image in
                !image.volumeUUIDs.isDisjoint(with: uuids)
                    || paths.contains { path in
                        path == image.imagePath || image.mountPaths.contains { root in
                            path == root || path.hasPrefix(root + "/")
                        }
                    }
            } || pauses.contains { pause in
                !pause.volumeUUIDs.isDisjoint(with: uuids)
                    || containerUUID.map { pause.containerUUIDs.contains($0.uppercased()) } == true
                    || paths.contains { path in pause.mountPaths.contains { root in
                        path == root || path.hasPrefix(root + "/")
                    } }
            }
        }

        func blocks(_ transfer: DataTransferRecord) -> Bool {
            blocks(volumeUUIDs: [transfer.createdVolumeUUID, transfer.sourceIdentity.volumeUUID,
                    transfer.destinationIdentity?.volumeUUID, transfer.destinationVolumeUUID,
                    transfer.recoveryMountRecord?.volumeUUID],
                paths: [transfer.originalPath, transfer.activePath, transfer.destinationPath]
                    + [transfer.backupPath, transfer.stagingPath].compactMap { $0 },
                containerUUID: transfer.volumeCreationContainerUUID)
        }

        func blocks(_ backup: SignatureBackup) -> Bool {
            blocks(volumeUUIDs: [backup.applicationIdentity?.volumeUUID, backup.snapshotIdentity?.volumeUUID,
                backup.snapshotLocation?.volumeUUID, backup.applicationParentLocation?.volumeUUID,
                backup.relocation?.sourceIdentity.volumeUUID, backup.relocation?.sourceParentIdentity.volumeUUID,
                backup.relocation?.destination.volumeUUID],
                paths: [backup.originalPath] + [backup.snapshotLocation?.path,
                    backup.applicationParentLocation?.path, backup.relocation?.destination.path].compactMap { $0 })
        }

        func blocks(_ deletion: SignatureMaterialDeletion) -> Bool {
            blocks(volumeUUIDs: [deletion.parentIdentity.volumeUUID, deletion.targetIdentity.volumeUUID,
                deletion.targetLocation?.volumeUUID, deletion.recordParentIdentity?.volumeUUID],
                paths: [deletion.targetPath] + [deletion.targetLocation?.path].compactMap { $0 })
        }
    }

    private struct Document: Codable {
        var schemaVersion = 1
        var pauses: [Pause]
        var images: [ImagePause]?
    }

    let fileURL: URL
    init(directory: URL) { fileURL = directory.appendingPathComponent("disk-ejection-pauses.plist") }
    init(store: ContainerMountStore = .shared) {
        self.init(directory: store.fileURLForDeletionAuthorization.deletingLastPathComponent())
    }

    func snapshot() throws -> Snapshot {
        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return Snapshot(pauses: []) }
            throw DiskEjectionError.invalidState
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 1_048_576 else { throw DiskEjectionError.invalidState }
        do {
            let document = try PropertyListDecoder().decode(Document.self, from: handle.readToEnd() ?? Data())
            let images = document.images ?? []
            guard [1, 2].contains(document.schemaVersion),
                  document.schemaVersion == 2 || images.isEmpty,
                  Set(images.map(\.imagePath)).count == images.count,
                  images.allSatisfy({ $0.imagePath.hasPrefix("/") && !$0.volumeUUIDs.isEmpty
                    && $0.volumeUUIDs.allSatisfy { UUID(uuidString: $0) != nil }
                    && $0.mountPaths.allSatisfy { $0.hasPrefix("/") && $0 != "/" } }),
                  Set(document.pauses.map(\.id)).count == document.pauses.count,
                  Set(document.pauses.map(\.connectionID)).count == document.pauses.count,
                  document.pauses.allSatisfy({ !$0.connectionID.isEmpty && !$0.volumeUUIDs.isEmpty
                    && $0.mountPaths.allSatisfy({ $0.hasPrefix("/") && $0 != "/" }) }) else {
                throw DiskEjectionError.invalidState
            }
            return Snapshot(pauses: document.pauses, images: images)
        } catch { throw DiskEjectionError.invalidState }
    }

    func save(_ pauses: [Pause]) throws {
        try save(pauses, images: snapshot().images)
    }

    private func save(_ pauses: [Pause], images: [ImagePause]) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        // Older agents reject version 2 instead of silently ignoring image pauses.
        let document = Document(schemaVersion: images.isEmpty ? 1 : 2, pauses: pauses,
                                images: images.isEmpty ? nil : images)
        try DurableFileIO.write(try encoder.encode(document), to: fileURL)
    }

    func pauseImage(_ record: AppLibraryImageService.Record, volumeUUIDs: Set<String>, mountPaths: Set<String>) throws {
        let current = try snapshot()
        let previous = current.images.first { $0.imagePath == record.imagePath }
        let uuids = volumeUUIDs.union(previous?.volumeUUIDs ?? [])
            .union([record.volumeUUID].compactMap { $0?.uppercased() })
        guard !uuids.isEmpty, uuids.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw DiskEjectionError.invalidState
        }
        let image = ImagePause(imagePath: record.imagePath, volumeUUIDs: uuids,
            mountPaths: mountPaths.union(previous?.mountPaths ?? []).union([record.libraryPath ?? record.mountPath]))
        try save(current.pauses, images: current.images.filter { $0.imagePath != record.imagePath } + [image])
    }

    /// Only an explicit, successful mount resumes an image; reconnecting its host does not.
    func resumeImage(_ record: AppLibraryImageService.Record) throws {
        let current = try snapshot()
        let images = current.images.filter {
            $0.imagePath != record.imagePath && !($0.volumeUUIDs.contains(record.volumeUUID?.uppercased() ?? ""))
        }
        if images != current.images { try save(current.pauses, images: images) }
    }

    @discardableResult
    func pause(_ disk: ExternalDiskInventory.Disk) throws -> Pause {
        var pauses = try snapshot().pauses
        if let existing = pauses.first(where: { $0.connectionID == disk.connectionID }) { return existing }
        let pause = Pause(disk: disk)
        pauses.append(pause)
        try save(pauses)
        return pause
    }


    /// Missing media or failed queries never clear intent. The same volume UUID
    /// must appear on a different physical connection before resuming automatically.
    @discardableResult
    func reconcile(_ inventory: ExternalDiskInventory) throws -> Snapshot {
        let current = try snapshot()
        let before = current.pauses
        let after = before.filter { pause in
            let matches = inventory.disks.filter { !$0.volumeUUIDs.isDisjoint(with: pause.volumeUUIDs) }
            return matches.count != 1 || matches[0].connectionID == pause.connectionID
        }
        if before != after { try save(after) }
        return Snapshot(pauses: after, images: current.images)
    }

    func refreshed(using disk: DiskUtility) async throws -> Snapshot {
        let current = try snapshot()
        guard !current.pauses.isEmpty else { return current }
        return try reconcile(await disk.ejectionInventory())
    }
}

/// Single-volume intent is independent of whole-disk ejection and reconnection.
enum ManualMountPauseError: LocalizedError {
    case paused, retryPaused
    var errorDescription: String? {
        switch self {
        case .paused: return "自动挂载已暂停。点击“挂载”可恢复。".localized
        case .retryPaused: return "自动挂载已暂停，本次未执行。请先恢复自动挂载后重试。".localized
        }
    }
}
