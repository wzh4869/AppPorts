import CryptoKit
import Darwin
import Foundation

/// Bundle copy and content primitives shared by temporary signing operations
/// and compatibility reads of historical complete originals.
enum SignatureSnapshot {
    /// Capability injection exercises the actual legacy copy path without
    /// pretending that the host OS itself is an older macOS release.
    typealias StateSetter = @Sendable (copyfile_state_t, UInt32, UnsafeRawPointer) -> Int32

    /// Fill an exclusively created, recorded root without changing its identity.
    /// Child copies may use clonefile; capacity must still allow ordinary copies.
    static func copyContents(from source: URL, into destination: URL, allowCloning: Bool = true,
                             onDataCopied: (@Sendable (URL, Int64) -> Void)? = nil,
                             stateSetter: @escaping StateSetter = { copyfile_state_set($0, $1, $2) }) throws {
        if try !supportsBoundedRecursiveCopy(using: stateSetter, at: source) || hasLargeResourceFork(in: source) {
            try SignatureCompatibilityCopy.copy(from: source, to: destination, intoExistingRoot: true,
                allowCloning: allowCloning, onDataCopied: onDataCopied)
            return
        }
        let identity = try DataPathIdentity.capture(destination)
        guard try info(at: source).st_mode & S_IFMT == S_IFDIR,
              try info(at: destination).st_mode & S_IFMT == S_IFDIR,
              try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try Task.checkCancellation()
            guard try DataPathIdentity.capture(destination).matchesFilesystemObject(identity) else {
                throw CodeSigner.SigningError.applicationChanged
            }
            try copy(from: source.appendingPathComponent(name), to: destination.appendingPathComponent(name),
                     allowCloning: allowCloning, onDataCopied: onDataCopied, stateSetter: stateSetter)
        }
        guard try DataPathIdentity.capture(destination).matchesFilesystemObject(identity) else {
            throw CodeSigner.SigningError.applicationChanged
        }
        try copyUsingSystem(from: source, to: destination,
                            flags: copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC),
                            onDataCopied: onDataCopied, stateSetter: stateSetter)
    }

    static func entryExists(_ url: URL) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 { return true }
        guard errno == ENOENT else { throw posixError(at: url) }
        return false
    }

    static func copy(from source: URL, to destination: URL, allowCloning: Bool = true,
                     onDataCopied: (@Sendable (URL, Int64) -> Void)? = nil,
                     stateSetter: @escaping StateSetter = { copyfile_state_set($0, $1, $2) }) throws {
        if try !supportsBoundedRecursiveCopy(using: stateSetter, at: source) || hasLargeResourceFork(in: source) {
            try SignatureCompatibilityCopy.copy(from: source, to: destination, intoExistingRoot: false,
                allowCloning: allowCloning, onDataCopied: onDataCopied)
            return
        }
        // A nested mounted volume is not owned by this bundle's transaction.
        _ = try items(in: source)
        // CLONE 在支持的文件系统上使用写时复制，不支持时 copyfile 正常复制；不跟随链接。
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC)
        if allowCloning {
            do {
                try copyUsingSystem(from: source, to: destination, flags: flags | copyfile_flags_t(COPYFILE_CLONE),
                                    onDataCopied: onDataCopied, stateSetter: stateSetter)
                return
            } catch is CancellationError {
                // The owning operation retains and later cleans this candidate.
                // Cancellation must never start a second ordinary-copy attempt.
                throw CancellationError()
            } catch {
                // Only inherited permission/lock metadata errors justify this
                // historical retry. Mount/identity/I/O errors must not launch
                // another whole-tree copy after a safety check has failed.
                let failure = error as NSError
                guard failure.domain == NSPOSIXErrorDomain,
                      [Int(EPERM), Int(EACCES)].contains(failure.code) else { throw error }
                try Task.checkCancellation()
                try remove(destination)
            }
        }
        try copyUsingSystem(from: source, to: destination, flags: flags, onDataCopied: onDataCopied, stateSetter: stateSetter)
    }

    private static func supportsBoundedRecursiveCopy(using setter: StateSetter, at source: URL) throws -> Bool {
        try Task.checkCancellation()
        guard let state = copyfile_state_alloc() else { throw posixError(at: source) }
        defer { copyfile_state_free(state) }
        func probe(_ flag: UInt32, _ value: UnsafeRawPointer) throws -> Bool {
            if setter(state, flag, value) == 0 { return true }
            // EINVAL is the documented response to an unknown state option.
            // Other failures are real errors, not permission to weaken guards.
            guard errno == EINVAL else { throw posixError(at: source) }
            return false
        }
        var bufferBytes: UInt32 = 1_048_576
        var forbidCrossMount = true
        let buffer = try probe(UInt32(COPYFILE_STATE_BSIZE), &bufferBytes)
        let mount = try probe(UInt32(COPYFILE_STATE_FORBID_CROSS_MOUNT), &forbidCrossMount)
        return buffer && mount
    }

    private static func hasLargeResourceFork(in source: URL) throws -> Bool {
        // BSIZE bounds the data fork only. Some libcopyfile versions supporting
        // both new state options still allocate an entire resource fork as one
        // xattr. Include hidden compression forks in this pre-write decision.
        for item in try items(in: source) {
            try Task.checkCancellation()
            let size = getxattr(item.path, ResourceForkStream.attributeName, nil, 0, 0,
                                XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION)
            if size > FileDataCopyStream.bufferByteCount { return true }
            if size < 0, errno != ENOATTR, errno != ENOTSUP { throw posixError(at: item) }
        }
        return false
    }

    private final class CopyContext {
        let onDataCopied: (@Sendable (URL, Int64) -> Void)?
        let stateSetter: StateSetter
        var cancelled = false
        var failureCode: Int32?

        init(onDataCopied: (@Sendable (URL, Int64) -> Void)?, stateSetter: @escaping StateSetter) {
            self.onDataCopied = onDataCopied
            self.stateSetter = stateSetter
        }
    }

    /// copyfile's data callback runs after each write, including its own clone
    /// fallback. Recursive-entry callbacks also stop long trees of tiny files.
    private static func copyUsingSystem(from source: URL, to destination: URL, flags: copyfile_flags_t,
                                        onDataCopied: (@Sendable (URL, Int64) -> Void)?,
                                        stateSetter: @escaping StateSetter) throws {
        try Task.checkCancellation()
        guard let state = copyfile_state_alloc() else { throw posixError(at: destination) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(onDataCopied: onDataCopied, stateSetter: stateSetter)
        let callback: copyfile_callback_t = { what, stage, state, sourcePath, _, rawContext in
            guard let rawContext else { return COPYFILE_QUIT }
            let context = Unmanaged<CopyContext>.fromOpaque(rawContext).takeUnretainedValue()
            if Task.isCancelled {
                context.cancelled = true
                return COPYFILE_QUIT
            }
            if stage == COPYFILE_ERR {
                // CONTINUE would retry/ignore some copy errors. Keep the original
                // errno because recursive QUIT does not necessarily set one.
                context.failureCode = context.failureCode ?? (errno == 0 ? EIO : errno)
                return COPYFILE_QUIT
            }
            if stage == COPYFILE_START, let state {
                // Recursive copies supply a fresh child state to this event.
                var bufferBytes: UInt32 = 1_048_576
                if context.stateSetter(state, UInt32(COPYFILE_STATE_BSIZE), &bufferBytes) != 0 {
                    context.failureCode = errno == 0 ? EIO : errno
                    return COPYFILE_QUIT
                }
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS,
               let sourcePath, let state, let progress = context.onDataCopied {
                var copied: off_t = 0
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) != 0 {
                    context.failureCode = errno == 0 ? EIO : errno
                    return COPYFILE_QUIT
                }
                progress(URL(fileURLWithPath: String(cString: sourcePath)), Int64(copied))
            }
            if Task.isCancelled {
                context.cancelled = true
                return COPYFILE_QUIT
            }
            return COPYFILE_CONTINUE
        }
        // A bounded copy buffer also bounds the ordinary-copy cancellation
        // interval. The context is used only synchronously inside this call.
        var bufferBytes: UInt32 = 1_048_576
        var forbidCrossMount = true
        guard stateSetter(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
              stateSetter(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque()) == 0,
              stateSetter(state, UInt32(COPYFILE_STATE_FORBID_CROSS_MOUNT), &forbidCrossMount) == 0,
              stateSetter(state, UInt32(COPYFILE_STATE_BSIZE), &bufferBytes) == 0 else {
            throw posixError(at: destination)
        }
        let result = copyfile(source.path, destination.path, state, flags)
        let failureCode = context.failureCode ?? errno
        if context.cancelled || (result != 0 && failureCode == ECANCELED) { throw CancellationError() }
        try Task.checkCancellation()
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureCode), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    static func items(in root: URL) throws -> [URL] {
        try itemsWithInfo(in: root).map(\.url)
    }

    static func itemsWithInfo(in root: URL) throws -> [(url: URL, info: stat)] {
        // 按相对文件名构造 URL，避免 DirectoryEnumerator 把 /var 转成 /private/var，
        // 造成源路径和副本的相对路径摘要不一致。
        var result: [(url: URL, info: stat)] = []
        var pending = [root]
        let rootInfo = try info(at: root)
        try requireOrdinaryRoot(root, info: rootInfo)
        while let item = pending.popLast() {
            try Task.checkCancellation()
            let current = try info(at: item)
            guard current.st_dev == rootInfo.st_dev else { throw TreeCopyError.mountBoundary(item.path) }
            result.append((item, current))
            if current.st_mode & S_IFMT == S_IFDIR {
                let names = try FileManager.default.contentsOfDirectory(atPath: item.path)
                pending.append(contentsOf: names.map { item.appendingPathComponent($0) })
            }
        }
        return result.sorted { $0.url.path < $1.url.path }
    }

    /// The mounted root itself cannot be owned as an ordinary app directory.
    static func requireOrdinaryRoot(_ root: URL, info rootInfo: stat) throws {
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { return }
        var parent = stat()
        guard stat(root.deletingLastPathComponent().path, &parent) == 0 else { throw posixError(at: root) }
        guard rootInfo.st_dev == parent.st_dev else { throw TreeCopyError.mountBoundary(root.path) }
    }

    static func info(at url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw posixError(at: url) }
        return value
    }

    /// 路径无关的内容摘要：移动应用不会失效；更新、丢失文件或签名属性变化会失效。
    /// 不包含时间戳、quarantine 等系统会自行修改的元数据；所有读取失败均中止操作。
    static func fingerprint(of root: URL) throws -> String {
        var hash = SHA256()
        for (url, itemStat) in try itemsWithInfo(in: root) {
            try Task.checkCancellation()
            try updateFingerprintHash(&hash, rootPathCount: root.path.count, url: url, info: itemStat)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func singleNodeFingerprint(at url: URL, info itemStat: stat) throws -> String {
        guard (itemStat.st_mode & S_IFMT) != S_IFDIR else {
            return try fingerprint(of: url)
        }
        var hash = SHA256()
        try updateFingerprintHash(&hash, rootPathCount: url.path.count, url: url, info: itemStat)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func updateFingerprintHash(_ hash: inout SHA256, rootPathCount: Int, url: URL, info itemStat: stat) throws {
        func field(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        let kind = itemStat.st_mode & S_IFMT
        field(Data(url.path.dropFirst(rootPathCount).utf8))
        field(Data(String(kind).utf8))
        field(Data(String(itemStat.st_mode & 0o7777).utf8))
        switch kind {
        case S_IFREG:
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var contents = SHA256()
            while true {
                try Task.checkCancellation()
                // FileHandle 的 NSData 桥接会延迟释放；逐块排空，避免多次应用校验
                // 把累计读取的 GB 级数据留在同一个同步 actor 任务的自动释放池中。
                let hasData = try autoreleasepool {
                    guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else {
                        return false
                    }
                    contents.update(data: data)
                    return true
                }
                if !hasData { break }
            }
            field(Data(contents.finalize()))
        case S_IFLNK:
            field(Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
        case S_IFDIR:
            break
        default:
            throw CodeSigner.SigningError.backupFailed("应用包含无法备份的特殊文件".localized)
        }
        // 脚本等非 Mach-O 代码的签名保存在 com.apple.cs.* 属性中。
        let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if count < 0 {
            if errno == ENOTSUP { field(Data("0".utf8)); return }
            throw posixError(at: url)
        }
        var names = [CChar](repeating: 0, count: count)
        let read = names.withUnsafeMutableBufferPointer {
            listxattr(url.path, $0.baseAddress, count, XATTR_NOFOLLOW)
        }
        guard read >= 0 else { throw posixError(at: url) }
        let attributes = names.prefix(read).split(separator: 0).map {
            String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }.filter {
            $0.hasPrefix("com.apple.cs.") || $0 == "com.apple.ResourceFork" || $0 == "com.apple.FinderInfo"
        }.sorted()
        field(Data(String(attributes.count).utf8))
        for name in attributes {
            try Task.checkCancellation()
            field(Data(name.utf8))
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { throw posixError(at: url) }
            if name == ResourceForkStream.attributeName {
                let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else { throw posixError(at: url) }
                defer { close(parent) }
                let descriptor = openat(parent, url.lastPathComponent,
                    O_RDONLY | O_CLOEXEC | (kind == S_IFLNK ? O_SYMLINK : O_NOFOLLOW))
                guard descriptor >= 0 else { throw posixError(at: url) }
                defer { close(descriptor) }
                var before = stat()
                guard fstat(descriptor, &before) == 0 else { throw posixError(at: url) }
                guard before.st_dev == itemStat.st_dev, before.st_ino == itemStat.st_ino else {
                    throw CodeSigner.SigningError.applicationChanged
                }
                let fork = ResourceForkStream.Handle(fileDescriptor: descriptor, parentDescriptor: parent,
                    name: url.lastPathComponent, path: url.path)
                guard try fork.size() == Int64(size) else { throw CodeSigner.SigningError.applicationChanged }
                // Preserve the historical field format: UInt64 length,
                // then the raw bytes, rather than a hash of the fork hash.
                var length = UInt64(size).bigEndian
                withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
                try ResourceForkStream.forEachChunk(in: fork, byteCount: Int64(size)) { hash.update(bufferPointer: $0) }
                var after = before
                guard fstat(descriptor, &after) == 0 else { throw posixError(at: url) }
                guard try fork.size() == Int64(size), before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                    throw CodeSigner.SigningError.applicationChanged
                }
                continue
            }
            var data = Data(count: size)
            let readSize = data.withUnsafeMutableBytes {
                getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
            guard readSize == size else { throw posixError(at: url) }
            field(data)
        }
    }

    /// codesign --deep 不能通过工作副本里的链接修改包外代码（包括原应用）。
    static func validateLinksForSigning(in root: URL) throws {
        let rootStandardized = root.standardizedFileURL.path
        let resolvedRoot = (DiskUtility.resolvedPath(root.path) ?? root.resolvingSymlinksInPath().path)
        let resolvedPrefix = resolvedRoot + "/"
        let lexicalPrefix = rootStandardized + "/"
        for (url, itemInfo) in try itemsWithInfo(in: root) where itemInfo.st_mode & S_IFMT == S_IFLNK {
            let raw = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let lexical = URL(fileURLWithPath: raw, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
            guard lexical.path != rootStandardized,
                  lexical.path.hasPrefix(lexicalPrefix),
                  resolvedTargetincludingMissing(lexical).hasPrefix(resolvedPrefix) else {
                throw CodeSigner.SigningError.codesignFailed("应用包含指向包外的符号链接，已停止重签名以保护原始文件。".localized)
            }
        }
    }

    private static func resolvedTargetincludingMissing(_ target: URL) -> String {
        var current = target.standardizedFileURL
        var trailing: [String] = []
        while current.path != "/" {
            if let real = DiskUtility.resolvedPath(current.path) {
                if trailing.isEmpty { return real }
                return (real == "/" ? "" : real) + "/" + trailing.reversed().joined(separator: "/")
            }
            trailing.append(current.lastPathComponent)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return target.resolvingSymlinksInPath().path
    }

    /// 同卷交换，失败时两边都保持原样。明确拒绝不支持该能力的存储，不降级为先删后复制。
    static func exchange(_ current: URL, _ replacement: URL) throws {
        guard renameatx_np(AT_FDCWD, current.path, AT_FDCWD, replacement.path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOTSUP || errno == EXDEV {
                throw CodeSigner.SigningError.atomicReplacementUnavailable
            }
            throw posixError(at: current)
        }
    }

    /// 仅用于我们自己创建的快照和工作副本；不跟随链接解除 uchg。
    static func remove(_ root: URL) throws {
        guard try entryExists(root) else { return }
        let items = try itemsWithInfo(in: root)
        var byPath: [String: stat] = [:]
        var children: [String: [(name: String, path: String)]] = [:]
        for (url, info) in items {
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK else {
                throw CodeSigner.SigningError.snapshotInvalid
            }
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            byPath[relative] = info
            if !relative.isEmpty {
                let parentPath = (relative as NSString).deletingLastPathComponent
                children[parentPath, default: []].append(((relative as NSString).lastPathComponent, relative))
            }
        }
        guard byPath[""] != nil else { throw CodeSigner.SigningError.snapshotInvalid }
        let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw posixError(at: root.deletingLastPathComponent()) }
        defer { close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0 else { throw posixError(at: root.deletingLastPathComponent()) }
        let expectedDevice = parentInfo.st_dev

        func matches(_ observed: stat, _ expected: stat) -> Bool {
            observed.st_dev == expectedDevice &&
            observed.st_ino == expected.st_ino &&
            (observed.st_mode & S_IFMT) == (expected.st_mode & S_IFMT) &&
            observed.st_birthtimespec.tv_sec == expected.st_birthtimespec.tv_sec &&
            observed.st_birthtimespec.tv_nsec == expected.st_birthtimespec.tv_nsec &&
            observed.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec &&
            observed.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec &&
            observed.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec &&
            observed.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec &&
            ((expected.st_mode & S_IFMT) != S_IFREG || observed.st_size == expected.st_size)
        }

        func removeNode(parentFD: Int32, name: String, path: String) throws {
            guard let expected = byPath[path] else { throw CodeSigner.SigningError.snapshotInvalid }
            let kind = expected.st_mode & S_IFMT
            let nodeURL = path.isEmpty ? root : root.appendingPathComponent(path)
            var observed = stat()
            guard fstatat(parentFD, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(at: nodeURL) }
            guard observed.st_dev == expectedDevice else { throw TreeCopyError.mountBoundary(path) }
            guard matches(observed, expected) else { throw CodeSigner.SigningError.applicationChanged }
            if kind == S_IFLNK {
                guard unlinkat(parentFD, name, 0) == 0 else { throw posixError(at: nodeURL) }
                return
            }
            let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw posixError(at: nodeURL) }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0 else { throw posixError(at: nodeURL) }
            guard opened.st_dev == expectedDevice else { throw TreeCopyError.mountBoundary(path) }
            guard matches(opened, expected) else { throw CodeSigner.SigningError.applicationChanged }
            if opened.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                guard opened.st_nlink == 1 || kind == S_IFDIR,
                      fchflags(fd, opened.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else {
                    throw CodeSigner.SigningError.lockedApplication(nodeURL)
                }
            }
            if kind == S_IFDIR {
                for child in children[path] ?? [] {
                    try removeNode(parentFD: fd, name: child.name, path: child.path)
                }
            }
            guard fstatat(parentFD, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(at: nodeURL) }
            guard observed.st_dev == expectedDevice,
                  observed.st_ino == expected.st_ino,
                  (observed.st_mode & S_IFMT) == kind,
                  observed.st_birthtimespec.tv_sec == expected.st_birthtimespec.tv_sec,
                  observed.st_birthtimespec.tv_nsec == expected.st_birthtimespec.tv_nsec else {
                throw CodeSigner.SigningError.applicationChanged
            }
            guard unlinkat(parentFD, name, kind == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw posixError(at: nodeURL) }
        }
        try removeNode(parentFD: parent, name: root.lastPathComponent, path: "")
    }

    /// Retire a complete original without a partially deleted app remaining in
    /// signature-backups. Child locks do not prevent renaming their parent.
    static func trash(_ root: URL) throws {
        _ = try items(in: root)
        let original = try info(at: root)
        guard [S_IFDIR, S_IFREG].contains(original.st_mode & S_IFMT) else { throw CodeSigner.SigningError.snapshotInvalid }
        let wasLocked = original.st_flags & UInt32(UF_IMMUTABLE) != 0
        if wasLocked, lchflags(root.path, original.st_flags & ~UInt32(UF_IMMUTABLE)) != 0 { throw posixError(at: root) }
        do {
            try FileManager.default.trashItem(at: root, resultingItemURL: nil)
        } catch {
            if wasLocked, let current = try? info(at: root), current.st_dev == original.st_dev, current.st_ino == original.st_ino {
                _ = lchflags(root.path, original.st_flags)
            }
            throw error
        }
    }

    private static func posixError(at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
