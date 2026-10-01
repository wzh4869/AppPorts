import Darwin
import Foundation

/// Holds the original directory across the overlay so post-mount checks inspect
/// local contents, rather than accidentally enumerating the newly mounted volume.
protocol MountPointLeasing: AnyObject {
    func verifyBeforeMount() throws
    func verifyUnderlyingDirectory() throws
}

final class MountPointLease: MountPointLeasing {
    enum Failure: Error { case notDirectory, notEmpty, replaced }
    let url: URL
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t

    init(at url: URL) throws {
        self.url = url.standardizedFileURL
        var before = stat()
        if lstat(url.path, &before) != 0 {
            guard errno == ENOENT else { throw Self.posix() }
            guard mkdir(url.path, 0o700) == 0 else { throw Self.posix() }
            guard lstat(url.path, &before) == 0 else { throw Self.posix() }
        }
        guard before.st_mode & S_IFMT == S_IFDIR else { throw Failure.notDirectory }
        var anchor = open(url.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW)
        if anchor < 0, errno == EACCES, before.st_mode & 0o7777 == 0 {
            // macOS also denies O_EVTONLY on a 000 directory. Reopen only a
            // previously locked, identity-checked directory via its parent FD.
            // This is preparation, never a writable retry after mount failure.
            let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parent >= 0 else { throw Self.posix() }
            defer { close(parent) }
            let name = url.lastPathComponent
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posix() }
            guard current.st_dev == before.st_dev, current.st_ino == before.st_ino,
                  current.st_mode == before.st_mode else { throw Failure.replaced }
            guard fchmodat(parent, name, 0o700, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posix() }
            anchor = openat(parent, name, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW)
            if anchor < 0 {
                let openingError = Self.posix()
                if fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == before.st_dev, current.st_ino == before.st_ino {
                    guard fchmodat(parent, name, 0, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posix() }
                }
                throw openingError
            }
        }
        guard anchor >= 0 else { throw Self.posix() }
        defer { close(anchor) }
        var anchored = stat()
        guard fstat(anchor, &anchored) == 0 else { throw Self.posix() }
        guard anchored.st_dev == before.st_dev, anchored.st_ino == before.st_ino else { throw Failure.replaced }
        let originalMode = before.st_mode & 0o7777
        guard fchmod(anchor, originalMode | 0o700) == 0 else { throw Self.posix() }
        var opened: Int32 = -1
        do {
            opened = openat(anchor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard opened >= 0 else { throw Self.posix() }
            try Self.requireEmpty(opened)
            guard fchmod(anchor, 0) == 0 else { throw Self.posix() }
        } catch {
            let restoration = fchmod(anchor, originalMode)
            if opened >= 0 { close(opened) }
            guard restoration == 0 else { throw Self.posix() }
            throw error
        }
        descriptor = opened
        device = before.st_dev
        inode = before.st_ino
    }

    deinit { close(descriptor) }

    func verifyBeforeMount() throws {
        var current = stat()
        guard lstat(url.path, &current) == 0 else { throw Self.posix() }
        guard current.st_dev == device, current.st_ino == inode,
              current.st_mode & S_IFMT == S_IFDIR else { throw Failure.replaced }
        try verifyUnderlyingDirectory()
    }

    func verifyUnderlyingDirectory() throws {
        var current = stat()
        guard fstat(descriptor, &current) == 0 else { throw Self.posix() }
        guard current.st_dev == device, current.st_ino == inode else { throw Failure.replaced }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { throw Self.posix() }
        let heldPath = URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
        // Resolve only the parent: resolving the leaf would follow a replacement symlink.
        let expected = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
        guard heldPath == expected else { throw Failure.replaced }
        try Self.requireEmpty(descriptor)
        guard current.st_mode & 0o7777 == 0 else { throw Failure.replaced }
    }

    private static func requireEmpty(_ descriptor: Int32) throws {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw posix() }
        guard let directory = fdopendir(copy) else { close(copy); throw posix() }
        defer { closedir(directory) }
        rewinddir(directory)
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name == "." || name == ".." else { throw Failure.notEmpty }
            errno = 0
        }
        guard errno == 0 else { throw posix() }
    }

    private static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
