import CryptoKit
import Darwin
import Foundation

/// Strict data-only copy. App bundle migration continues to use FileCopier.
///
/// A successful result describes bytes verified at the destination, with source
/// identities for checking a retained original. The caller must retain that
/// original: no userspace copy can rule out a write after this method returns.
actor TreeCopySession {
    func copy(
        from source: URL,
        to destination: URL,
        excludingRootEntries: Set<String> = [],
        finalDestination: URL? = nil,
        logicalSourceRoot: URL? = nil,
        progressHandler: FileCopier.ProgressHandler? = nil
    ) async throws -> TreeCopySnapshot {
        try Task.checkCancellation()
        let source = Self.canonicalRoot(source)
        let destination = Self.canonicalRoot(destination)
        let finalDestination = Self.canonicalRoot(finalDestination ?? destination)
        guard !Self.contains(source.path, destination.path), !Self.contains(destination.path, source.path) else {
            throw TreeCopyError.unsafeLayout(destination.path)
        }
        let baseline = try Self.snapshot(at: source, excludingRootEntries: excludingRootEntries,
                                         finalDestination: finalDestination, logicalSourceRoot: logicalSourceRoot)
        try Self.requireOwnership(at: destination.deletingLastPathComponent())
        let context = CopyContext(snapshot: baseline, source: source, destination: destination, progress: progressHandler)
        await progressHandler?(FileCopier.Progress(copiedBytes: 0, totalBytes: baseline.logicalBytes, currentFile: source.lastPathComponent))
        try Task.checkCancellation()
        let sourceParent = try Descriptor.open(source.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let targetParent = try Descriptor.open(destination.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try await Self.copyNode(path: "", sourceParent: sourceParent.value, sourceName: source.lastPathComponent,
                                targetParent: targetParent.value, targetName: destination.lastPathComponent, context: context)
        try Self.verifyCopy(at: destination, against: baseline)
        try Self.verifyUnchanged(at: source, against: baseline)
        await progressHandler?(FileCopier.Progress(copiedBytes: baseline.logicalBytes, totalBytes: baseline.logicalBytes, currentFile: ""))
        // The awaited callback can itself write to either tree. Never absorb
        // those changes into the manifest describing the already copied bytes.
        try Task.checkCancellation()
        try Self.verifyCopy(at: destination, against: baseline)
        try Self.verifyUnchanged(at: source, against: baseline)
        return baseline
    }

    nonisolated static func snapshot(at root: URL, excludingRootEntries: Set<String> = [], finalDestination: URL? = nil, logicalSourceRoot: URL? = nil) throws -> TreeCopySnapshot {
        let root = canonicalRoot(root)
        let result = try scan(root, exclusions: excludingRootEntries)
        // A proven volume mounted privately during restore retains the link
        // semantics of its recorded original path. This changes validation
        // only; all traversal and identities still refer to the actual root.
        try validateLinks(result, source: canonicalRoot(logicalSourceRoot ?? root),
                          finalDestination: canonicalRoot(finalDestination ?? root))
        return result
    }

    /// Checks semantic equality, including hardlink relationships, without
    /// comparing source and destination device/inode numbers.
    nonisolated static func verifyCopy(at root: URL, against snapshot: TreeCopySnapshot) throws {
        try compare(scan(canonicalRoot(root), exclusions: snapshot.excludedRootEntries), snapshot, identities: false)
    }

    /// Checks a retained original even after its root has been renamed. ctime
    /// and atime are intentionally not semantic attributes.
    nonisolated static func verifyUnchanged(at root: URL, against snapshot: TreeCopySnapshot) throws {
        try compare(scan(canonicalRoot(root), exclusions: snapshot.excludedRootEntries), snapshot, identities: true)
    }

    nonisolated static func verifyUnchanged(at root: URL, against snapshot: TreeCopySnapshot, expectedVolumeUUID: String) throws {
        let root = canonicalRoot(root)
        guard UUID(uuidString: expectedVolumeUUID) != nil else { throw TreeCopyError.verificationFailed(root.path) }
        try requireVolumeUUID(expectedVolumeUUID, at: root)
        let actual = try scan(root, exclusions: snapshot.excludedRootEntries)
        try requireVolumeUUID(expectedVolumeUUID, at: root)
        var current = stat()
        guard lstat(root.path, &current) == 0, actual.entries.first?.identity == identity(current) else {
            throw TreeCopyError.sourceChanged(root.path)
        }
        try compare(actual, snapshot, identities: false)
        // st_dev can be reassigned after eject/reinsert. UUID establishes the
        // volume namespace; every inode and semantic attribute must still match.
        for (actual, expected) in zip(actual.entries, snapshot.entries) {
            guard actual.identity.inode == expected.identity.inode else { throw TreeCopyError.sourceChanged(expected.path) }
        }
    }

    nonisolated private static func requireVolumeUUID(_ expected: String, at root: URL) throws {
        var fresh = URL(fileURLWithPath: root.path)
        fresh.removeAllCachedResourceValues()
        guard let actual = try fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              actual.caseInsensitiveCompare(expected) == .orderedSame else { throw TreeCopyError.verificationFailed(root.path) }
    }

    nonisolated static func applyRootMetadata(at root: URL, from snapshot: TreeCopySnapshot) throws {
        try Task.checkCancellation()
        guard let entry = snapshot.entries.first(where: { $0.path.isEmpty }) else { throw TreeCopyError.verificationFailed("") }
        let root = canonicalRoot(root)
        let parent = try Descriptor.open(root.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let descriptor = try openNode(parent: parent.value, name: root.lastPathComponent, expectedDevice: nil)
        let value = try status(descriptor.value)
        guard (entry.kind == .directory && value.st_mode & S_IFMT == S_IFDIR)
                || (entry.kind == .file && value.st_mode & S_IFMT == S_IFREG) else { throw TreeCopyError.unsupportedNode(root.path) }
        try requireOwnership(fd: descriptor.value, path: root.path)
        // Unlike initial copying, marker writers may have already restored a
        // readonly root mode. Replaying xattrs requires owner write access.
        let priorMode = value.st_mode & 0o7777
        guard fchmod(descriptor.value, priorMode | 0o700) == 0 else { throw posix(root.path) }
        var restored = false
        defer { if !restored { _ = fchmod(descriptor.value, priorMode) } }
        try applyMetadata(entry, fd: descriptor.value)
        try compareEntry(capture(fd: descriptor.value, parent: parent.value, name: root.lastPathComponent,
                                 path: "", hardlinkGroup: entry.hardlinkGroup), entry, identities: false)
        restored = true
    }

    /// Delete only a freshly verified tree. The caller separately establishes
    /// retained-object identity and exclusive cleanup ownership. Any failure
    /// may leave a partial tree; the ledger must require recovery, never resume
    /// by treating missing entries as permission to delete the remainder.
    nonisolated static func removeVerifiedCopy(at root: URL, against snapshot: TreeCopySnapshot) throws {
        try Task.checkCancellation()
        let root = canonicalRoot(root)
        let actual = try scan(root, exclusions: snapshot.excludedRootEntries)
        try compare(actual, snapshot, identities: false)
        let entries = Dictionary(uniqueKeysWithValues: actual.entries.map { ($0.path, $0) })
        let children = Dictionary(grouping: actual.entries.filter { !$0.path.isEmpty }.map(\.path)) {
            ($0 as NSString).deletingLastPathComponent
        }
        let parent = try Descriptor.open(root.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let descriptor = try openNode(parent: parent.value, name: root.lastPathComponent, expectedDevice: actual.entries.first?.identity.device)
        if actual.entries.first?.kind == .directory {
            // Excluded names were never content-verified. Their mere presence
            // blocks cleanup before any deletion, including product markers.
            guard Set(try directoryNames(descriptor.value)) == Set((children[""] ?? []).map { ($0 as NSString).lastPathComponent }) else {
                throw TreeCopyError.verificationFailed(root.path)
            }
        }
        try removeNode(fd: descriptor.value, parent: parent.value, name: root.lastPathComponent, path: "", entries: entries, children: children)
    }

    nonisolated private static func removeNode(fd: Int32, parent: Int32, name: String, path: String,
                                              entries: [String: TreeCopySnapshot.Entry], children: [String: [String]]) throws {
        try Task.checkCancellation()
        guard let expected = entries[path] else { throw TreeCopyError.verificationFailed(path) }
        try compareEntry(capture(fd: fd, parent: parent, name: name, path: path, hardlinkGroup: expected.hardlinkGroup), expected, identities: true)
        if expected.kind == .directory {
            let expectedChildren = children[path] ?? []
            guard Set(try directoryNames(fd)) == Set(expectedChildren.map { ($0 as NSString).lastPathComponent }) else { throw TreeCopyError.verificationFailed(path) }
            guard fchmod(fd, expected.mode | 0o700) == 0 else { throw posix(path) }
            var removed = false
            defer { if !removed { _ = fchmod(fd, expected.mode) } }
            for child in expectedChildren.sorted() {
                let childName = (child as NSString).lastPathComponent
                let childFD = try openNode(parent: fd, name: childName, expectedDevice: expected.identity.device)
                try removeNode(fd: childFD.value, parent: fd, name: childName, path: child, entries: entries, children: children)
            }
            try Task.checkCancellation()
            guard try directoryNames(fd).isEmpty else { throw TreeCopyError.verificationFailed(path) }
            try requireNamedIdentity(parent: parent, name: name, expected: expected.identity)
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posix(path) }
            removed = true
        } else {
            // Move to an exclusive, unpredictable sibling before the last
            // verification. A writer recreating the original name leaves new
            // data behind and makes the parent nonempty; it is not unlinked.
            let quarantinedName = ".appports-deleting-" + UUID().uuidString
            guard renameatx_np(parent, name, parent, quarantinedName, UInt32(RENAME_EXCL)) == 0 else { throw posix(path) }
            var removed = false
            defer {
                if !removed {
                    // Never replace a new entry at the original name. A crash
                    // or failed restoration leaves recognizable retained data
                    // under the recorded root for explicit recovery.
                    _ = renameatx_np(parent, quarantinedName, parent, name, UInt32(RENAME_EXCL))
                }
            }
            let quarantined = try openNode(parent: parent, name: quarantinedName, expectedDevice: expected.identity.device)
            try compareEntry(capture(fd: quarantined.value, parent: parent, name: quarantinedName, path: path,
                                     hardlinkGroup: expected.hardlinkGroup), expected, identities: true)
            try Task.checkCancellation()
            try requireNamedIdentity(parent: parent, name: quarantinedName, expected: expected.identity)
            guard unlinkat(parent, quarantinedName, 0) == 0 else { throw posix(path) }
            removed = true
        }
    }

    nonisolated private static func requireNamedIdentity(parent: Int32, name: String, expected: TreeCopySnapshot.Identity) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(name) }
        guard identity(info) == expected else { throw TreeCopyError.sourceChanged(name) }
        try validateFlags(info, path: name)
    }

    private final class CopyContext {
        let snapshot: TreeCopySnapshot
        let entries: [String: TreeCopySnapshot.Entry]
        let children: [String: [String]]
        let source: URL
        let destination: URL
        let progress: FileCopier.ProgressHandler?
        var hardlinks: [TreeCopySnapshot.Identity: String] = [:]
        var copiedBytes: Int64 = 0

        init(snapshot: TreeCopySnapshot, source: URL, destination: URL, progress: FileCopier.ProgressHandler?) {
            self.snapshot = snapshot
            entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.path, $0) })
            children = Dictionary(grouping: snapshot.entries.filter { !$0.path.isEmpty }.map(\.path)) {
                ($0 as NSString).deletingLastPathComponent
            }
            self.source = source
            self.destination = destination
            self.progress = progress
        }
    }

    nonisolated private static func copyNode(path: String, sourceParent: Int32, sourceName: String,
                                            targetParent: Int32, targetName: String, context: CopyContext) async throws {
        try Task.checkCancellation()
        guard let entry = context.entries[path] else { throw TreeCopyError.sourceChanged(path) }
        let sourceFD = try openNode(parent: sourceParent, name: sourceName, expectedDevice: entry.identity.device)
        guard identity(try status(sourceFD.value)) == entry.identity else { throw TreeCopyError.sourceChanged(path) }
        let targetFD: Descriptor
        switch entry.kind {
        case .directory:
            if mkdirat(targetParent, targetName, 0o700) != 0 {
                guard path.isEmpty, errno == EEXIST else { throw posix(targetName) }
                targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                let names = try directoryNames(targetFD.value)
                guard Set(names).isSubset(of: context.snapshot.excludedRootEntries) else { throw TreeCopyError.destinationExists(targetName) }
                try validateExcludedEntries(parent: targetFD.value, names: names)
            } else {
                targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            try requireOwnership(fd: targetFD.value, path: targetName)
            try setACL(nil, fd: targetFD.value, path: targetName)
            guard fchmod(targetFD.value, 0o700) == 0 else { throw posix(targetName) }
            for child in (context.children[path] ?? []).sorted() {
                let name = (child as NSString).lastPathComponent
                try await copyNode(path: child, sourceParent: sourceFD.value, sourceName: name,
                                   targetParent: targetFD.value, targetName: name, context: context)
            }
        case .file:
            if let firstPath = context.hardlinks[entry.identity] {
                // Destination traversal remains anchored and no-follow, even
                // when the other link lives in a different sibling directory.
                let first = try openParent(of: firstPath, root: context.destination)
                guard linkat(first.fd.value, first.name, targetParent, targetName, 0) == 0 else { throw posix(targetName) }
                targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDONLY | O_NOFOLLOW)
                try compareEntry(try capture(fd: targetFD.value, parent: targetParent, name: targetName, path: path,
                                             hardlinkGroup: entry.hardlinkGroup), entry, identities: false)
                context.copiedBytes += entry.size
                await context.progress?(FileCopier.Progress(copiedBytes: context.copiedBytes, totalBytes: context.snapshot.logicalBytes, currentFile: targetName))
                return
            }
            targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode: 0o600)
            try setACL(nil, fd: targetFD.value, path: targetName)
            try copyData(from: sourceFD.value, to: targetFD.value, size: entry.size, path: path)
            try Task.checkCancellation()
            context.hardlinks[entry.identity] = path
            context.copiedBytes += entry.size
        case .symbolicLink:
            guard let target = entry.linkTarget, symlinkat(target, targetParent, targetName) == 0 else { throw posix(targetName) }
            targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDONLY | O_SYMLINK)
        }
        // All writable metadata is installed before the ACL. In particular,
        // chown can clear setgid/setuid, so full mode restoration follows it.
        try applyMetadata(entry, fd: targetFD.value)
        let actual = try capture(fd: targetFD.value, parent: targetParent, name: targetName, path: path, hardlinkGroup: entry.hardlinkGroup)
        try compareEntry(actual, entry, identities: false)
        await context.progress?(FileCopier.Progress(copiedBytes: context.copiedBytes, totalBytes: context.snapshot.logicalBytes, currentFile: targetName))
    }

    nonisolated private static func scan(_ root: URL, exclusions: Set<String>) throws -> TreeCopySnapshot {
        try Task.checkCancellation()
        for name in exclusions where name.isEmpty || name == "." || name == ".." || name.contains("/") {
            throw TreeCopyError.unsafeLayout(name)
        }
        let parent = try Descriptor.open(root.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let fd = try openNode(parent: parent.value, name: root.lastPathComponent, expectedDevice: nil)
        let rootInfo = try status(fd.value)
        guard rootInfo.st_mode & S_IFMT != S_IFLNK else { throw TreeCopyError.unsupportedNode(root.path) }
        try requireOwnership(fd: fd.value, path: root.path)
        var entries: [TreeCopySnapshot.Entry] = []
        var linkCounts: [TreeCopySnapshot.Identity: UInt16] = [:]
        try walk(fd: fd.value, parent: parent.value, name: root.lastPathComponent, path: "", device: rootInfo.st_dev,
                 exclusions: exclusions, entries: &entries, linkCounts: &linkCounts)
        let groups = Dictionary(grouping: entries.filter { $0.kind == .file }, by: \.identity)
        for (identity, links) in groups {
            guard Int(linkCounts[identity] ?? 0) == links.count else { throw TreeCopyError.hardlinkOutsideSelection(links[0].path) }
        }
        entries = entries.map { entry in
            let links = groups[entry.identity] ?? []
            return entry.withHardlinkGroup(links.count > 1 ? links.map(\.path).min() : nil)
        }.sorted { $0.path < $1.path }
        return TreeCopySnapshot(entries: entries, excludedRootEntries: exclusions)
    }

    nonisolated private static func walk(fd: Int32, parent: Int32, name: String, path: String, device: Int32,
                                        exclusions: Set<String>, entries: inout [TreeCopySnapshot.Entry],
                                        linkCounts: inout [TreeCopySnapshot.Identity: UInt16]) throws {
        try Task.checkCancellation()
        let before = try status(fd)
        let entry = try capture(fd: fd, parent: parent, name: name, path: path, hardlinkGroup: nil)
        entries.append(entry)
        if entry.kind == .file { linkCounts[entry.identity] = before.st_nlink }
        if entry.kind == .directory {
            let names = try directoryNames(fd)
            if path.isEmpty { try validateExcludedEntries(parent: fd, names: names.filter(exclusions.contains)) }
            for child in names where !path.isEmpty || !exclusions.contains(child) {
                let childFD = try openNode(parent: fd, name: child, expectedDevice: device)
                try walk(fd: childFD.value, parent: fd, name: child, path: path.isEmpty ? child : path + "/" + child,
                         device: device, exclusions: exclusions, entries: &entries, linkCounts: &linkCounts)
            }
        }
        try assertStable(before, try status(fd), path: path)
    }

    nonisolated private static func capture(fd: Int32, parent: Int32, name: String, path: String,
                                           hardlinkGroup: String?) throws -> TreeCopySnapshot.Entry {
        let before = try status(fd)
        let kind: TreeCopySnapshot.Entry.Kind
        switch before.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: throw TreeCopyError.unsupportedNode(path)
        }
        try validateFlags(before, path: path)
        let attributes = try extendedAttributes(fd: fd, path: path)
        let acl = try aclText(fd: fd, path: path)
        let digest = kind == .file ? try sha256(fd: fd, path: path) : nil
        let target: String?
        if kind == .symbolicLink {
            var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlinkat(parent, name, &bytes, bytes.count)
            guard count >= 0, count < bytes.count else { throw posix(path) }
            guard let decoded = String(bytes: bytes.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else { throw TreeCopyError.unsupportedMetadata(path) }
            target = decoded
        } else { target = nil }
        try assertStable(before, try status(fd), path: path)
        return TreeCopySnapshot.Entry(path: path, kind: kind, identity: identity(before), mode: before.st_mode & 0o7777,
                                      uid: before.st_uid, gid: before.st_gid, flags: before.st_flags & UInt32(UF_HIDDEN | UF_NODUMP),
                                      birthTime: timestamp(before.st_birthtimespec), modificationTime: timestamp(before.st_mtimespec),
                                      extendedAttributes: attributes, acl: acl, size: kind == .file ? before.st_size : 0,
                                      digest: digest, linkTarget: target, hardlinkGroup: hardlinkGroup)
    }

    nonisolated private static func applyMetadata(_ entry: TreeCopySnapshot.Entry, fd: Int32) throws {
        try setACL(nil, fd: fd, path: entry.path)
        guard fchown(fd, entry.uid, entry.gid) == 0 else { throw posix(entry.path) }
        let current = try extendedAttributes(fd: fd, path: entry.path)
        for name in current.keys where entry.extendedAttributes[name] == nil {
            guard fremovexattr(fd, name, 0) == 0 else { throw posix(entry.path) }
        }
        for (name, data) in entry.extendedAttributes {
            guard data.withUnsafeBytes({ fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw posix(entry.path) }
        }
        guard fchmod(fd, entry.mode) == 0 else { throw posix(entry.path) }
        // APFS supports nanosecond birth and modification times. A filesystem
        // that rounds either value fails subsequent verification, never passes
        // a silently weakened precision contract.
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
        var times = [nativeTimestamp(entry.birthTime), nativeTimestamp(entry.modificationTime)]
        guard fsetattrlist(fd, &attrs, &times, times.count * MemoryLayout<timespec>.stride, 0) == 0 else { throw posix(entry.path) }
        guard fchflags(fd, entry.flags) == 0 else { throw posix(entry.path) }
        try setACL(entry.acl, fd: fd, path: entry.path)
    }

    nonisolated private static func extendedAttributes(fd: Int32, path: String) throws -> [String: Data] {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 else { throw posix(path) }
        var names = [UInt8](repeating: 0, count: size)
        let actual = names.withUnsafeMutableBytes { flistxattr(fd, $0.baseAddress?.assumingMemoryBound(to: CChar.self), size, 0) }
        guard actual == size else { throw TreeCopyError.sourceChanged(path) }
        var result: [String: Data] = [:]
        for raw in names.split(separator: 0) {
            guard let name = String(bytes: raw, encoding: .utf8) else { throw TreeCopyError.unsupportedMetadata(path) }
            let count = fgetxattr(fd, name, nil, 0, 0, 0)
            guard count >= 0 else { throw posix(path) }
            var bytes = Data(count: count)
            let read = bytes.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }
            guard read == count else { throw TreeCopyError.sourceChanged(path) }
            result[name] = bytes
        }
        return result
    }

    nonisolated private static func aclText(fd: Int32, path: String) throws -> String? {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return nil }
            throw posix(path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        if acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 { return nil }
        guard let text = acl_to_text(acl, nil) else { throw posix(path) }
        defer { acl_free(text) }
        return String(cString: text)
    }

    nonisolated private static func setACL(_ text: String?, fd: Int32, path: String) throws {
        let acl = text.map { acl_from_text($0) } ?? acl_init(0)
        guard let acl else { throw posix(path) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw posix(path) }
    }

    nonisolated private static func sha256(fd: Int32, path: String) throws -> Data {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var offset: off_t = 0
        while true {
            try Task.checkCancellation()
            let count = pread(fd, &buffer, buffer.count, offset)
            if count < 0 { if errno == EINTR { continue }; throw posix(path) }
            if count == 0 { break }
            hasher.update(data: buffer.prefix(count))
            offset += off_t(count)
        }
        return Data(hasher.finalize())
    }

    nonisolated private static func copyData(from source: Int32, to destination: Int32, size: Int64, path: String) throws {
        // Walk native data extents. APFS may eagerly allocate holes during
        // extension, so punch the observed gaps after setting the logical size.
        // Filesystems without extent support still receive all logical bytes.
        var offset: off_t = 0
        var holes: [(off_t, off_t)] = []
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while offset < size {
            try Task.checkCancellation()
            let data = lseek(source, offset, SEEK_DATA)
            if data < 0 {
                if errno == ENXIO { holes.append((offset, size)); break }
                if errno == ENOTSUP || errno == EINVAL {
                    guard lseek(source, 0, SEEK_SET) >= 0, lseek(destination, 0, SEEK_SET) >= 0,
                          fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { throw posix(path) }
                    return
                }
                throw posix(path)
            }
            if data > offset { holes.append((offset, min(data, size))) }
            let hole = lseek(source, data, SEEK_HOLE)
            guard hole > data else { throw TreeCopyError.sourceChanged(path) }
            offset = data
            while offset < min(hole, size) {
                try Task.checkCancellation()
                let count = pread(source, &buffer, min(buffer.count, Int(min(hole, size) - offset)), offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TreeCopyError.sourceChanged(path) }
                try buffer.withUnsafeBytes { bytes in
                    var written = 0
                    while written < count {
                        let result = pwrite(destination, bytes.baseAddress!.advanced(by: written), count - written, offset + off_t(written))
                        if result < 0, errno == EINTR { continue }
                        guard result > 0 else { throw posix(path) }
                        written += result
                    }
                }
                offset += off_t(count)
            }
        }
        guard ftruncate(destination, size) == 0 else { throw posix(path) }
        var filesystem = statfs()
        guard fstatfs(destination, &filesystem) == 0 else { throw posix(path) }
        let block = off_t(filesystem.f_bsize)
        guard block > 0 else { throw TreeCopyError.unsupportedMetadata(path) }
        for (start, end) in holes {
            let alignedStart = ((start + block - 1) / block) * block
            let alignedEnd = (end / block) * block
            guard alignedEnd > alignedStart else { continue }
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: alignedStart, fp_length: alignedEnd - alignedStart)
            if fcntl(destination, F_PUNCHHOLE, &hole) != 0, errno != ENOTSUP, errno != EINVAL { throw posix(path) }
        }
    }

    nonisolated private static func openNode(parent: Int32, name: String, expectedDevice: Int32?) throws -> Descriptor {
        var before = stat()
        guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(name) }
        guard [S_IFDIR, S_IFREG, S_IFLNK].contains(before.st_mode & S_IFMT) else { throw TreeCopyError.unsupportedNode(name) }
        try validateFlags(before, path: name)
        if let expectedDevice, before.st_dev != expectedDevice { throw TreeCopyError.mountBoundary(name) }
        // O_NONBLOCK prevents an intervening replacement by a FIFO from blocking.
        let linkOption = before.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW
        let descriptor = try Descriptor.openAt(parent, name, flags: O_RDONLY | O_NONBLOCK | linkOption)
        let after = try status(descriptor.value)
        guard identity(before) == identity(after), before.st_mode & S_IFMT == after.st_mode & S_IFMT else { throw TreeCopyError.sourceChanged(name) }
        return descriptor
    }

    nonisolated private static func directoryNames(_ fd: Int32) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw posix("") }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw posix("") }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw posix("") }; break }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw TreeCopyError.unsupportedMetadata("") }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    nonisolated private static func validateExcludedEntries(parent: Int32, names: [String]) throws {
        for name in names {
            var value = stat()
            guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(name) }
            guard value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else { throw TreeCopyError.unsupportedNode(name) }
        }
    }

    nonisolated private static func requireOwnership(at url: URL) throws {
        let fd = try Descriptor.open(url.path, flags: O_RDONLY | O_NOFOLLOW)
        try requireOwnership(fd: fd.value, path: url.path)
    }

    nonisolated private static func requireOwnership(fd: Int32, path: String) throws {
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw posix(path) }
        guard filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else { throw TreeCopyError.ownershipDisabled(path) }
    }

    nonisolated private static func openParent(of relative: String, root: URL) throws -> (fd: Descriptor, name: String) {
        let components = relative.split(separator: "/").map(String.init)
        if components.isEmpty {
            return (try Descriptor.open(root.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW), root.lastPathComponent)
        }
        var fd = try Descriptor.open(root.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        for part in components.dropLast() { fd = try Descriptor.openAt(fd.value, part, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        return (fd, components.last!)
    }

    nonisolated private static func compare(_ actual: TreeCopySnapshot, _ expected: TreeCopySnapshot, identities: Bool) throws {
        guard actual.entries.map(\.path) == expected.entries.map(\.path) else { throw TreeCopyError.verificationFailed("") }
        for (actual, expected) in zip(actual.entries, expected.entries) { try compareEntry(actual, expected, identities: identities) }
    }

    nonisolated private static func compareEntry(_ a: TreeCopySnapshot.Entry, _ b: TreeCopySnapshot.Entry, identities: Bool) throws {
        guard (!identities || a.identity == b.identity), a.path == b.path, a.kind == b.kind,
              a.mode == b.mode, a.uid == b.uid, a.gid == b.gid, a.flags == b.flags,
              a.birthTime == b.birthTime, a.modificationTime == b.modificationTime,
              a.extendedAttributes == b.extendedAttributes, a.acl == b.acl, a.size == b.size,
              a.digest == b.digest, a.linkTarget == b.linkTarget, a.hardlinkGroup == b.hardlinkGroup else {
            throw TreeCopyError.verificationFailed(b.path)
        }
    }

    nonisolated private static func validateLinks(_ snapshot: TreeCopySnapshot, source: URL, finalDestination: URL) throws {
        let entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.path, $0) })
        for entry in snapshot.entries where entry.kind == .symbolicLink {
            guard let target = entry.linkTarget, !target.hasPrefix("/") else { continue }
            let sourceLink = source.appendingPathComponent(entry.path)
            let finalLink = finalDestination.appendingPathComponent(entry.path)
            let sourceTarget = try projectedResolution(sourceLink.deletingLastPathComponent().appendingPathComponent(target).path,
                                                       root: source.path, entries: entries)
            let finalTarget = try projectedResolution(finalLink.deletingLastPathComponent().appendingPathComponent(target).path,
                                                      root: finalDestination.path, entries: entries)
            let entersExcludedEntry = snapshot.excludedRootEntries.contains {
                contains(source.appendingPathComponent($0).path, sourceTarget)
            }
            if contains(source.path, sourceTarget), !entersExcludedEntry {
                let suffix = String(sourceTarget.dropFirst(source.path.count))
                guard finalTarget == finalDestination.path + suffix else { throw TreeCopyError.relativeLinkChangesTarget(entry.path) }
            } else {
                guard sourceTarget == finalTarget else { throw TreeCopyError.relativeLinkChangesTarget(entry.path) }
            }
        }
    }

    /// Resolve selected symlinks using the manifest, so the staged tree need not
    /// already exist at its projected final location. Resolve outside ancestors
    /// against the actual filesystem. Dangling links are valid; cycles fail.
    nonisolated private static func projectedResolution(_ path: String, root: String,
                                                        entries: [String: TreeCopySnapshot.Entry], depth: Int = 0) throws -> String {
        guard depth < 40 else { throw TreeCopyError.relativeLinkChangesTarget(path) }
        var resolved = "/"
        var remaining = path.split(separator: "/").map(String.init)
        while !remaining.isEmpty {
            let part = remaining.removeFirst()
            if part == "." { continue }
            if part == ".." { resolved = (resolved as NSString).deletingLastPathComponent; if resolved.isEmpty { resolved = "/" }; continue }
            resolved = (resolved as NSString).appendingPathComponent(part)
            if contains(root, resolved) {
                let relative = String(resolved.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let target = entries[relative]?.linkTarget {
                    let next = target.hasPrefix("/") ? target : ((resolved as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
                    let combined = remaining.reduce(next) { ($0 as NSString).appendingPathComponent($1) }
                    return try projectedResolution(combined, root: root, entries: entries, depth: depth + 1)
                }
            } else {
                resolved = URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
            }
        }
        return resolved
    }

    nonisolated private static func canonicalRoot(_ root: URL) -> URL {
        root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent).standardizedFileURL
    }
    nonisolated private static func validateFlags(_ value: stat, path: String) throws {
        // Validate before opening: opening a dataless item can hydrate it, and
        // opening an unsupported compression representation can alter flags.
        // Compressed files fail closed until logical resource-fork handling is
        // independently verified. Physical compression is not copied blindly.
        let supported = UInt32(UF_HIDDEN | UF_NODUMP)
        guard value.st_flags & ~supported == 0 else { throw TreeCopyError.unsupportedMetadata(path) }
    }
    nonisolated private static func contains(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    nonisolated private static func status(_ fd: Int32) throws -> stat { var value = stat(); guard fstat(fd, &value) == 0 else { throw posix("") }; return value }
    nonisolated private static func identity(_ value: stat) -> TreeCopySnapshot.Identity { .init(device: value.st_dev, inode: value.st_ino) }
    nonisolated private static func timestamp(_ value: timespec) -> TreeCopySnapshot.Timestamp { .init(seconds: Int64(value.tv_sec), nanoseconds: Int64(value.tv_nsec)) }
    nonisolated private static func nativeTimestamp(_ value: TreeCopySnapshot.Timestamp) -> timespec { timespec(tv_sec: Int(value.seconds), tv_nsec: Int(value.nanoseconds)) }
    nonisolated private static func assertStable(_ a: stat, _ b: stat, path: String) throws {
        guard identity(a) == identity(b), a.st_mode == b.st_mode, a.st_size == b.st_size, a.st_nlink == b.st_nlink,
              timestamp(a.st_mtimespec) == timestamp(b.st_mtimespec), timestamp(a.st_ctimespec) == timestamp(b.st_ctimespec) else { throw TreeCopyError.sourceChanged(path) }
    }
    nonisolated private static func posix(_ path: String) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path]) }

    private final class Descriptor {
        let value: Int32
        init(_ value: Int32) { self.value = value }
        deinit { close(value) }
        static func open(_ path: String, flags: Int32) throws -> Descriptor {
            let fd = Darwin.open(path, flags | O_CLOEXEC)
            guard fd >= 0 else { throw TreeCopySession.posix(path) }
            return Descriptor(fd)
        }
        static func openAt(_ parent: Int32, _ name: String, flags: Int32, mode: mode_t = 0) throws -> Descriptor {
            let fd = openat(parent, name, flags | O_CLOEXEC, mode)
            guard fd >= 0 else { throw TreeCopySession.posix(name) }
            return Descriptor(fd)
        }
    }
}

enum TreeCopyError: Error {
    case unsafeLayout(String)
    case destinationExists(String)
    case unsupportedNode(String)
    case unsupportedMetadata(String)
    case mountBoundary(String)
    case ownershipDisabled(String)
    case hardlinkOutsideSelection(String)
    case relativeLinkChangesTarget(String)
    case sourceChanged(String)
    case verificationFailed(String)
}

private extension TreeCopySnapshot.Entry {
    func withHardlinkGroup(_ group: String?) -> Self {
        Self(path: path, kind: kind, identity: identity, mode: mode, uid: uid, gid: gid, flags: flags,
             birthTime: birthTime, modificationTime: modificationTime, extendedAttributes: extendedAttributes,
             acl: acl, size: size, digest: digest, linkTarget: linkTarget, hardlinkGroup: group)
    }
}
