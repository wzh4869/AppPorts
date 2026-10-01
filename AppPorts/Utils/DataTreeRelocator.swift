import Darwin
import Foundation

/// Moves a real tree root without replacing an entry or changing its identity or permissions.
/// Open directory descriptors anchor both names during the exclusive, same-volume rename.
enum DataTreeRelocator {
    static func move(_ source: URL, to destination: URL) throws {
        let sourceParent = source.deletingLastPathComponent().resolvingSymlinksInPath()
        let destinationParent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let sourceFD = open(sourceParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw posixFailure() }
        defer { close(sourceFD) }
        let destinationFD = open(destinationParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destinationFD >= 0 else { throw posixFailure() }
        defer { close(destinationFD) }
        var sourceParentInfo = stat(), destinationParentInfo = stat(), original = stat()
        guard fstat(sourceFD, &sourceParentInfo) == 0,
              fstat(destinationFD, &destinationParentInfo) == 0,
              fstatat(sourceFD, source.lastPathComponent, &original, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
        let kind = original.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG else { throw POSIXError(.EINVAL) }
        guard original.st_dev == sourceParentInfo.st_dev,
              original.st_dev == destinationParentInfo.st_dev else { throw POSIXError(.EXDEV) }
        guard original.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw POSIXError(.EPERM) }
        let rootFD = openat(sourceFD, source.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw posixFailure() }
        defer { close(rootFD) }
        var opened = stat()
        guard fstat(rootFD, &opened) == 0 else { throw posixFailure() }
        guard sameObject(original, opened) else { throw POSIXError(.ESTALE) }
        let originalMode = original.st_mode & 0o7777
        let needsWrite = kind == S_IFDIR && originalMode & 0o200 == 0
            && !sameObject(sourceParentInfo, destinationParentInfo)
        if needsWrite, fchmod(rootFD, originalMode | 0o200) != 0 { throw posixFailure() }
        do {
            try requireParent(sourceParent, matches: sourceParentInfo)
            try requireParent(destinationParent, matches: destinationParentInfo)
            var current = stat()
            guard fstatat(sourceFD, source.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
            guard sameObject(current, original) else { throw POSIXError(.ESTALE) }
            guard renameatx_np(sourceFD, source.lastPathComponent, destinationFD, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw posixFailure() }
            guard fstatat(destinationFD, destination.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
            guard sameObject(current, original) else { throw POSIXError(.ESTALE) }
            try requireParent(destinationParent, matches: destinationParentInfo)
        } catch {
            if needsWrite { try restoreMode(originalMode, descriptor: rootFD) }
            throw error
        }
        if needsWrite { try restoreMode(originalMode, descriptor: rootFD) }
        var final = stat()
        guard fstatat(destinationFD, destination.lastPathComponent, &final, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
        guard sameObject(final, original), final.st_mode & 0o7777 == originalMode else { throw POSIXError(.ESTALE) }
    }

    private static func restoreMode(_ mode: mode_t, descriptor: Int32) throws {
        guard fchmod(descriptor, mode) == 0 else { throw posixFailure() }
        var restored = stat()
        guard fstat(descriptor, &restored) == 0 else { throw posixFailure() }
        guard restored.st_mode & 0o7777 == mode else { throw POSIXError(.EPERM) }
    }

    private static func requireParent(_ url: URL, matches expected: stat) throws {
        var current = stat()
        guard lstat(url.path, &current) == 0 else { throw posixFailure() }
        guard current.st_mode & S_IFMT == S_IFDIR, sameObject(current, expected) else { throw POSIXError(.ESTALE) }
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
    }

    private static func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
