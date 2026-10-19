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

enum StorageCapabilityProbe {
    /// - Parameter destination: a location inside the target volume. The probe
    ///   walks up to the nearest existing directory so it works before the
    ///   destination folder itself is created.
    /// - Returns: nil when the volume cannot be inspected at all, in which case
    ///   the caller should not warn (an unreadable probe is not evidence).
    static func probe(destination: URL) -> StorageCapabilities? {
        guard let directory = existingAncestor(of: destination),
              let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) as Int32?,
              descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }

        let prefix = ".appports-probe-\(UUID().uuidString)"

        func makeEntry(_ suffix: String) -> Int32 {
            openat(descriptor, prefix + suffix, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        func removeEntry(_ suffix: String) {
            _ = unlinkat(descriptor, prefix + suffix, 0)
        }

        var capabilities = StorageCapabilities(
            supportsACL: false, supportsHardlinks: false,
            supportsResourceFork: false, supportsPermissions: false)

        // ACL: writing an empty extended ACL is the same call the copier makes
        // for an entry that has none.
        if let fd = makeEntry("-acl") as Int32?, fd >= 0 {
            if let empty = acl_init(0) {
                capabilities.supportsACL = acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) == 0
                acl_free(UnsafeMutableRawPointer(empty))
            }
            _ = close(fd)
            removeEntry("-acl")
        }

        // Hardlinks: two names for one inode.
        if let first = makeEntry("-link1") as Int32?, first >= 0 {
            _ = close(first)
            capabilities.supportsHardlinks =
                linkat(descriptor, prefix + "-link1", descriptor, prefix + "-link2", 0) == 0
            removeEntry("-link1")
            removeEntry("-link2")
        }

        // Resource fork: a named stream the copier writes as an xattr.
        if let fd = makeEntry("-fork") as Int32?, fd >= 0 {
            capabilities.supportsResourceFork =
                fsetxattr(fd, ResourceForkStream.attributeName, nil, 0, 0, 0) == 0
            _ = close(fd)
            removeEntry("-fork")
        }

        // Permissions: whether a non-default mode survives a round trip.
        if let fd = makeEntry("-perm") as Int32?, fd >= 0 {
            _ = close(fd)
            _ = fchmodat(descriptor, prefix + "-perm", 0o640, 0)
            var info = stat()
            if fstatat(descriptor, prefix + "-perm", &info, AT_SYMLINK_NOFOLLOW) == 0 {
                capabilities.supportsPermissions = info.st_mode & 0o777 == 0o640
            }
            removeEntry("-perm")
        }

        return capabilities
    }

    private static func existingAncestor(of url: URL) -> String? {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        return candidate.path
    }
}
