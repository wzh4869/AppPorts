import Darwin
import Foundation

/// libcopyfile before macOS 14 cannot enforce recursive mount boundaries, and
/// early macOS 12 cannot bound its data buffer. Keep traversal in anchored
/// descriptors on those runtimes; share the existing data/fork streaming code.
/// This has no journal or backup lifecycle: the signing operation owns the root.
enum SignatureCompatibilityCopy {
    typealias CloneOperation = @Sendable (Int32, Int32, String, UInt32) -> Int32

    static func copy(from source: URL, to destination: URL, intoExistingRoot: Bool,
                     allowCloning: Bool, onDataCopied: (@Sendable (URL, Int64) -> Void)?,
                     cloneFile: @escaping CloneOperation = { fclonefileat($0, $1, $2, $3) }) throws {
        let source = canonical(source)
        let destination = canonical(destination)
        guard source.path != destination.path,
              !destination.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(destination.path + "/") else { throw TreeCopyError.unsafeLayout(destination.path) }
        let sourceParent = try Descriptor.open(source.deletingLastPathComponent().path, directory: true)
        let targetParent = try Descriptor.open(destination.deletingLastPathComponent().path, directory: true)
        let sourceRoot = try Descriptor.node(sourceParent.value, source.lastPathComponent, device: nil)
        let sourceInfo = try status(sourceRoot.value)
        let parentInfo = try status(sourceParent.value)
        if sourceInfo.st_mode & S_IFMT == S_IFDIR, sourceInfo.st_dev != parentInfo.st_dev {
            throw TreeCopyError.mountBoundary(source.path)
        }
        let targetDevice = try status(targetParent.value).st_dev
        let existingTarget: Descriptor?
        if intoExistingRoot {
            let target = try Descriptor.node(targetParent.value, destination.lastPathComponent, device: targetDevice)
            guard sourceInfo.st_mode & S_IFMT == S_IFDIR, try status(target.value).st_mode & S_IFMT == S_IFDIR,
                  try directoryNames(target.value).isEmpty else { throw CodeSigner.SigningError.snapshotInvalid }
            existingTarget = target
        } else { existingTarget = nil }
        let context = Context(source: source, destination: destination, sourceParent: sourceParent,
                              targetParent: targetParent, sourceInfo: sourceInfo,
                              targetDevice: targetDevice, existingTarget: existingTarget,
                              allowCloning: allowCloning, onDataCopied: onDataCopied, cloneFile: cloneFile)
        if let existingTarget { context.targetRootInfo = try status(existingTarget.value) }
        try context.scan(sourceRoot.value, parent: sourceParent.value, name: source.lastPathComponent, path: "")
        try context.copyNode(sourceRoot.value, sourceParent: sourceParent.value, sourceName: source.lastPathComponent,
                             targetParent: targetParent.value, targetName: destination.lastPathComponent,
                             path: "", intoExistingRoot: intoExistingRoot)
        try context.requireRoots()
    }

    private final class Context {
        let source: URL
        let destination: URL
        let sourceParent: Descriptor
        let targetParent: Descriptor
        let sourceInfo: stat
        let targetDevice: dev_t
        let existingTarget: Descriptor?
        let allowCloning: Bool
        let onDataCopied: (@Sendable (URL, Int64) -> Void)?
        let cloneFile: CloneOperation
        var targetRootInfo: stat?
        var entries: [String: stat] = [:]
        var children: [String: [String]] = [:]

        init(source: URL, destination: URL, sourceParent: Descriptor, targetParent: Descriptor,
             sourceInfo: stat, targetDevice: dev_t, existingTarget: Descriptor?, allowCloning: Bool,
             onDataCopied: (@Sendable (URL, Int64) -> Void)?, cloneFile: @escaping CloneOperation) {
            self.source = source
            self.destination = destination
            self.sourceParent = sourceParent
            self.targetParent = targetParent
            self.sourceInfo = sourceInfo
            self.targetDevice = targetDevice
            self.existingTarget = existingTarget
            self.allowCloning = allowCloning
            self.onDataCopied = onDataCopied
            self.cloneFile = cloneFile
        }

