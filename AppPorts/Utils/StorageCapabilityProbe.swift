import Darwin
import Foundation

/// What an application's filesystem can actually store.
///
/// Probing beats guessing from the filesystem name: the same filesystem can be
/// mounted with different options, and a new format would silently fall through
/// a name-based switch. Each capability is measured by performing the operation
/// on a throwaway entry inside the destination directory, then removing it.
struct StorageCapabilities: Equatable, Sendable {
    var supportsACL: Bool
    var supportsHardlinks: Bool
    var supportsResourceFork: Bool
    var supportsPermissions: Bool

    /// Capabilities an application bundle does not strictly need. A copy that
    /// loses these still produces a runnable, correctly signed application.
    var missing: [Missing] {
        var result: [Missing] = []
        if !supportsACL { result.append(.acl) }
        if !supportsHardlinks { result.append(.hardlinks) }
        if !supportsResourceFork { result.append(.resourceFork) }
        if !supportsPermissions { result.append(.permissions) }
        return result
    }

    enum Missing: String, Equatable, Sendable, CaseIterable {
        case acl
        case hardlinks
        case resourceFork
        case permissions

        /// One bullet per capability the target cannot store. Kept short: the
        /// surrounding warning already explains the consequences.
        var localizedDescription: String {
            switch self {
            case .acl: return "• 文件权限与访问控制列表（ACL）".localized
            case .hardlinks: return "• 硬链接".localized
            case .resourceFork: return "• 资源叉".localized
            case .permissions: return "• POSIX 权限位".localized
            }
        }
    }
}

extension StorageCapabilities {
    /// Whether a bundle copied *from* this volume may already have lost
    /// metadata its filesystem could not store.
    ///
    /// A restore reads the external copy. If that volume cannot represent ACLs,
    /// hard links, resource forks or permission bits, the copy it holds was
    /// written without them — the loss happened at migration time and restoring
    /// cannot bring it back. This is a property of where the copy lives, not of
    /// where it is going.
    var mayHoldDegradedBundle: Bool { !missing.isEmpty }
}

enum StorageCapabilityProbe {
    private struct CacheKey: Hashable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let flags: UInt32
        let uid: uid_t
        let gid: gid_t
    }

    private struct CacheEntry {
        let capabilities: StorageCapabilities
        let expiresAt: TimeInterval
    }

    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 5.0

    internal static func clearCacheForTests() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    /// Probe beside an application bundle, never inside its signed or locked tree.
    /// nil means the check could not run; access errors do not prove a missing capability.
    static func probe(destination: URL) -> StorageCapabilities? {
        guard let directory = existingAncestor(outsideApplicationAt: destination) else { return nil }
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }
        var dirInfo = stat()
        guard fstat(descriptor, &dirInfo) == 0 else { return nil }
        guard dirInfo.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0,
              faccessat(descriptor, ".", W_OK | X_OK, AT_EACCESS) == 0 else {
            return nil
        }

        let cacheKey = CacheKey(
            device: dirInfo.st_dev,
            inode: dirInfo.st_ino,
            mode: dirInfo.st_mode,
            flags: dirInfo.st_flags,
            uid: dirInfo.st_uid,
            gid: dirInfo.st_gid
        )
        let now = ProcessInfo.processInfo.systemUptime
        cacheLock.lock()
        if let entry = cache[cacheKey], entry.expiresAt > now {
            cacheLock.unlock()
            return entry.capabilities
        }
        cache[cacheKey] = nil
        cacheLock.unlock()

        let prefix = ".appports-probe-\(UUID().uuidString)"

        guard let acl = probeFile(in: descriptor, name: prefix + "-acl", operation: { fd in
            guard let empty = acl_init(0) else { return nil }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            return supported(acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED))
        }), let hardlinks = probeFile(in: descriptor, name: prefix + "-link1", operation: { _ in
            defer { _ = unlinkat(descriptor, prefix + "-link2", 0) }
            return supported(linkat(descriptor, prefix + "-link1", descriptor, prefix + "-link2", 0))
        }), let resourceFork = probeFile(in: descriptor, name: prefix + "-fork", operation: { fd in
            supported(fsetxattr(fd, ResourceForkStream.attributeName, nil, 0, 0, 0))
        }), let permissions = probeFile(in: descriptor, name: prefix + "-perm", operation: { fd in
            guard let changed = supported(fchmod(fd, 0o640)) else { return nil }
            guard changed else { return false }
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            return info.st_mode & 0o777 == 0o640
        }) else { return nil }

        let result = StorageCapabilities(supportsACL: acl, supportsHardlinks: hardlinks,
                                         supportsResourceFork: resourceFork, supportsPermissions: permissions)
        cacheLock.lock()
        cache[cacheKey] = CacheEntry(capabilities: result, expiresAt: now + cacheTTL)
        cacheLock.unlock()
        return result
    }

    private static func probeFile(in directory: Int32, name: String,
                                  operation: (Int32) -> Bool?) -> Bool? {
        let descriptor = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        defer {
            _ = close(descriptor)
            _ = unlinkat(directory, name, 0)
        }
        return operation(descriptor)
    }

    private static func supported(_ result: Int32) -> Bool? {
        if result == 0 { return true }
        // Each request above is valid for its regular scratch file. Other errors,
        // including permission denial and I/O failures, leave the result unknown.
        return [ENOTSUP, EOPNOTSUPP, ENOSYS, EINVAL].contains(errno) ? false : nil
    }

    private static func existingAncestor(outsideApplicationAt url: URL) -> String? {
        var candidate = url.resolvingSymlinksInPath().standardizedFileURL
        var ancestor = candidate
        while ancestor.path != "/" {
            if ancestor.pathExtension.lowercased() == "app" {
                candidate = ancestor.deletingLastPathComponent()
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
        while candidate.path != "/" {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue { return candidate.path }
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate.path
    }
}
