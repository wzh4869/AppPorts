import Darwin
import Foundation

/// A write barrier for operation records and the trees they commit. Every
/// syscall failure is reported to the caller; unsupported storage never falls
/// back to an atomic rename without a durability barrier.
enum DurableFileIO {
    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let directory = try openDescriptor(parent.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { _ = close(directory) }
        let temporaryName = ".appports-write-\(UUID().uuidString)"
        let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("create temporary record", url) }
        defer { _ = close(descriptor) }
        var published = false
        defer { if !published { _ = unlinkat(directory, temporaryName, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure("write record", url, code: count == 0 ? EIO : errno) }
                offset += count
            }
        }
        try synchronize(descriptor, url: url, full: true)
        var existing = stat()
        if fstatat(directory, url.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw failure("replace non-regular record", url, code: EINVAL) }
        } else if errno != ENOENT {
            throw failure("inspect record", url)
        }
        try requireNamedObject(parent, descriptor: directory)
        guard renameat(directory, temporaryName, directory, url.lastPathComponent) == 0 else {
            throw failure("publish record", url)
        }
        published = true
        try synchronize(directory, url: parent, full: true)
        try requireNamedObject(parent, descriptor: directory)
        try requireNamedObject(url, descriptor: descriptor)
    }

    /// Flushes file contents and metadata, followed by every containing
    /// directory and one device-cache barrier. Traversal does not follow links
    /// and refuses nested mounts or unsupported filesystem nodes.
    ///
    /// `barrier` selects how much durability the caller needs. A tree that is
    /// only published after its own verification does not need a device flush
    /// per file: a power cut leaves a destination the caller re-copies, never
    /// one it switches to. Every node still checks cancellation and reports
    /// progress, so a long flush can be stopped and is visible to the user.
    static func syncTree(at root: URL, excludingRootEntries: Set<String> = [],
                         allowParentAlias: Bool = false, barrier: TreeSyncBarrier = .full) throws {
        DataTransferSession.progress?.begin(.synchronizing)
        DataTransferSession.progress?.startTraversal(at: root)
        let descriptor = try openDescriptor(root.path, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw failure("inspect tree", root) }
        try syncNode(descriptor, url: root, device: status.st_dev,
                     exclusions: excludingRootEntries, barrier: barrier)
        // The root always gets the device-cache barrier: it is the single
        // object whose durability the caller switches on.
        try synchronize(descriptor, url: root, full: true)
        try requireNamedObject(root, descriptor: descriptor)
        try syncDirectory(at: root.deletingLastPathComponent(), resolvingAlias: allowParentAlias)
        try requireNamedObject(root, descriptor: descriptor)
    }

    /// A configured home root may be an ordinary system alias. Callers must
    /// opt in for that exact root; both the alias entry and its resolved target
    /// stay anchored across the barrier. Record writes always remain no-follow.
    static func syncDirectory(at directory: URL, resolvingAlias: Bool = false) throws {
        if resolvingAlias {
            var named = stat()
            guard lstat(directory.path, &named) == 0 else { throw failure("inspect directory alias", directory) }
            let resolved = directory.resolvingSymlinksInPath()
            let descriptor = try openDescriptor(resolved.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            defer { _ = close(descriptor) }
            try requireDirectoryAlias(directory, named: named, resolved: resolved, descriptor: descriptor)
            try synchronize(descriptor, url: directory, full: true)
            try requireDirectoryAlias(directory, named: named, resolved: resolved, descriptor: descriptor)
            return
        }
        let descriptor = try openDescriptor(directory.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { _ = close(descriptor) }
        try synchronize(descriptor, url: directory, full: true)
        try requireNamedObject(directory, descriptor: descriptor)
    }

    private static func syncNode(_ descriptor: Int32, url: URL, device: dev_t, exclusions: Set<String> = [],
                                 barrier: TreeSyncBarrier = .full) throws {
        try Task.checkCancellation()
        DataTransferSession.progress?.activity(file: url.lastPathComponent)
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw failure("inspect tree node", url) }
        guard value.st_dev == device else { throw failure("sync nested mount", url, code: EXDEV) }
        switch value.st_mode & S_IFMT {
        case S_IFREG, S_IFIFO:
            // A FIFO has persistent inode metadata, but no durable byte stream.
            // It was opened with O_NONBLOCK and is never read during the barrier.
            // `.contentDurable` still flushes every directory, so the file's
            // name and inode are committed by its parent's fsync.
            if barrier == .full { try synchronize(descriptor, url: url, full: false) }
        case S_IFDIR:
            let duplicate = dup(descriptor)
            guard duplicate >= 0 else { throw failure("open directory stream", url) }
            guard let stream = fdopendir(duplicate) else {
                let error = failure("open directory stream", url)
                _ = close(duplicate)
                throw error
            }
            defer { _ = closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw failure("read directory", url) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." || exclusions.contains(name) { continue }
                let childURL = url.appendingPathComponent(name)
                var child = stat()
                guard fstatat(descriptor, name, &child, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw failure("inspect directory entry", childURL)
                }
                // Link data is committed by the containing directory's fsync.
                if child.st_mode & S_IFMT == S_IFLNK { continue }
                let childDescriptor = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard childDescriptor >= 0 else { throw failure("open tree node", childURL) }
                var opened = stat()
                guard fstat(childDescriptor, &opened) == 0 else {
                    _ = close(childDescriptor)
                    throw failure("inspect opened node", childURL)
                }
                guard opened.st_dev == child.st_dev, opened.st_ino == child.st_ino else {
                    _ = close(childDescriptor)
                    throw failure("tree node changed", childURL, code: ESTALE)
                }
                defer { _ = close(childDescriptor) }
                try syncNode(childDescriptor, url: childURL, device: device,
                             exclusions: exclusions, barrier: barrier)
            }
            try synchronize(descriptor, url: url, full: false)
        default:
            throw failure("sync unsupported node", url, code: ENOTSUP)
        }
        DataTransferSession.progress?.activity(completedItem: true)
    }

    private static func synchronize(_ descriptor: Int32, url: URL, full: Bool) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw failure("fsync", url)
        }
        if full {
            while fcntl(descriptor, F_FULLFSYNC) != 0 {
                if errno == EINTR { continue }
                throw failure("F_FULLFSYNC", url)
            }
        }
    }

    private static func openDescriptor(_ path: String, flags: Int32) throws -> Int32 {
        let descriptor = open(path, flags)
        guard descriptor >= 0 else { throw failure("open for synchronization", URL(fileURLWithPath: path)) }
        return descriptor
    }

    private static func requireNamedObject(_ url: URL, descriptor: Int32) throws {
        var opened = stat(), current = stat()
        guard fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0 else {
            throw failure("recheck synchronized object", url)
        }
        guard opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
              opened.st_mode & S_IFMT == current.st_mode & S_IFMT else {
            throw failure("synchronized object moved or changed", url, code: ESTALE)
        }
    }

    private static func requireDirectoryAlias(_ directory: URL, named: stat, resolved: URL, descriptor: Int32) throws {
        var currentName = stat(), currentTarget = stat(), opened = stat()
        guard lstat(directory.path, &currentName) == 0, stat(directory.path, &currentTarget) == 0,
              fstat(descriptor, &opened) == 0 else { throw failure("recheck directory alias", directory) }
        guard named.st_dev == currentName.st_dev, named.st_ino == currentName.st_ino,
              named.st_mode & S_IFMT == currentName.st_mode & S_IFMT,
              opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_dev == currentTarget.st_dev, opened.st_ino == currentTarget.st_ino else {
            throw failure("directory alias moved or changed", directory, code: ESTALE)
        }
        try requireNamedObject(resolved, descriptor: descriptor)
    }

    private static func failure(_ operation: String, _ url: URL, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "\(operation) failed for \(url.path): \(String(cString: strerror(code)))"
        ])
    }
}