        func scan(_ fd: Int32, parent: Int32, name: String, path: String) throws {
            try Task.checkCancellation()
            let before = try status(fd)
            guard before.st_dev == sourceInfo.st_dev else { throw TreeCopyError.mountBoundary(path) }
            try requireNamed(parent, name, expected: before)
            entries[path] = before
            if before.st_mode & S_IFMT == S_IFDIR {
                let names = try directoryNames(fd)
                children[path] = names
                for name in names {
                    let child = try Descriptor.node(fd, name, device: sourceInfo.st_dev)
                    try scan(child.value, parent: fd, name: name, path: joined(path, name))
                }
            }
            try requireStable(before, status(fd), path: path)
            try requireNamed(parent, name, expected: before)
        }

        func requireRoots() throws {
            try Task.checkCancellation()
            try requireNamed(sourceParent.value, source.lastPathComponent, expected: sourceInfo)
            if let targetRootInfo {
                try requireNamed(targetParent.value, destination.lastPathComponent, expected: targetRootInfo)
            }
        }

        func copyNode(_ sourceFD: Int32, sourceParent: Int32, sourceName: String,
                      targetParent: Int32, targetName: String, path: String, intoExistingRoot: Bool = false) throws {
            try requireRoots()
            guard let expected = entries[path] else { throw CodeSigner.SigningError.applicationChanged }
            try requireStable(expected, status(sourceFD), path: path)
            try requireNamed(sourceParent, sourceName, expected: expected)
            let kind = expected.st_mode & S_IFMT
            let target: Descriptor
            var cloned = false
            if intoExistingRoot {
                guard path.isEmpty, kind == S_IFDIR, let existingTarget else { throw CodeSigner.SigningError.snapshotInvalid }
                target = existingTarget
                guard try status(target.value).st_mode & S_IFMT == S_IFDIR,
                      try directoryNames(target.value).isEmpty else { throw CodeSigner.SigningError.snapshotInvalid }
            } else if kind == S_IFDIR {
                guard mkdirat(targetParent, targetName, 0o700) == 0 else { throw failure(targetName) }
                target = try Descriptor.node(targetParent, targetName, device: targetDevice)
            } else if kind == S_IFREG {
                if allowCloning {
                    // Plain clonefile omits the source ACL. Request it as part
                    // of the atomic clone; old kernels reject CLONE_ACL with
                    // EINVAL, which takes the verified ordinary-copy fallback
                    // below without ever accepting an incomplete clone.
                    if cloneFile(sourceFD, targetParent, targetName, UInt32(CLONE_NOFOLLOW | CLONE_ACL)) == 0 {
                        cloned = true
                    } else {
                        let code = errno
                        guard [ENOTSUP, EXDEV, EINVAL, EPERM, EACCES].contains(code) else { throw failure(targetName, code) }
                        // fclonefileat is atomic. Never replace or remove a
                        // name that appeared while the clone attempt failed.
                        var unexpected = stat()
                        guard fstatat(targetParent, targetName, &unexpected, AT_SYMLINK_NOFOLLOW) != 0,
                              errno == ENOENT else { throw CodeSigner.SigningError.applicationChanged }
                        try requireStable(expected, status(sourceFD), path: path)
                        try requireNamed(sourceParent, sourceName, expected: expected)
                    }
                }
                if cloned { target = try Descriptor.node(targetParent, targetName, device: targetDevice) }
                else { target = try Descriptor.createFile(targetParent, targetName) }
            } else if kind == S_IFLNK {
                var bytes = [UInt8](repeating: 0, count: Int(expected.st_size) + 1)
                let capacity = bytes.count
                let count = readlinkat(sourceParent, sourceName, &bytes, capacity)
                guard count == Int(expected.st_size), let link = String(bytes: bytes.prefix(count), encoding: .utf8),
                      symlinkat(link, targetParent, targetName) == 0 else { throw failure(path) }
                target = try Descriptor.node(targetParent, targetName, device: targetDevice)
            } else { throw TreeCopyError.unsupportedNode(path) }
            let targetInfo = try status(target.value)
            guard targetInfo.st_dev == targetDevice, targetInfo.st_mode & S_IFMT == kind else {
                throw TreeCopyError.mountBoundary(path)
            }
            if path.isEmpty { targetRootInfo = targetInfo }
            func requireCurrent() throws {
                try requireRoots()
                try requireStable(expected, status(sourceFD), path: path)
                try requireNamed(sourceParent, sourceName, expected: expected)
                try requireNamed(targetParent, targetName, expected: targetInfo)
            }
            if kind == S_IFDIR {
                for name in children[path] ?? [] {
                    try requireCurrent()
                    let child = try Descriptor.node(sourceFD, name, device: sourceInfo.st_dev)
                    try copyNode(child.value, sourceParent: sourceFD, sourceName: name,
                                 targetParent: target.value, targetName: name, path: joined(path, name))
                }
            } else if kind == S_IFREG, !cloned {
                // Separate source hardlinks become independent candidate
                // files, as copyfile does. Never link the candidate to either
                // another installed app or the source's external hardlink.
                // Compressed files can report no physical data extents even
                // though their logical data is nonempty. Read that logical
                // stream through the same bounded non-extent fallback.
                let logicalCompression = expected.st_flags & UInt32(UF_COMPRESSED) != 0
                var stream = FileDataCopyStream(from: sourceFD, to: target.value, size: expected.st_size, path: path,
                    extentSeek: { fd, offset, whence in
                        if logicalCompression { errno = ENOTSUP; return -1 }
                        return lseek(fd, offset, whence)
                    })
                while let copied = try stream.copyNextChunk() {
                    onDataCopied?(path.isEmpty ? source : source.appendingPathComponent(path), copied)
                    try requireCurrent()
                }
            }
            try requireCurrent()
            if !cloned {
                try copyAttributes(from: sourceFD, to: target.value, sourceParent: sourceParent, sourceName: sourceName,
                                   targetParent: targetParent, targetName: targetName, path: path,
                                   onResourceForkProgress: { copied in
                                       self.onDataCopied?(path.isEmpty ? self.source : self.source.appendingPathComponent(path),
                                                          Int64(expected.st_size) + copied)
                                   },
                                   check: requireCurrent)
                try copySecurityAndTimes(from: sourceFD, to: target.value, sourceInfo: expected, path: path)
            }
            try requireCurrent()
        }
    }

