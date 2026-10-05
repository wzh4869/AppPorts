//
//  FileCopier.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Darwin
import Foundation

/// 单次遍历的文件复制器。网络卷最多同时复制 4 个普通文件，避免小文件的
/// 元数据往返完全串行，也避免为整棵目录树预先创建任务或统计大小。
actor FileCopier {
    struct Progress: Sendable {
        let copiedBytes: Int64
        /// 复制期间为调用者已有的大小估算（0 表示未知），完成时为实际复制字节数。
        let totalBytes: Int64
        let currentFile: String

        var percentage: Double {
            totalBytes > 0 ? min(1, max(0, Double(copiedBytes) / Double(totalBytes))) : 0
        }
    }

    typealias ProgressHandler = @Sendable (Progress) async -> Void
    typealias CopyOperation = @Sendable (URL, URL) async throws -> Void
    typealias NetworkVolumeDetector = @Sendable (URL) -> Bool
    typealias Clock = @Sendable () -> TimeInterval

    private let fileManager = FileManager.default
    private let networkVolumeDetector: NetworkVolumeDetector
    private let copyOperation: CopyOperation
    private let clock: Clock
    private let progressUpdateThreshold: Int64 = 5 * 1024 * 1024
    private let itemCountThreshold = 50
    private let progressUpdateInterval: TimeInterval = 0.2

    init(
        networkVolumeDetector: @escaping NetworkVolumeDetector = { FileCopier.isNetworkVolume(at: $0) },
        copyOperation: @escaping CopyOperation = { try await FileCopier.copyWithRetry(at: $0, to: $1) },
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.networkVolumeDetector = networkVolumeDetector
        self.copyOperation = copyOperation
        self.clock = clock
    }

    /// estimatedTotalBytes 可复用扫描列表已有的大小，复制器不会为了进度另扫一遍目录。
    /// removeQuarantine 仅供应用迁移使用，不影响其他扩展属性或源文件。
    @discardableResult
    func copyDirectory(
        from source: URL,
        to destination: URL,
        estimatedTotalBytes: Int64? = nil,
        removeQuarantine: Bool = false,
        progressHandler: ProgressHandler?
    ) async throws -> Int64 {
        try Task.checkCancellation()
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        let operationID = AppLogger.shared.makeOperationID(prefix: "file-copy")
        var state = CopyState(totalBytes: max(0, estimatedTotalBytes ?? 0), lastReportedAt: clock())

        // 在读取源目录之前先让界面显示当前操作；NAS 目录查询本身也可能较慢。
        await progressHandler?(Progress(copiedBytes: 0, totalBytes: state.totalBytes, currentFile: source.lastPathComponent))

        do {
            let sourceValues = try source.resourceValues(forKeys: [.fileResourceTypeKey, .fileSizeKey])
            guard source != destination else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }

            let concurrentCopies = networkVolumeDetector(source) || networkVolumeDetector(destination) ? 4 : 1
            AppLogger.shared.logContext(
                "FileCopier 开始复制",
                details: [
                    ("operation_id", operationID),
                    ("source", source.path),
                    ("destination", destination.path),
                    ("max_concurrent_copies", String(concurrentCopies)),
                    ("estimated_total_bytes", String(state.totalBytes)),
                    ("remove_quarantine", removeQuarantine ? "true" : "false")
                ],
                level: "TRACE"
            )

            switch sourceValues.fileResourceType {
            case .directory:
                let resolvedSource = source.resolvingSymlinksInPath().path
                let resolvedDestination = destination.resolvingSymlinksInPath().path
                guard resolvedDestination != resolvedSource,
                      !resolvedDestination.hasPrefix(resolvedSource == "/" ? "/" : resolvedSource + "/") else {
                    throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: destination.path])
                }
                try await copyContents(
                    from: source,
                    to: destination,
                    concurrentCopies: concurrentCopies,
                    removeQuarantine: removeQuarantine,
                    state: &state,
                    progressHandler: progressHandler
                )
            case .regular:
                var destinationInfo = stat()
                guard lstat(destination.path, &destinationInfo) != 0 else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
                }
                state.totalBytes = Int64(sourceValues.fileSize ?? 0)
                await progressHandler?(Progress(copiedBytes: 0, totalBytes: state.totalBytes, currentFile: source.lastPathComponent))
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let result = try await Self.copyFile(
                    from: source,
                    to: destination,
                    size: state.totalBytes,
                    removeQuarantine: removeQuarantine,
                    operation: copyOperation
                )
                state.copiedBytes = result.bytes
                state.copiedItems = 1
            case .symbolicLink:
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.copySymbolicLink(from: source, to: destination, removeQuarantine: removeQuarantine)
                state.copiedItems = 1
            case .socket:
                break
            default:
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: source.path])
            }

            try Task.checkCancellation()
            await progressHandler?(Progress(copiedBytes: state.copiedBytes, totalBytes: state.copiedBytes, currentFile: ""))
            AppLogger.shared.logContext(
                "FileCopier 完成复制",
                details: [
                    ("operation_id", operationID),
                    ("copied_bytes", String(state.copiedBytes)),
                    ("copied_items", String(state.copiedItems)),
                    ("source", source.path),
                    ("destination", destination.path)
                ],
                level: "TRACE"
            )
            return state.copiedBytes
        } catch {
            AppLogger.shared.logError(
                "FileCopier 复制失败",
                error: error,
                context: [("operation_id", operationID), ("source", source.path), ("destination", destination.path)]
            )
            throw error
        }
    }

    /// 对尚未创建的目标逐级查询父目录；statfs 会解析挂载点与父路径中的符号链接。
    nonisolated static func isNetworkVolume(at url: URL) -> Bool {
        var current = url.standardizedFileURL
        while true {
            var fileSystem = statfs()
            if statfs(current.path, &fileSystem) == 0 {
                return fileSystem.f_flags & UInt32(MNT_LOCAL) == 0
            }
            guard errno == ENOENT || errno == ENOTDIR else { return false }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { return false }
            current = parent
        }
    }

    /// 仅用于调用者明确拥有的迁移副本。源目录的只读权限也会被复制，
    /// 清理时临时允许其所有者遍历和删除；不改变符号链接指向的项目。
    nonisolated static func removeCopy(at url: URL) throws {
        let url = url.standardizedFileURL
        let fileManager = FileManager.default
        var rootInfo = stat()
        guard lstat(url.path, &rootInfo) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else {
            try fileManager.removeItem(at: url)
            return
        }

        var changedDirectories: [DirectoryPermissions] = []
        do {
            try prepareDirectoryForRemoval(at: url, info: rootInfo, changedDirectories: &changedDirectories)
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            for case let item as URL in enumerator {
                var info = stat()
                guard lstat(item.path, &info) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: item.path])
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    try prepareDirectoryForRemoval(at: item, info: info, changedDirectories: &changedDirectories)
                }
            }
            if let enumerationError { throw enumerationError }
            try fileManager.removeItem(at: url)
        } catch {
            // 部分删除失败时，先恢复仍存在的子目录，再恢复父目录。
            // 用 inode/device 确认仍是原项目，避免修改同一路径下的替换文件。
            for directory in changedDirectories.reversed() {
                var info = stat()
                if lstat(directory.url.path, &info) == 0,
                   info.st_mode & S_IFMT == S_IFDIR,
                   info.st_ino == directory.inode,
                   info.st_dev == directory.device {
                    _ = lchmod(directory.url.path, directory.mode)
                }
            }
            throw error
        }
    }

    private struct DirectoryPermissions {
        let url: URL
        let mode: mode_t
        let inode: ino_t
        let device: dev_t
    }

    nonisolated private static func prepareDirectoryForRemoval(
        at url: URL,
        info: stat,
        changedDirectories: inout [DirectoryPermissions]
    ) throws {
        let originalMode = info.st_mode & 0o7777
        let removableMode = originalMode | 0o700
        guard removableMode != originalMode else { return }
        guard lchmod(url.path, removableMode) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        changedDirectories.append(DirectoryPermissions(url: url, mode: originalMode, inode: info.st_ino, device: info.st_dev))
    }

    private struct CopyState {
        var copiedBytes: Int64 = 0
        var copiedItems = 0
        var lastReportedBytes: Int64 = 0
        var itemsSinceLastReport = 0
        var totalBytes: Int64
        var lastReportedAt: TimeInterval
    }

    private struct CopiedFile: Sendable {
        let bytes: Int64
        let name: String
    }

    private struct DirectoryMetadata {
        let source: URL
        let destination: URL
        let attributes: [FileAttributeKey: Any]
        let groupOwnerID: gid_t?
    }

    private func copyContents(
        from source: URL,
        to destination: URL,
        concurrentCopies: Int,
        removeQuarantine: Bool,
        state: inout CopyState,
        progressHandler: ProgressHandler?
    ) async throws {
        var directories = [try directoryMetadata(from: source, to: destination)]
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.createDestinationDirectory(at: destination)

        var enumerationError: Error?
        let keys: [URLResourceKey] = [.fileResourceTypeKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: source.path])
        }
        let operation = copyOperation

        try await withThrowingTaskGroup(of: CopiedFile.self) { group in
            var pendingCopies = 0
            do {
                while let item = enumerator.nextObject() as? URL {
                    try Task.checkCancellation()
                    let values = try item.resourceValues(forKeys: Set(keys))
                    if Self.isManagedLinkMetadataFile(item.lastPathComponent) {
                        if values.fileResourceType == .directory { enumerator.skipDescendants() }
                        continue
                    }
                    // Foundation 可能把 /var 等祖先软链展开为 /private/var。
                    // 使用枚举层级取相对组件，不依赖源 URL 与枚举 URL 的前缀长度。
                    let relativePath = item.pathComponents.suffix(enumerator.level).joined(separator: "/")
                    let target = destination.appendingPathComponent(relativePath)

                    switch values.fileResourceType {
                    case .directory:
                        directories.append(try directoryMetadata(from: item, to: target))
                        try Self.createDestinationDirectory(at: target)
                        await recordCompletion(bytes: 0, name: item.lastPathComponent, state: &state, progressHandler: progressHandler)
                    case .symbolicLink:
                        try Self.copySymbolicLink(from: item, to: target, removeQuarantine: removeQuarantine)
                        await recordCompletion(bytes: 0, name: item.lastPathComponent, state: &state, progressHandler: progressHandler)
                    case .socket:
                        AppLogger.shared.logContext("跳过 socket 文件", details: [("path", item.path)], level: "TRACE")
                    case .regular:
                        let size = Int64(values.fileSize ?? 0)
                        if concurrentCopies == 1 {
                            let result = try await Self.copyFile(from: item, to: target, size: size, removeQuarantine: removeQuarantine, operation: operation)
                            await recordCompletion(bytes: result.bytes, name: result.name, state: &state, progressHandler: progressHandler)
                        } else {
                            if pendingCopies == concurrentCopies, let result = try await group.next() {
                                pendingCopies -= 1
                                await recordCompletion(bytes: result.bytes, name: result.name, state: &state, progressHandler: progressHandler)
                            }
                            group.addTask {
                                try await Self.copyFile(from: item, to: target, size: size, removeQuarantine: removeQuarantine, operation: operation)
                            }
                            pendingCopies += 1
                        }
                    default:
                        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: item.path])
                    }
                }
                if let enumerationError { throw enumerationError }
                while let result = try await group.next() {
                    await recordCompletion(bytes: result.bytes, name: result.name, state: &state, progressHandler: progressHandler)
                }
            } catch {
                group.cancelAll()
                // 同步文件 I/O 不能立即取消。等待所有在途写入结束后再抛出，
                // 上层才能安全删除半成品，避免有任务在清理之后重新写回目标。
                while let _ = await group.nextResult() {}
                throw error
            }
        }

        // 子项的创建会改变父目录时间；延后恢复，也允许复制只读目录的内容。
        var groupRestoreFailures = 0
        var firstGroupRestoreError: (path: String, code: Int32)?
        for directory in directories.reversed() {
            try Task.checkCancellation()
            // mkdir 默认继承目标父目录的组，需恢复源目录的组归属。
            // 网络卷可能不支持 chgrp；属组单独尽力保留，不让它阻断数据复制。
            // chown 可能清除 setgid，所以必须先于后面的 mode 恢复执行。
            if let groupID = directory.groupOwnerID,
               lchown(directory.destination.path, uid_t.max, groupID) != 0 {
                groupRestoreFailures += 1
                if firstGroupRestoreError == nil {
                    firstGroupRestoreError = (directory.destination.path, errno)
                }
            }
            Self.copyDirectoryExtendedAttributes(from: directory.source, to: directory.destination, removeQuarantine: removeQuarantine)
            try fileManager.setAttributes(directory.attributes, ofItemAtPath: directory.destination.path)
            try Self.copyDirectoryACL(from: directory.source, to: directory.destination)
            await reportProgressIfNeeded(name: directory.source.lastPathComponent, state: &state, progressHandler: progressHandler)
        }
        if let firstGroupRestoreError {
            AppLogger.shared.logContext(
                "部分目录的组归属无法保留",
                details: [
                    ("directory_count", String(groupRestoreFailures)),
                    ("destination", firstGroupRestoreError.path),
                    ("errno", String(firstGroupRestoreError.code))
                ],
                level: "WARN"
            )
        }
    }

    private func directoryMetadata(from source: URL, to destination: URL) throws -> DirectoryMetadata {
        let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
        let retainedKeys: Set<FileAttributeKey> = [.posixPermissions, .creationDate, .modificationDate]
        return DirectoryMetadata(
            source: source,
            destination: destination,
            attributes: sourceAttributes.filter { retainedKeys.contains($0.key) },
            groupOwnerID: (sourceAttributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value
        )
    }

    private func recordCompletion(bytes: Int64, name: String, state: inout CopyState, progressHandler: ProgressHandler?) async {
        state.copiedBytes += bytes
        state.copiedItems += 1
        state.itemsSinceLastReport += 1
        await reportProgressIfNeeded(name: name, state: &state, progressHandler: progressHandler)
    }

    private func reportProgressIfNeeded(name: String, state: inout CopyState, progressHandler: ProgressHandler?) async {
        let now = clock()
        if state.copiedBytes - state.lastReportedBytes >= progressUpdateThreshold
            || state.itemsSinceLastReport >= itemCountThreshold
            || now - state.lastReportedAt >= progressUpdateInterval {
            await progressHandler?(Progress(copiedBytes: state.copiedBytes, totalBytes: state.totalBytes, currentFile: name))
            state.lastReportedBytes = state.copiedBytes
            state.itemsSinceLastReport = 0
            state.lastReportedAt = now
        }
    }

    nonisolated private static func createDestinationDirectory(at destination: URL) throws {
        guard mkdir(destination.path, 0o777) != 0 else { return }
        let creationError = errno
        if creationError == EEXIST {
            var info = stat()
            // 不能把已有的目录软链当成目标目录穿透写入。
            if lstat(destination.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(creationError), userInfo: [NSFilePathErrorKey: destination.path])
    }

    nonisolated private static func copyFile(
        from source: URL,
        to destination: URL,
        size: Int64,
        removeQuarantine: Bool,
        operation: CopyOperation
    ) async throws -> CopiedFile {
        try Task.checkCancellation()
        // FileManager 的原生复制保留权限、日期和扩展属性，无需再次 stat/chmod。
        try await operation(source, destination)
        if removeQuarantine { removeCopiedQuarantine(from: source, to: destination) }
        try Task.checkCancellation()
        return CopiedFile(bytes: size, name: source.lastPathComponent)
    }

    nonisolated private static func copySymbolicLink(from source: URL, to destination: URL, removeQuarantine: Bool) throws {
        // copyItem 复制链接本身，保留相对路径，也支持悬空链接。
        try FileManager.default.copyItem(at: source, to: destination)
        if removeQuarantine { removeCopiedQuarantine(from: source, to: destination) }
    }

    nonisolated private static func copyWithRetry(at source: URL, to destination: URL) async throws {
        let fileManager = FileManager.default
        for attempt in 1...3 {
            try Task.checkCancellation()
            do {
                try fileManager.copyItem(at: source, to: destination)
                return
            } catch {
                let nsError = error as NSError
                let errors = [nsError] + nsError.underlyingErrors.map { $0 as NSError }
                let interrupted = errors.contains { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EINTR) }
                let alreadyExists = errors.contains {
                    ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteFileExistsError)
                        || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(EEXIST))
                }
                guard attempt < 3, interrupted || alreadyExists else { throw error }

                var destinationInfo = stat()
                if lstat(destination.path, &destinationInfo) == 0,
                   destinationInfo.st_mode & S_IFMT == S_IFDIR {
                    throw error
                }

                // 仅在复制确实报告冲突/中断时清理，不再为每个小文件查询目标是否存在。
                // 无法替换的普通文件必须失败，不能静默跳过后让上层删除源。
                do {
                    try fileManager.removeItem(at: destination)
                } catch let cleanupError as NSError {
                    guard cleanupError.domain == NSCocoaErrorDomain && cleanupError.code == NSFileNoSuchFileError else {
                        throw cleanupError
                    }
                }
                if interrupted {
                    AppLogger.shared.logContext("文件复制被中断，重试", details: [("attempt", String(attempt)), ("source", source.path)], level: "WARN")
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                }
            }
        }
    }

    nonisolated private static func removeCopiedQuarantine(from source: URL, to destination: URL) {
        let name = "com.apple.quarantine"
        // 查询源上的属性；没有 quarantine 时不向 NAS 发起无用的删除请求。
        guard getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { return }
        if removexattr(destination.path, name, XATTR_NOFOLLOW) != 0, errno != ENOATTR, errno != ENOTSUP {
            AppLogger.shared.logContext("清除已复制文件的隔离属性失败", details: [("destination", destination.path), ("errno", String(errno))], level: "WARN")
        }
    }

    nonisolated private static func copyDirectoryExtendedAttributes(from source: URL, to destination: URL, removeQuarantine: Bool) {
        let size = listxattr(source.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        let count = listxattr(source.path, &names, size, XATTR_NOFOLLOW)
        guard count > 0 else { return }
        names.withUnsafeBufferPointer { buffer in
            guard var pointer = buffer.baseAddress else { return }
            let end = pointer.advanced(by: count)
            while pointer < end {
                let name = String(cString: pointer)
                pointer = pointer.advanced(by: name.utf8.count + 1)
                if removeQuarantine, name == "com.apple.quarantine" {
                    // 新目录不复制 quarantine；若目标原有该属性，也只在源确有时清除。
                    removexattr(destination.path, name, XATTR_NOFOLLOW)
                    continue
                }
                let valueSize = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard valueSize >= 0 else { continue }
                if valueSize == 0 {
                    setxattr(destination.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                } else {
                    var value = [UInt8](repeating: 0, count: valueSize)
                    let readSize = getxattr(source.path, name, &value, valueSize, 0, XATTR_NOFOLLOW)
                    guard readSize >= 0 else { continue }
                    setxattr(destination.path, name, value, readSize, 0, XATTR_NOFOLLOW)
                }
            }
        }
    }

    nonisolated private static func copyDirectoryACL(from source: URL, to destination: URL) throws {
        var sourceACL = acl_get_file(source.path, ACL_TYPE_EXTENDED)
        if sourceACL == nil {
            if errno == ENOTSUP { return }
            // Darwin uses ENOENT for a present directory with no extended ACL.
            guard errno == ENOENT, FileManager.default.fileExists(atPath: source.path) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            sourceACL = acl_init(0)
        }
        guard let acl = sourceACL else { throw POSIXError(.ENOMEM) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let hasEntries = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
        guard acl_set_file(destination.path, ACL_TYPE_EXTENDED, acl) == 0 else {
            if !hasEntries, errno == ENOTSUP { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard let actual = acl_get_file(destination.path, ACL_TYPE_EXTENDED) else {
            if !hasEntries, errno == ENOENT, FileManager.default.fileExists(atPath: destination.path) { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(actual)) }
        guard let expectedText = acl_to_text(acl, nil), let actualText = acl_to_text(actual, nil) else {
            throw POSIXError(.EIO)
        }
        defer { acl_free(expectedText); acl_free(actualText) }
        guard String(cString: expectedText) == String(cString: actualText) else { throw POSIXError(.EIO) }
    }

    nonisolated private static func isManagedLinkMetadataFile(_ fileName: String) -> Bool {
        fileName == ".appports-link-metadata.plist"
            || (fileName.hasPrefix(".") && fileName.hasSuffix(".appports-link-metadata.plist"))
    }
}
