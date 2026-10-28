import Darwin
import Foundation

/// User choices change the journal only. A retained copy is never called
/// deleted, moved over live data, or silently included in later cleanup.
enum DataCleanupResolution {
    static func currentDataPaths(for transfers: [DataTransferRecord], store: ContainerMountStore = .shared) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: transfers.compactMap { transfer in
            (try? store.completedLocation(after: transfer.operationID)).map { (transfer.operationID, $0.activePath) }
        })
    }

    static func requiresAdministrator(_ transfer: DataTransferRecord) -> Bool {
        guard transfer.mode == .symlink, transfer.isDataSwitchComplete, geteuid() != 0,
              let path = transfer.backupPath,
              let actual = try? TreeCopySession.retainedRemovalURL(at: URL(fileURLWithPath: path), removalID: transfer.operationID) else { return false }
        var info = stat()
        return lstat(actual.path, &info) == 0 && info.st_uid == 0
    }

    static func decide(_ disposition: DataTransferRecord.CleanupDisposition,
                       expected: DataTransferRecord) async throws {
        let lock = OperationLock()
        guard await lock.acquire(timeout: OperationLock.appWaitTimeout) else {
            throw Failure(lock.admissionFailureReason ?? "其他操作正在进行，请稍后重试。".localized)
        }
        defer { lock.release() }
        do {
            try ContainerMountStore.shared.setCleanupDisposition(disposition, expected: expected)
        } catch ContainerMountStore.StoreError.conflict(_) {
            throw Failure("操作状态已更新，请关闭面板后重新打开。现有文件未被改动。".localized)
        }
    }

    /// Resolve a deletion quarantine too: a partial cleanup may have renamed
    /// the root before stopping. Never reveal a replacement at the old name.
    static func retainedURL(for transfer: DataTransferRecord) async throws -> URL {
        guard let path = transfer.backupPath, let expected = transfer.backupIdentity else {
            throw Failure("此操作尚未生成可打开的旧副本，请先重试恢复。".localized)
        }
        let url: URL
        if transfer.mode == .mount && transfer.direction == .restore {
            guard let uuid = expected.volumeUUID else {
                throw Failure("无法确认旧副本所在的磁盘，记录已保留。".localized)
            }
            let info = try await DiskUtility(administratorRunner: nil).volumeInfo(for: uuid)
            guard info.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame,
                  let mount = info.mountPoint, !mount.isEmpty else {
                throw Failure("旧副本所在的卷尚未挂载。请连接外置盘，在“磁盘工具”中解锁并挂载后再打开。".localized)
            }
            url = URL(fileURLWithPath: mount)
        } else {
            guard let retained = try TreeCopySession.retainedRemovalURL(
                at: URL(fileURLWithPath: path), removalID: transfer.operationID) else {
                throw Failure("暂时找不到旧副本。请确认磁盘已连接；也可能文件已清理完成，可重试更新状态。".localized)
            }
            url = retained
        }
        guard try DataPathIdentity.capture(url).matchesFilesystemObject(expected) else {
            throw Failure("此位置的文件夹已发生变化，无法确认它是原来的旧副本。记录已保留。".localized)
        }
        return url
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

struct DataCleanupFailure: LocalizedError, CustomNSError {
    let transfer: DataTransferRecord
    let stage: String
    let underlying: NSError

    static var errorDomain: String { "AppPorts.DataCleanup" }
    var errorCode: Int { underlying.code }
    var errorDescription: String? {
        let detail = DataCleanupResolution.requiresAdministrator(transfer) && Self.isPermissionFailure(underlying)
            ? "旧副本由管理员（root）拥有，需要授权后才能清理。当前数据未受影响。".localized
            : underlying.localizedDescription
        return String(format: "清理旧副本失败：%@\n%@".localized, transfer.backupPath ?? transfer.originalPath, detail)
    }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? underlying.localizedDescription,
         NSUnderlyingErrorKey: underlying,
         OperationBlockage.diagnosticFieldsKey: ["diagnostic_code": "DATA-CLEANUP-FAILED",
            "blocking_operation_id": transfer.operationID.uuidString, "cleanup_stage": stage,
            "cleanup_path": transfer.backupPath ?? transfer.originalPath]]
    }

    static func isPermissionFailure(_ error: Error) -> Bool {
        let native = error as NSError
        return native.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(native.code)
    }
}