    private static func copyAttributes(from source: Int32, to destination: Int32,
        sourceParent: Int32, sourceName: String, targetParent: Int32, targetName: String,
        path: String, onResourceForkProgress: (Int64) -> Void, check: () throws -> Void) throws {
        // Compression is a storage representation, not part of a signature.
        // A non-cloned file is copied through its logical data view; ordinary
        // xattr enumeration hides compression backing forks. Never attach the
        // old decmpfs representation to that already copied logical data.
        let systemManaged: Set<String> = ["com.apple.decmpfs", "com.apple.provenance", "com.apple.quarantine", "com.apple.macl"]
        let names = try attributeNames(source, path: path).filter { !systemManaged.contains($0) }
        for name in try attributeNames(destination, path: path) where !systemManaged.contains(name) && !names.contains(name) {
            guard fremovexattr(destination, name, 0) == 0 else { throw failure(path) }
        }
        for name in names {
            try check()
            if name == ResourceForkStream.attributeName {
                let input = ResourceForkStream.Handle(fileDescriptor: source, parentDescriptor: sourceParent, name: sourceName, path: path)
                let output = ResourceForkStream.Handle(fileDescriptor: destination, parentDescriptor: targetParent, name: targetName, path: path, writable: true)
                guard let size = try input.size() else { throw CodeSigner.SigningError.applicationChanged }
                try output.clear()
                var offset: Int64 = 0
                if size == 0 { try output.write(UnsafeRawBufferPointer(start: nil, count: 0), at: 0) }
                try ResourceForkStream.forEachChunk(in: input, byteCount: size) { bytes in
                    try output.write(bytes, at: offset)
                    offset += Int64(bytes.count)
                    onResourceForkProgress(offset)
                    try check()
                }
                guard try input.size() == size, try output.size() == size else { throw CodeSigner.SigningError.applicationChanged }
            } else {
                let size = fgetxattr(source, name, nil, 0, 0, 0)
                guard size >= 0 else { throw failure(path) }
                var bytes = Data(count: size)
                guard bytes.withUnsafeMutableBytes({ fgetxattr(source, name, $0.baseAddress, $0.count, 0, 0) }) == size else {
                    throw CodeSigner.SigningError.applicationChanged
                }
                guard bytes.withUnsafeBytes({ fsetxattr(destination, name, $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw failure(path) }
            }
        }
    }

    private static func copySecurityAndTimes(from source: Int32, to destination: Int32, sourceInfo: stat, path: String) throws {
        // Match libcopyfile's best effort ownership on user-writable copied
        // bundles. All content, modes, ACLs and user-set flags remain required.
        if fchown(destination, sourceInfo.st_uid, sourceInfo.st_gid) != 0, errno != EPERM, errno != EACCES { throw failure(path) }
        guard fchmod(destination, sourceInfo.st_mode & 0o7777) == 0 else { throw failure(path) }
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME)
        var times = [sourceInfo.st_mtimespec, sourceInfo.st_atimespec]
        guard fsetattrlist(destination, &attrs, &times, times.count * MemoryLayout<timespec>.stride, 0) == 0 else { throw failure(path) }
        // This old API handles ACL inheritance without invoking data/xattr
        // copying, so neither new state option nor an unbounded fork buffer is
        // needed. Install immutable flags only after all writable metadata.
        guard fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_ACL)) == 0 else { throw failure(path) }
        let omitted = UInt32(UF_TRACKED | SF_RESTRICTED | SF_NOUNLINK | UF_DATAVAULT | UF_COMPRESSED)
        let preserved = try status(destination).st_flags & UInt32(SF_RESTRICTED | SF_NOUNLINK | UF_DATAVAULT)
        guard fchflags(destination, (sourceInfo.st_flags & ~omitted) | preserved) == 0 else { throw failure(path) }
    }

    private static func attributeNames(_ fd: Int32, path: String) throws -> [String] {
        let count = flistxattr(fd, nil, 0, 0)
        if count < 0, errno == ENOTSUP { return [] }
        guard count >= 0 else { throw failure(path) }
        var bytes = [UInt8](repeating: 0, count: count)
        let actual = bytes.withUnsafeMutableBytes { flistxattr(fd, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count, 0) }
        guard actual == count else { throw CodeSigner.SigningError.applicationChanged }
        return try bytes.split(separator: 0).map {
            guard let name = String(bytes: $0, encoding: .utf8) else { throw TreeCopyError.unsupportedMetadata(path) }
            return name
        }
    }

    private static func directoryNames(_ fd: Int32) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw failure("") }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw failure("") }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(stream) else { if errno != 0 { throw failure("") }; break }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw TreeCopyError.unsupportedMetadata("") }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    private final class Descriptor {
        let value: Int32
        init(_ value: Int32) { self.value = value }
        deinit { close(value) }
        static func open(_ path: String, directory: Bool) throws -> Descriptor {
            let value = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
            guard value >= 0 else { throw failure(path) }
            return Descriptor(value)
        }
        static func node(_ parent: Int32, _ name: String, device: dev_t?) throws -> Descriptor {
            var before = stat()
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(name) }
            if let device, before.st_dev != device { throw TreeCopyError.mountBoundary(name) }
            guard [S_IFDIR, S_IFREG, S_IFLNK].contains(before.st_mode & S_IFMT) else { throw TreeCopyError.unsupportedNode(name) }
            let value = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (before.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW))
            guard value >= 0 else { throw failure(name) }
            let result = Descriptor(value)
            try requireStable(before, status(value), path: name)
            return result
        }
        static func createFile(_ parent: Int32, _ name: String) throws -> Descriptor {
            let value = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard value >= 0 else { throw failure(name) }
            return Descriptor(value)
        }
    }

    private static func status(_ fd: Int32) throws -> stat {
        var result = stat()
        guard fstat(fd, &result) == 0 else { throw failure("") }
        return result
    }
    private static func requireNamed(_ parent: Int32, _ name: String, expected: stat) throws {
        var actual = stat()
        guard fstatat(parent, name, &actual, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(name) }
        guard actual.st_dev == expected.st_dev else { throw TreeCopyError.mountBoundary(name) }
        guard actual.st_ino == expected.st_ino, actual.st_mode & S_IFMT == expected.st_mode & S_IFMT else {
            throw CodeSigner.SigningError.applicationChanged
        }
    }
    private static func requireStable(_ a: stat, _ b: stat, path: String) throws {
        guard a.st_dev == b.st_dev else { throw TreeCopyError.mountBoundary(path) }
        guard a.st_ino == b.st_ino, a.st_mode == b.st_mode, a.st_size == b.st_size, a.st_flags == b.st_flags,
              a.st_nlink == b.st_nlink, a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec,
              a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec, a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec,
              a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec else { throw CodeSigner.SigningError.applicationChanged }
    }
    private static func joined(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }
    private static func canonical(_ url: URL) -> URL { url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent) }
    private static func failure(_ path: String, _ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}
