import CryptoKit
import Darwin
import Foundation

/// Verified tree copy shared by data directories and application bundles.
///
/// The structural guarantees are identical for both: no-follow traversal,
/// anchored descriptors, mount-boundary refusal, atomic rename switching, and a
/// retained original until the destination is verified. What differs is which
/// content proof is required — see `TreeCopyProfile`.
///
/// By default a successful result describes verified destination bytes. Data
/// transactions can defer that readback until immediately before switching;
/// they must not record a verified phase before performing it themselves.
/// The caller retains the original until cleanup verifies it again.
actor TreeCopySession {
    enum OwnershipRole: Equatable, Sendable { case source, destination }

    /// Only scheduling varies; every scan still produces the same complete proof.
    @TaskLocal static var concurrentScanReads = 4
    @TaskLocal static var concurrentSmallFileCopies = 4
    @TaskLocal private static var scanReadCancellation: ScanReadCancellation?
    @TaskLocal private static var isParallelScanRead = false

    typealias ExtentSeek = @Sendable (Int32, off_t, Int32) -> off_t
    private let extentSeek: ExtentSeek
    private let profile: TreeCopyProfile

    init(extentSeek: @escaping ExtentSeek = { lseek($0, $1, $2) },
         profile: TreeCopyProfile = .strictData) {
        self.extentSeek = extentSeek
        self.profile = profile
    }

    private enum MetadataOwnership: Equatable { case required, unchanged }

    // macOS may attach provenance and per-application access grants when a
    // downloaded file is opened or renamed, including our deletion rename.
    // Preserve those OS-managed tags in place; copying or comparing them as
    // application metadata causes false conflicts and can replay stale grants.
    // POSIX permissions, filesystem ACLs and application xattrs remain verified.
    nonisolated private static let systemManagedAttributes: Set<String> = ["com.apple.provenance", "com.apple.macl"]

    // Finder display settings are disposable, not application data. Limit
    // this exception to ordinary, unshared files; never hide a same-name
    // directory, symlink, or a hardlink to data elsewhere in the selection.
    nonisolated private static func isFinderMetadata(_ entry: TreeCopySnapshot.Entry) -> Bool {
        !entry.path.isEmpty && (entry.path as NSString).lastPathComponent == ".DS_Store"
            && entry.kind == .file && entry.hardlinkGroup == nil
    }

    nonisolated private static func contentEntries(_ snapshot: TreeCopySnapshot) -> [TreeCopySnapshot.Entry] {
        snapshot.entries.filter { !isFinderMetadata($0) }
    }

    nonisolated private static func isFinderMetadata(parent: Int32, name: String) throws -> Bool {
        guard name == ".DS_Store" else { return false }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(name) }
        return info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
    }

    func copy(
        from source: URL,
        to destination: URL,
        excludingRootEntries: Set<String> = [],
        finalDestination: URL? = nil,
        logicalSourceRoot: URL? = nil,
        legacyRootOwnership: TreeCopySnapshot.Ownership? = nil,
        validateRelocatedLinks: Bool = true,
        // 仅在调用方切换入口前自行复核源端时关闭，默认保持独立复制的完整校验。
        verifySourceAfterCopy: Bool = true,
        verifyDestinationAfterCopy: Bool = true,
        preparedHandler: (@Sendable (TreeCopySnapshot) async throws -> Void)? = nil,
        destinationCreatedHandler: (@Sendable (DataPathIdentity) async throws -> Void)? = nil,
        progressHandler: FileCopier.ProgressHandler? = nil
    ) async throws -> TreeCopySnapshot {
        if DataTransferSession.current == nil {
            return try await DataTransferSession.run {
                try await self.copy(from: source, to: destination, excludingRootEntries: excludingRootEntries,
                    finalDestination: finalDestination, logicalSourceRoot: logicalSourceRoot,
                    legacyRootOwnership: legacyRootOwnership, validateRelocatedLinks: validateRelocatedLinks,
                    verifySourceAfterCopy: verifySourceAfterCopy, verifyDestinationAfterCopy: verifyDestinationAfterCopy,
                    preparedHandler: preparedHandler, destinationCreatedHandler: destinationCreatedHandler,
                    progressHandler: progressHandler)
            }
        }
        try MigrationExecution.checkpoint()
        // Maintenance may copy without a UI callback. Its task-local observer
        // still sees bytes; existing caller callbacks remain awaited in place.
        let report: FileCopier.ProgressHandler?
        if let observer = DataTransferSession.progress {
            report = { value in
                observer.update(value)
                await progressHandler?(value)
            }
        } else {
            report = progressHandler
        }
        let source = Self.canonicalRoot(source)
        DataTransferSession.progress?.setDirectory(logicalSourceRoot ?? source, onlyIfUnset: true)
        DataTransferSession.progress?.observeNewCopy(tracksEntrySwitchBoundaries: profile.recordsContentDigests)
        let destination = Self.canonicalRoot(destination)
        let finalDestination = Self.canonicalRoot(finalDestination ?? destination)
        guard !Self.contains(source.path, destination.path), !Self.contains(destination.path, source.path) else {
            throw TreeCopyError.unsafeLayout(destination.path)
        }
        var baseline = try Self.snapshot(at: source, excludingRootEntries: excludingRootEntries,
                                         finalDestination: finalDestination, logicalSourceRoot: logicalSourceRoot,
                                         validateRelocatedLinks: validateRelocatedLinks, profile: profile)
        if let legacyRootOwnership {
            guard legacyRootOwnership.uid == geteuid(), legacyRootOwnership.gid == getegid(),
                  baseline.ownershipCompatibility?.sourceIgnoresOwnership != true,
                  let root = baseline.entries.first, root.path.isEmpty, root.kind == .directory,
                  root.uid == 0 || root.uid == legacyRootOwnership.uid,
                  DiskUtility.isMountPoint(source) else {
                throw TreeCopyError.unsupportedMetadata(source.path, details: "检查源端还原权限失败：旧挂载记录、当前用户或挂载点状态不符合还原条件。".localized)
            }
            baseline.restoredRootOwnership = legacyRootOwnership
        }
        // A pre-created destination may itself be an APFS mount over a local
        // directory. Its parent belongs to a different filesystem.
        var destinationInfo = stat()
        let destinationExists = lstat(destination.path, &destinationInfo) == 0
        let destinationIgnoresOwnership = try Self.ignoresOwnership(
            at: destinationExists ? destination : destination.deletingLastPathComponent())
        if var compatibility = baseline.ownershipCompatibility {
            compatibility.destinationIgnoresOwnership = destinationIgnoresOwnership
            baseline.ownershipCompatibility = compatibility
        } else if destinationIgnoresOwnership {
            baseline.ownershipCompatibility = .init(sourceIgnoresOwnership: false,
                destinationIgnoresOwnership: true, projectedSourceOwner: nil)
        }
        // Persist the source snapshot and creation intent before any target
        // exists. A second callback claims its actual inode before content is
        // written, including a root file that fails on its first write.
        try await preparedHandler?(baseline)
        let context = CopyContext(snapshot: baseline, source: source, destination: destination,
                                  created: destinationCreatedHandler, progress: report, extentSeek: extentSeek,
                                  profile: profile)
        await report?(FileCopier.Progress(copiedBytes: 0, totalBytes: baseline.logicalBytes, currentFile: source.lastPathComponent))
        try MigrationExecution.checkpoint()
        let sourceParent = try Descriptor.open(source.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let targetParent = try Descriptor.open(destination.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try await DataTransferSession.measure(.copy) {
            try await Self.copyNode(path: "", sourceParent: sourceParent.value, sourceName: source.lastPathComponent,
                                    targetParent: targetParent.value, targetName: destination.lastPathComponent, context: context)
            DataTransferSession.progress?.begin(.synchronizing)
            try DurableFileIO.syncTree(at: destination, excludingRootEntries: excludingRootEntries,
                                       barrier: profile.syncBarrier)
        }
        await report?(FileCopier.Progress(copiedBytes: baseline.logicalBytes, totalBytes: baseline.logicalBytes, currentFile: ""))
        // Read back the entire destination once after synchronization and all
        // callbacks. Per-file readback before those callbacks would be repeated
        // work and could not replace this final contents/metadata/topology check.
        try MigrationExecution.checkpoint()
        if verifyDestinationAfterCopy { try Self.verifyCopy(at: destination, against: baseline, profile: profile) }
        // 数据迁移调用方会在切换入口前复核源目录，避免在这里重复整树读取。
        // 其他调用方默认继续由复制器复核源端。
        if verifySourceAfterCopy { try Self.verifyUnchanged(at: source, against: baseline, profile: profile) }
        // A relaxed destination may be unable to represent parts of the source.
        // Report it once per copy so the degradation is visible to the user and
        // in a diagnostic package, never silently assumed.
        if context.separatedHardlinks > 0 || context.droppedResourceForks > 0 {
            AppLogger.shared.logContext(
                "目标存储无法保留部分元数据",
                details: [
                    ("destination", destination.path),
                    ("hardlinks_split", String(context.separatedHardlinks)),
                    ("resource_forks_dropped", String(context.droppedResourceForks)),
                    ("note", "文件内容与签名校验仍通过；仅硬链接共享和资源叉未保留。")
                ],
                level: "WARN"
            )
        }
        return baseline
    }

    nonisolated static func snapshot(at root: URL, excludingRootEntries: Set<String> = [], finalDestination: URL? = nil,
                                     logicalSourceRoot: URL? = nil, validateRelocatedLinks: Bool = true,
                                     profile: TreeCopyProfile = .strictData,
                                     scanTitle: String = "", scanDetail: String = "") throws -> TreeCopySnapshot {
        let root = canonicalRoot(root)
        DataTransferSession.progress?.setDirectory(logicalSourceRoot ?? root, onlyIfUnset: true)
        let result = try DataTransferSession.measure(.scan) {
            DataTransferSession.progress?.begin(.scanning,
                detail: scanDetail.isEmpty
                    ? "正在读取源目录，记录文件内容和属性，作为复制和后续检查的依据。".localized : scanDetail,
                title: scanTitle)
            return try withCopyDiagnostics(String(format: "检查源端目录：%@".localized, root.path)) {
                try scan(root, exclusions: excludingRootEntries, profile: profile)
            }
        }
        // A proven volume mounted privately during restore retains the link
        // semantics of its recorded original path. This changes validation
        // only; all traversal and identities still refer to the actual root.
        if validateRelocatedLinks {
            try validateLinks(result, source: canonicalRoot(logicalSourceRoot ?? root),
                              finalDestination: canonicalRoot(finalDestination ?? root))
        }
        return result
    }

    /// Checks semantic equality, including hardlink relationships, without
    /// comparing source and destination device/inode numbers.
    nonisolated static func verifyCopy(at root: URL, against snapshot: TreeCopySnapshot,
                                       profile: TreeCopyProfile = .strictData,
                                       purpose: DataTransferVerification = .copiedData) throws {
        _ = try verifiedCopySnapshot(at: root, against: snapshot, profile: profile, purpose: purpose)
    }

    /// Returns the exact destination observation that passed the saved proof.
    /// A second scan after verification must not become a new deletion baseline.
    nonisolated static func verifiedCopySnapshot(at root: URL, against snapshot: TreeCopySnapshot,
                                                profile: TreeCopyProfile = .strictData,
                                                purpose: DataTransferVerification = .copiedData) throws -> TreeCopySnapshot {
        let root = canonicalRoot(root)
        return try DataTransferSession.measure(.verification) {
            DataTransferSession.progress?.verify(purpose)
            return try withCopyDiagnostics(String(format: "校验目标端目录：%@".localized, root.path)) {
                let actual = try scan(root, exclusions: snapshot.excludedRootEntries, profile: profile, expectedItems: snapshot.entries.count)
                try compare(actual, snapshot,
                            identities: false, ownershipRole: .destination, rootPath: root.path,
                            profile: profile)
                return actual
            }
        }
    }

    /// Proves that every surviving byte of a claimed, unactivated candidate is
    /// still present in the unchanged source. A partial file may be a prefix;
    /// unknown names, different bytes, links or metadata are never discarded.
    /// The returned destination snapshot becomes the deletion checkpoint.
    nonisolated static func partialCopySnapshot(at root: URL, source: URL,
                                                against baseline: TreeCopySnapshot,
                                                sourceVolumeUUID: String? = nil) throws -> TreeCopySnapshot {
        func verifySource() throws {
            if let sourceVolumeUUID {
                try verifyUnchanged(at: source, against: baseline, expectedVolumeUUID: sourceVolumeUUID)
            } else { try verifyUnchanged(at: source, against: baseline) }
        }
        try verifySource()
        let actual = try scan(canonicalRoot(root), exclusions: baseline.excludedRootEntries)
        let expected = Dictionary(uniqueKeysWithValues: baseline.entries.map { ($0.path, baseline.destinationEntry($0)) })
        DataTransferSession.progress?.startTraversal(at: source)
        for entry in actual.entries {
            DataTransferSession.progress?.activity(file: entry.path)
            guard let original = expected[entry.path], entry.kind == original.kind,
                  entry.acl == nil || entry.acl == original.acl,
                  portableAttributes(entry.extendedAttributes).allSatisfy({ original.extendedAttributes[$0.key] == $0.value }),
                  entry.flags & ~original.flags == 0 else { throw TreeCopyError.verificationFailed(entry.path) }
            // Cancellation can leave a complete data fork and only a prefix
            // of its resource fork. Prove that prefix belongs to the still
            // unchanged source before authorizing candidate cleanup.
            if let copiedFork = try recordedResourceFork(entry) {
                guard let originalFork = try recordedResourceFork(original), copiedFork.size <= originalFork.size else {
                    throw TreeCopyError.verificationFailed(entry.path)
                }
                if copiedFork != originalFork {
                    let parent = try openParent(of: entry.path, root: canonicalRoot(source))
                    let descriptor = try openNode(parent: parent.fd.value, name: parent.name, expectedDevice: nil)
                    let fork = ResourceForkStream.Handle(fileDescriptor: descriptor.value, parentDescriptor: parent.fd.value,
                        name: parent.name, path: entry.path)
                    guard try ResourceForkStream.digest(in: fork, byteCount: copiedFork.size) == copiedFork.digest else {
                        throw TreeCopyError.verificationFailed(entry.path)
                    }
                }
            }
            switch entry.kind {
            case .directory, .namedPipe: break
            case .symbolicLink:
                guard entry.linkTarget == original.linkTarget else { throw TreeCopyError.verificationFailed(entry.path) }
            case .file:
                guard entry.size >= 0, entry.size <= original.size else { throw TreeCopyError.verificationFailed(entry.path) }
                let parent = try openParent(of: entry.path, root: canonicalRoot(source))
                let descriptor = try Descriptor.openAt(parent.fd.value, parent.name, flags: O_RDONLY | O_NOFOLLOW)
                var hasher = SHA256()
                var offset: Int64 = 0
                var bytes = [UInt8](repeating: 0, count: max(1, min(1_048_576, Int(clamping: entry.size))))
                while offset < entry.size {
                    try MigrationExecution.checkpoint()
                    let count = pread(descriptor.value, &bytes, min(bytes.count, Int(entry.size - offset)), off_t(offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw TreeCopyError.sourceChanged(entry.path) }
                    hasher.update(data: Data(bytes.prefix(count)))
                    offset += Int64(count)
                    DataTransferSession.progress?.activity(bytesRead: Int64(count))
                }
                guard Data(hasher.finalize()) == entry.digest else { throw TreeCopyError.verificationFailed(entry.path) }
            }
            DataTransferSession.progress?.activity(completedItem: true)
        }
        try verifySource()
        return actual
    }

    /// Checks a retained original even after its root has been renamed. ctime
    /// and atime are intentionally not semantic attributes.
    nonisolated static func verifyUnchanged(at root: URL, against snapshot: TreeCopySnapshot,
                                            profile: TreeCopyProfile = .strictData,
                                            purpose: DataTransferVerification = .sourceUnchanged) throws {
        let root = canonicalRoot(root)
        try DataTransferSession.measure(.verification) {
            DataTransferSession.progress?.verify(purpose)
            try withCopyDiagnostics(String(format: "校验源端目录：%@".localized, root.path)) {
                try compare(scan(root, exclusions: snapshot.excludedRootEntries, profile: profile, expectedItems: snapshot.entries.count), snapshot,
                            identities: true, rootPath: root.path, profile: profile)
            }
        }
    }

    nonisolated static func verifyUnchanged(at root: URL, against snapshot: TreeCopySnapshot,
                                            expectedVolumeUUID: String,
                                            profile: TreeCopyProfile = .strictData,
                                            purpose: DataTransferVerification = .sourceUnchanged) throws {
        let root = canonicalRoot(root)
        guard UUID(uuidString: expectedVolumeUUID) != nil else { throw TreeCopyError.verificationFailed(root.path) }
        try requireVolumeUUID(expectedVolumeUUID, at: root)
        let actual = try DataTransferSession.measure(.verification) {
            DataTransferSession.progress?.verify(purpose)
            return try scan(root, exclusions: snapshot.excludedRootEntries, profile: profile, expectedItems: snapshot.entries.count)
        }
        try requireVolumeUUID(expectedVolumeUUID, at: root)
        var current = stat()
        guard lstat(root.path, &current) == 0, actual.entries.first?.identity == identity(current) else {
            throw TreeCopyError.sourceChanged(root.path)
        }
        try compare(actual, snapshot, identities: false, rootPath: root.path, profile: profile)
        // st_dev can be reassigned after eject/reinsert. UUID establishes the
        // volume namespace; every inode and semantic attribute must still match.
        for (actual, expected) in zip(contentEntries(actual), contentEntries(snapshot)) {
            guard actual.identity.inode == expected.identity.inode else { throw TreeCopyError.sourceChanged(expected.path) }
        }
    }

    nonisolated private static func requireVolumeUUID(_ expected: String, at root: URL) throws {
        var fresh = URL(fileURLWithPath: root.path)
        fresh.removeAllCachedResourceValues()
        guard let actual = try fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              actual.caseInsensitiveCompare(expected) == .orderedSame else { throw TreeCopyError.verificationFailed(root.path) }
    }

    nonisolated static func applyRootMetadata(at root: URL, from snapshot: TreeCopySnapshot,
                                            ownershipRole: OwnershipRole = .source,
                                            profile: TreeCopyProfile = .strictData) throws {
        try MigrationExecution.checkpoint()
        guard let sourceEntry = snapshot.entries.first(where: { $0.path.isEmpty }) else { throw TreeCopyError.verificationFailed("") }
        let entry = ownershipRole == .destination ? snapshot.destinationEntry(sourceEntry) : sourceEntry
        let ownershipIsIgnored = try permitsProjectedOwnership(snapshot, role: ownershipRole)
        let root = canonicalRoot(root)
        let parent = try Descriptor.open(root.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let descriptor = try openNode(parent: parent.value, name: root.lastPathComponent, expectedDevice: nil)
        let value = try status(descriptor.value)
        guard (entry.kind == .directory && value.st_mode & S_IFMT == S_IFDIR)
                || (entry.kind == .file && value.st_mode & S_IFMT == S_IFREG) else {
            throw TreeCopyError.unsupportedNode(root.path, details: String(format: "恢复目录属性失败：实际文件类型与记录不符，mode=%@。".localized, String(value.st_mode, radix: 8)))
        }
        try requireOwnership(fd: descriptor.value, path: root.path, allowingIgnored: ownershipIsIgnored)
        // Unlike initial copying, marker writers may have already restored a
        // readonly root mode. Replaying xattrs requires owner write access.
        let priorMode = value.st_mode & 0o7777
        guard fchmod(descriptor.value, priorMode | 0o700) == 0 else { throw posix(root.path) }
        var restored = false
        defer { if !restored { _ = fchmod(descriptor.value, priorMode) } }
        // Replaying a retained source must never write its projected UID back
        // as physical ownership, even if the disk now mounts with owners.
        let ownership: MetadataOwnership = ownershipRole == .source && ownershipIsIgnored ? .unchanged
            : (ownershipIsIgnored ? .unchanged : .required)
        try applyMetadata(entry, fd: descriptor.value, ownership: ownership)
        try compareEntry(capture(fd: descriptor.value, parent: parent.value, name: root.lastPathComponent,
                                 path: "", hardlinkGroup: entry.hardlinkGroup, profile: profile), entry,
                         identities: false, compareOwnership: !ownershipIsIgnored, profile: profile)
        restored = true
    }

    /// Locate a retained file interrupted between its exclusive rename and
    /// unlink. A replacement at the original name never inherits that identity.
    nonisolated static func retainedRemovalURL(at root: URL, removalID: UUID) throws -> URL? {
        let root = canonicalRoot(root)
        let quarantine = root.deletingLastPathComponent().appendingPathComponent(removalName(removalID))
        func exists(_ url: URL) throws -> Bool {
            var value = stat()
            if lstat(url.path, &value) == 0 { return true }
            guard errno == ENOENT else { throw posix(url.path) }
            return false
        }
        let originalExists = try exists(root)
        let quarantineExists = try exists(quarantine)
        guard !(originalExists && quarantineExists) else { throw TreeCopyError.sourceChanged(root.path) }
        return originalExists ? root : quarantineExists ? quarantine : nil
    }

    /// Only a durable cleanup checkpoint authorizes this subset check. Every
    /// remaining node must still have its original inode and content. Deletion
    /// can change directory timestamps, temporary owner-write modes, and the
    /// representative name of an internal hardlink group.
    nonisolated static func verifyRemovalRemainder(at root: URL, against snapshot: TreeCopySnapshot,
                                                   expectedVolumeUUID: String? = nil, removalID: UUID,
                                                   profile: TreeCopyProfile = .strictData) throws {
        guard let retained = try retainedRemovalURL(at: root, removalID: removalID) else {
            throw TreeCopyError.verificationFailed(root.path)
        }
        DataTransferSession.progress?.verify(.retainedCopy)
        let actual = try scan(retained, exclusions: snapshot.excludedRootEntries, profile: profile)
        try compareRemovalRemainder(actual, snapshot, root: retained,
                                    expectedVolumeUUID: expectedVolumeUUID, removalID: removalID, profile: profile)
    }

    /// Delete a freshly verified tree, or resume a checkpointed deletion. The
    /// caller proves active data and retained-parent identity before calling.
    nonisolated static func removeVerifiedCopy(at root: URL, against snapshot: TreeCopySnapshot,
                                             ownershipRole: OwnershipRole = .source,
                                             allowPartialRemoval: Bool = false,
                                             expectedVolumeUUID: String? = nil, removalID: UUID? = nil,
                                             requireSourceIdentity: Bool = false,
                                             profile: TreeCopyProfile = .strictData,
                                             prepareForRemoval: (() throws -> Void)? = nil,
                                             willRemove: (() throws -> Void)? = nil) throws {
        try MigrationExecution.checkpoint()
        var root = canonicalRoot(root)
        if allowPartialRemoval {
            guard ownershipRole == .source, let removalID,
                  let retained = try retainedRemovalURL(at: root, removalID: removalID) else {
                throw TreeCopyError.verificationFailed(root.path)
            }
            root = retained
        }
        DataTransferSession.progress?.verify(.retainedCopy)
        // Deletion is authorized by the manifest alone, so every node is
        // re-checked with the profile that produced it. Relaxing the copy
        // profile must not relax the proof that a node is the recorded one.
        let actual = try scan(root, exclusions: snapshot.excludedRootEntries, profile: profile, includeFinderMetadata: true)
        if allowPartialRemoval, let removalID {
            try compareRemovalRemainder(actual, snapshot, root: root,
                                        expectedVolumeUUID: expectedVolumeUUID, removalID: removalID,
                                        profile: profile)
        } else {
            try compare(actual, snapshot, identities: requireSourceIdentity && expectedVolumeUUID == nil,
                        ownershipRole: ownershipRole, rootPath: root.path, profile: profile)
            if requireSourceIdentity, let expectedVolumeUUID {
                try requireVolumeUUID(expectedVolumeUUID, at: root)
                for (current, original) in zip(contentEntries(actual), contentEntries(snapshot)) {
                    guard current.identity.inode == original.identity.inode else { throw TreeCopyError.sourceChanged(current.path) }
                }
            }
        }
        let index = SnapshotIndex(actual.entries)
        let parent = try Descriptor.open(root.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let descriptor = try openNode(parent: parent.value, name: root.lastPathComponent, expectedDevice: actual.entries.first?.identity.device)
        // Remove only caller-owned management metadata after the original root
        // has passed verification. The caller restores its root metadata; the
        // no-extra-entries check and per-node checks still precede deletion.
        try prepareForRemoval?()
        if actual.entries.first?.kind == .directory {
            // Excluded names were never content-verified. Their mere presence
            // blocks cleanup before any deletion, including product markers.
            guard Set(try directoryNames(descriptor.value)) == Set((index.children[""] ?? []).map { ($0 as NSString).lastPathComponent }) else {
                throw TreeCopyError.verificationFailed(root.path)
            }
        }
        // The caller can durably authorize deletion after the full manifest
        // check, without repeating that scan. This callback cannot suspend;
        // removeNode still checks each object immediately before unlinking it.
        try willRemove?()
        DataTransferSession.progress?.begin(.cleaning)
        DataTransferSession.progress?.startTraversal(at: root)
        try removeNode(fd: descriptor.value, parent: parent.value, name: root.lastPathComponent, path: "", snapshot: actual, index: index,
                       ownershipIsIgnored: actual.ownershipCompatibility?.sourceIgnoresOwnership == true,
                       removalID: removalID, profile: profile)
    }

    nonisolated private static func removalName(_ id: UUID) -> String { ".appports-deleting-" + id.uuidString }

    nonisolated private static func compareRemovalRemainder(_ actual: TreeCopySnapshot, _ expected: TreeCopySnapshot,
                                                           root: URL, expectedVolumeUUID: String?, removalID: UUID,
                                                           profile: TreeCopyProfile = .strictData) throws {
        let ignoresOwnership = try permitsProjectedOwnership(expected, role: .source)
        if !ignoresOwnership, actual.ownershipCompatibility?.sourceIgnoresOwnership == true {
            throw TreeCopyError.ownershipDisabled(root.path)
        }
        if let expectedVolumeUUID { try requireVolumeUUID(expectedVolumeUUID, at: root) }
        var byPath: [String: TreeCopySnapshot.Entry] = [:]
        byPath.reserveCapacity(expected.entries.count)
        for entry in expected.entries {
            guard byPath.updateValue(entry, forKey: entry.path) == nil else {
                throw TreeCopyError.verificationFailed(root.path)
            }
        }
        let remainingPaths = Set(actual.entries.map(\.path))
        let quarantinedName = removalName(removalID)
        var matched: Set<String> = []
        for entry in actual.entries {
            // New or changed Finder settings do not require an old manifest
            // match. removeNode still verifies this scan's exact file.
            if isFinderMetadata(entry) { continue }
            let baseline: TreeCopySnapshot.Entry
            if let exact = byPath[entry.path] {
                baseline = exact
            } else {
                // A crash may leave our exclusive per-file rename behind.
                // Match only a missing sibling with the recorded inode.
                guard (entry.path as NSString).lastPathComponent == quarantinedName,
                      let prior = expected.entries.first(where: {
                          $0.kind != .directory && !remainingPaths.contains($0.path) && !matched.contains($0.path)
                              && ($0.path as NSString).deletingLastPathComponent == (entry.path as NSString).deletingLastPathComponent
                              && $0.identity.inode == entry.identity.inode
                      }) else { throw TreeCopyError.verificationFailed(entry.path) }
                baseline = prior
            }
            guard matched.insert(baseline.path).inserted,
                  entry.identity.inode == baseline.identity.inode,
                  expectedVolumeUUID != nil || entry.identity.device == baseline.identity.device,
                  entry.kind == baseline.kind,
                  entry.mode == baseline.mode || (entry.kind == .directory && entry.mode == baseline.mode | 0o700) else {
                throw TreeCopyError.sourceChanged(entry.path)
            }
            // A previous interrupted deletion may have quarantined an old
            // .DS_Store under the operation's private name.
            if isFinderMetadata(baseline), entry.kind == .file, entry.hardlinkGroup == nil { continue }
            let comparable = TreeCopySnapshot.Entry(path: entry.path, kind: baseline.kind, identity: entry.identity,
                mode: entry.mode, uid: baseline.uid, gid: baseline.gid, flags: baseline.flags,
                birthTime: baseline.birthTime,
                modificationTime: baseline.kind == .directory ? entry.modificationTime : baseline.modificationTime,
                extendedAttributes: baseline.extendedAttributes, resourceFork: baseline.resourceFork, acl: baseline.acl, size: baseline.size,
                digest: baseline.digest, linkTarget: baseline.linkTarget, hardlinkGroup: entry.hardlinkGroup)
            try compareEntry(entry, comparable, identities: true, compareOwnership: !ignoresOwnership, profile: profile)
        }
        guard matched.contains("") else { throw TreeCopyError.verificationFailed(root.path) }
        if let expectedVolumeUUID { try requireVolumeUUID(expectedVolumeUUID, at: root) }
    }

    nonisolated private static func removeNode(fd: Int32, parent: Int32, name: String, path: String,
                                              snapshot: TreeCopySnapshot, index: SnapshotIndex,
                                              ownershipIsIgnored: Bool, removalID: UUID?,
                                              profile: TreeCopyProfile = .strictData) throws {
        try MigrationExecution.checkpoint()
        DataTransferSession.progress?.activity(file: path.isEmpty ? name : path)
        guard let entryIndex = index.byPath[path] else { throw TreeCopyError.verificationFailed(path) }
        let expected = snapshot.entries[entryIndex]
        try requireOwnership(fd: fd, path: path, allowingIgnored: ownershipIsIgnored)
        try requireNamedIdentity(parent: parent, name: name, expected: expected.identity)
        if expected.kind == .directory {
            try compareEntry(capture(fd: fd, parent: parent, name: name, path: path, hardlinkGroup: expected.hardlinkGroup,
                                     profile: profile), expected,
                             identities: true, compareOwnership: !ownershipIsIgnored, profile: profile)
            let expectedChildren = index.children[path] ?? []
            guard Set(try directoryNames(fd)) == Set(expectedChildren.map { ($0 as NSString).lastPathComponent }) else { throw TreeCopyError.verificationFailed(path) }
            guard fchmod(fd, expected.mode | 0o700) == 0 else { throw posix(path) }
            var removed = false
            defer { if !removed { _ = fchmod(fd, expected.mode) } }
            for child in expectedChildren.sorted() {
                let childName = (child as NSString).lastPathComponent
                let childFD = try openNode(parent: fd, name: childName, expectedDevice: expected.identity.device)
                try removeNode(fd: childFD.value, parent: fd, name: childName, path: child, snapshot: snapshot, index: index,
                               ownershipIsIgnored: ownershipIsIgnored, removalID: removalID, profile: profile)
            }
            try MigrationExecution.checkpoint()
            guard try directoryNames(fd).isEmpty else { throw TreeCopyError.verificationFailed(path) }
            try requireNamedIdentity(parent: parent, name: name, expected: expected.identity)
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posix(path) }
            removed = true
        } else {
            // File contents are checked after the exclusive rename below.
            // Reading them here as well cannot protect the later unlink.
            // Move to an exclusive, unpredictable sibling before the last
            // verification. A writer recreating the original name leaves new
            // data behind and makes the parent nonempty; it is not unlinked.
            let quarantinedName = removalName(removalID ?? UUID())
            if name != quarantinedName {
                guard renameatx_np(parent, name, parent, quarantinedName, UInt32(RENAME_EXCL)) == 0 else { throw posix(path) }
            }
            var removed = false
            defer {
                if !removed && name != quarantinedName {
                    // Never replace a new entry at the original name. A crash
                    // or failed restoration leaves recognizable retained data
                    // under the recorded root for explicit recovery.
                    _ = renameatx_np(parent, quarantinedName, parent, name, UInt32(RENAME_EXCL))
                }
            }
            let quarantined = try openNode(parent: parent, name: quarantinedName, expectedDevice: expected.identity.device)
            try requireOwnership(fd: quarantined.value, path: path, allowingIgnored: ownershipIsIgnored)
            try compareEntry(capture(fd: quarantined.value, parent: parent, name: quarantinedName, path: path,
                                     hardlinkGroup: expected.hardlinkGroup, profile: profile), expected,
                             identities: true, compareOwnership: !ownershipIsIgnored, profile: profile)
            try MigrationExecution.checkpoint()
            try requireNamedIdentity(parent: parent, name: quarantinedName, expected: expected.identity)
            guard unlinkat(parent, quarantinedName, 0) == 0 else { throw posix(path) }
            removed = true
        }
        DataTransferSession.progress?.activity(completedItem: true)
    }

    nonisolated private static func requireNamedIdentity(parent: Int32, name: String, expected: TreeCopySnapshot.Identity) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(name) }
        guard identity(info) == expected else {
            throw TreeCopyError.sourceChanged(name)
        }
        try validateFlags(info, path: name, descriptor: parent, child: name)
    }

    /// Reference the immutable manifest by position instead of duplicating all
    /// metadata in hash-table buckets and temporary mapped arrays.
    private struct SnapshotIndex {
        let byPath: [String: Int]
        let children: [String: [String]]

        init(_ entries: [TreeCopySnapshot.Entry]) {
            byPath = Dictionary(uniqueKeysWithValues: entries.indices.lazy.map { (entries[$0].path, $0) })
            var children: [String: [String]] = [:]
            for entry in entries where !entry.path.isEmpty {
                children[(entry.path as NSString).deletingLastPathComponent, default: []].append(entry.path)
            }
            self.children = children
        }
    }

    private final class CopyContext {
        let snapshot: TreeCopySnapshot
        let index: SnapshotIndex
        let source: URL
        let destination: URL
        let progress: FileCopier.ProgressHandler?
        let created: (@Sendable (DataPathIdentity) async throws -> Void)?
        let extentSeek: ExtentSeek
        let destinationIgnoresOwnership: Bool
        let profile: TreeCopyProfile
        let totalLogicalBytes: Int64
        var hardlinks: [TreeCopySnapshot.Identity: String] = [:]
        /// Links that had to become independent copies on a filesystem without
        /// inode sharing. Reported so the caller can surface the storage cost.
        var separatedHardlinks = 0
        /// Resource forks the destination cannot store. Surfaced as a warning.
        var droppedResourceForks = 0
        var copiedBytes: Int64 = 0

        init(snapshot: TreeCopySnapshot, source: URL, destination: URL,
             created: (@Sendable (DataPathIdentity) async throws -> Void)?, progress: FileCopier.ProgressHandler?,
             extentSeek: @escaping ExtentSeek, profile: TreeCopyProfile) {
            self.snapshot = snapshot
            index = SnapshotIndex(snapshot.entries)
            self.source = source
            self.destination = destination
            self.progress = progress
            self.created = created
            self.extentSeek = extentSeek
            self.profile = profile
            destinationIgnoresOwnership = snapshot.ownershipCompatibility?.destinationIgnoresOwnership == true
            totalLogicalBytes = snapshot.logicalBytes
        }

        /// Workers share only immutable values. Their mutable counters and link
        /// inventory remain private, and no worker invokes an external callback.
        init(workerFor context: CopyContext) {
            snapshot = context.snapshot
            index = context.index
            source = context.source
            destination = context.destination
            progress = nil
            created = nil
            extentSeek = context.extentSeek
            profile = context.profile
            destinationIgnoresOwnership = context.destinationIgnoresOwnership
            totalLogicalBytes = context.totalLogicalBytes
        }
    }

    /// The wrapper transfers one context to one child task; it is never shared
    /// between workers or read by the parent while that child is running.
    private struct SmallFileCopy: @unchecked Sendable {
        let path: String
        let context: CopyContext
    }

    nonisolated private static func canBatchSmallFile(_ path: String, context: CopyContext) -> Bool {
        guard context.profile.recordsContentDigests, let index = context.index.byPath[path] else { return false }
        let entry = context.snapshot.entries[index]
        // Larger batches regress write/sync latency on the tested external APFS
        // SSD. Keep concurrency within the tiny-file range that benefits there.
        return entry.kind == .file && entry.size <= 16_384 && entry.hardlinkGroup == nil
            && entry.resourceFork == nil && entry.extendedAttributes[ResourceForkStream.attributeName] == nil
    }

    /// The structured group joins all writes before descriptors can be closed,
    /// callbacks can mutate data, or the caller can start recovery/cleanup.
    nonisolated private static func copySmallFileBatch(_ paths: [String], sourceParent: Int32,
                                                      targetParent: Int32, context: CopyContext) async throws {
        guard !paths.isEmpty else { return }
        if paths.count == 1 {
            let path = paths[0]
            let name = (path as NSString).lastPathComponent
            try await copyNodeContents(path: path, sourceParent: sourceParent, sourceName: name,
                                       targetParent: targetParent, targetName: name, context: context)
            return
        }
        let control = MigrationExecution.control
        let counts = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
                for (index, path) in paths.enumerated() {
                    let worker = SmallFileCopy(path: path, context: CopyContext(workerFor: context))
                    group.addTask {
                        let name = (worker.path as NSString).lastPathComponent
                        try await copyNodeContents(path: worker.path, sourceParent: sourceParent, sourceName: name,
                            targetParent: targetParent, targetName: name, context: worker.context)
                        return (index, worker.context.copiedBytes)
                    }
                }
                var counts = Array(repeating: Int64(0), count: paths.count)
                do {
                    while let (index, bytes) = try await group.next() { counts[index] = bytes }
                } catch {
                    group.cancelAll()
                    // A sibling may already be sleeping in a paused checkpoint.
                    // Wake the operation's control before the group joins it.
                    control?.cancel()
                    throw error
                }
                return counts
            }
        } onCancel: {
            control?.cancel()
        }
        for (path, bytes) in zip(paths, counts) {
            try MigrationExecution.checkpoint()
            context.copiedBytes += bytes
            await context.progress?(FileCopier.Progress(copiedBytes: context.copiedBytes,
                totalBytes: context.totalLogicalBytes, currentFile: (path as NSString).lastPathComponent))
        }
    }

    nonisolated private static func copyNode(path: String, sourceParent: Int32, sourceName: String,
                                            targetParent: Int32, targetName: String, context: CopyContext) async throws {
        do {
            try await copyNodeContents(path: path, sourceParent: sourceParent, sourceName: sourceName,
                                       targetParent: targetParent, targetName: targetName, context: context)
        } catch {
            let source = path.isEmpty ? context.source : context.source.appendingPathComponent(path)
            let target = path.isEmpty ? context.destination : context.destination.appendingPathComponent(path)
            throw copyDiagnosticError(error, context: String(format: "复制源端：%@\n复制目标端：%@".localized, source.path, target.path))
        }
    }

    nonisolated private static func copyNodeContents(path: String, sourceParent: Int32, sourceName: String,
                                                    targetParent: Int32, targetName: String, context: CopyContext) async throws {
        try MigrationExecution.checkpoint()
        guard let entryIndex = context.index.byPath[path] else {
            throw TreeCopyError.sourceChanged(path)
        }
        let entry = context.snapshot.destinationEntry(context.snapshot.entries[entryIndex])
        let sourceFD = try openNode(parent: sourceParent, name: sourceName, expectedDevice: entry.identity.device)
        guard identity(try status(sourceFD.value)) == entry.identity else {
            throw TreeCopyError.sourceChanged(path)
        }
        let targetFD: Descriptor
        switch entry.kind {
        case .directory:
            if mkdirat(targetParent, targetName, 0o700) != 0 {
                guard path.isEmpty, errno == EEXIST else { throw posix(targetName) }
                targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                let names = try directoryNames(targetFD.value).filter {
                    try !isFinderMetadata(parent: targetFD.value, name: $0)
                }
                guard Set(names).isSubset(of: context.snapshot.excludedRootEntries) else { throw TreeCopyError.destinationExists(targetName) }
                try validateExcludedEntries(parent: targetFD.value, names: names)
            } else {
                targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            if path.isEmpty {
                try DurableFileIO.syncDirectory(at: context.destination.deletingLastPathComponent())
                try await context.created?(DataPathIdentity.capture(context.destination))
                try requireNamedIdentity(parent: targetParent, name: targetName, expected: identity(status(targetFD.value)))
            }
            try requireOwnership(fd: targetFD.value, path: targetName, allowingIgnored: context.destinationIgnoresOwnership)
            try setACL(nil, fd: targetFD.value, path: targetName, profile: context.profile)
            guard fchmod(targetFD.value, 0o700) == 0 else { throw posix(targetName) }
            let parallelism = context.profile.recordsContentDigests ? min(4, max(1, concurrentSmallFileCopies)) : 1
            var pending: [String] = []
            for child in (context.index.children[path] ?? []).sorted() {
                if parallelism > 1, canBatchSmallFile(child, context: context) {
                    pending.append(child)
                    if pending.count == parallelism {
                        try await copySmallFileBatch(pending, sourceParent: sourceFD.value,
                            targetParent: targetFD.value, context: context)
                        pending.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                try await copySmallFileBatch(pending, sourceParent: sourceFD.value,
                    targetParent: targetFD.value, context: context)
                pending.removeAll(keepingCapacity: true)
                let name = (child as NSString).lastPathComponent
                try await copyNodeContents(path: child, sourceParent: sourceFD.value, sourceName: name,
                                           targetParent: targetFD.value, targetName: name, context: context)
            }
            try await copySmallFileBatch(pending, sourceParent: sourceFD.value,
                targetParent: targetFD.value, context: context)
        case .file, .namedPipe:
            if entry.hardlinkGroup != nil, let firstPath = context.hardlinks[entry.identity] {
                // Destination traversal remains anchored and no-follow, even
                // when the other link lives in a different sibling directory.
                let first = try openParent(of: firstPath, root: context.destination)
                if linkat(first.fd.value, first.name, targetParent, targetName, 0) != 0 {
                    // A destination filesystem without hardlinks (ExFAT, FAT)
                    // cannot share an inode. Materialising a second independent
                    // copy keeps the application usable; only the storage
                    // saving is lost, and every file still holds the same bytes.
                    guard context.profile.toleratesUnsupportedHardlink, errno == ENOTSUP else {
                        throw posix(targetName)
                    }
                    context.separatedHardlinks += 1
                } else {
                    targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                    try requireOwnership(fd: targetFD.value, path: targetName, allowingIgnored: context.destinationIgnoresOwnership)
                    context.copiedBytes += entry.logicalBytes
                    await context.progress?(FileCopier.Progress(copiedBytes: context.copiedBytes, totalBytes: context.totalLogicalBytes, currentFile: targetName))
                    return
                }
            }
            if entry.kind == .namedPipe {
                // Realm and other databases keep FIFO notification nodes beside
                // durable data. Recreate the node without consuming its runtime
                // messages or waiting for a peer; metadata is copied below.
                if #available(macOS 13.0, *) {
                    guard mkfifoat(targetParent, targetName, 0o600) == 0 else { throw posix(targetName) }
                } else {
                    try createNamedPipeUsingSystemUtility(parent: targetParent, name: targetName)
                }
                targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            } else {
                targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode: 0o600)
            }
            if path.isEmpty {
                try DurableFileIO.syncDirectory(at: context.destination.deletingLastPathComponent())
                try await context.created?(DataPathIdentity.capture(context.destination))
                try requireNamedIdentity(parent: targetParent, name: targetName, expected: identity(status(targetFD.value)))
            }
            try setACL(nil, fd: targetFD.value, path: targetName, profile: context.profile)
            let completedBytes = context.copiedBytes
            let totalBytes = context.totalLogicalBytes
            let progress = context.progress
            if entry.kind == .file {
                try await copyData(from: sourceFD.value, to: targetFD.value, size: entry.size, path: path,
                    extentSeek: context.extentSeek) { currentBytes in
                        await progress?(FileCopier.Progress(copiedBytes: completedBytes + currentBytes,
                            totalBytes: totalBytes, currentFile: targetName))
                    }
            }
            try MigrationExecution.checkpoint()
            if entry.hardlinkGroup != nil { context.hardlinks[entry.identity] = path }
            context.copiedBytes += entry.size
        case .symbolicLink:
            guard let target = entry.linkTarget, symlinkat(target, targetParent, targetName) == 0 else { throw posix(targetName) }
            targetFD = try Descriptor.openAt(targetParent, targetName, flags: O_RDONLY | O_SYMLINK)
        }
        // All writable metadata is installed before the ACL. In particular,
        // chown can clear setgid/setuid, so full mode restoration follows it.
        try requireOwnership(fd: targetFD.value, path: targetName, allowingIgnored: context.destinationIgnoresOwnership)
        try await copyResourceFork(entry, sourceFD: sourceFD.value, sourceParent: sourceParent, sourceName: sourceName,
            targetFD: targetFD.value, targetParent: targetParent, targetName: targetName, context: context)
        try applyMetadata(entry, fd: targetFD.value, ownership: context.destinationIgnoresOwnership ? .unchanged : .required,
                          profile: context.profile)
        await context.progress?(FileCopier.Progress(copiedBytes: context.copiedBytes, totalBytes: context.totalLogicalBytes, currentFile: targetName))
    }

    nonisolated private static func copyResourceFork(_ entry: TreeCopySnapshot.Entry,
        sourceFD: Int32, sourceParent: Int32, sourceName: String,
        targetFD: Int32, targetParent: Int32, targetName: String, context: CopyContext) async throws {
        guard let expected = try recordedResourceFork(entry) else { return }
        // A destination filesystem that cannot carry a resource fork (ExFAT,
        // FAT) cannot store it at any cost. Materialising the data fork is still
        // correct for an application whose signature does not cover the fork;
        // the loss is recorded so the caller can tell the user.
        if context.profile.toleratesUnsupportedResourceFork, !supportsResourceFork(targetFD) {
            context.droppedResourceForks += 1
            return
        }
        let source = ResourceForkStream.Handle(fileDescriptor: sourceFD, parentDescriptor: sourceParent,
            name: sourceName, path: entry.path)
        let target = ResourceForkStream.Handle(fileDescriptor: targetFD, parentDescriptor: targetParent,
            name: targetName, path: entry.path, writable: true)
        guard try source.size() == expected.size else {
            throw TreeCopyError.sourceChanged(entry.path)
        }
        try target.clear()
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: ResourceForkStream.bufferByteCount)
        var offset: Int64 = 0
        if expected.size == 0 { try target.write(UnsafeRawBufferPointer(start: nil, count: 0), at: 0) }
        while offset < expected.size {
            try MigrationExecution.checkpoint()
            let wanted = min(buffer.count, Int(expected.size - offset))
            let count = try buffer.withUnsafeMutableBytes {
                try source.read(into: UnsafeMutableRawBufferPointer(rebasing: $0.prefix(wanted)), at: offset)
            }
            guard count > 0, count <= wanted else { throw TreeCopyError.sourceChanged(entry.path) }
            try buffer.withUnsafeBytes {
                let bytes = UnsafeRawBufferPointer(rebasing: $0.prefix(count))
                try target.write(bytes, at: offset)
                hash.update(bufferPointer: bytes)
            }
            offset += Int64(count)
            await context.progress?(FileCopier.Progress(copiedBytes: context.copiedBytes + offset,
                totalBytes: context.totalLogicalBytes, currentFile: targetName))
        }
        try MigrationExecution.checkpoint()
        guard Data(hash.finalize()) == expected.digest, try source.size() == expected.size,
              try target.size() == expected.size else { throw TreeCopyError.verificationFailed(entry.path) }
        try target.synchronize()
        context.copiedBytes += expected.size
    }

    /// Probes the destination for resource-fork support by writing and clearing
    /// an empty value; no content is lost if the probe succeeds.
    nonisolated private static func supportsResourceFork(_ fd: Int32) -> Bool {
        let name = ResourceForkStream.attributeName
        if fsetxattr(fd, name, nil, 0, 0, 0) == 0 {
            _ = fremovexattr(fd, name, 0)
            return true
        }
        return errno != ENOTSUP && errno != EINVAL
    }

    nonisolated private static func scan(_ root: URL, exclusions: Set<String>,
                                        profile: TreeCopyProfile = .strictData,
                                        includeFinderMetadata: Bool = false,
                                        expectedItems: Int = 0) throws -> TreeCopySnapshot {
        try withCopyDiagnostics(String(format: "读取目录：%@".localized, root.path)) {
            try scanContents(root, exclusions: exclusions, profile: profile, includeFinderMetadata: includeFinderMetadata, expectedItems: expectedItems)
        }
    }

    nonisolated private static func scanContents(_ root: URL, exclusions: Set<String>,
                                                profile: TreeCopyProfile, includeFinderMetadata: Bool, expectedItems: Int) throws -> TreeCopySnapshot {
        try MigrationExecution.checkpoint()
        DataTransferSession.progress?.startTraversal(at: root, expectedItems: expectedItems)
        for name in exclusions where name.isEmpty || name == "." || name == ".." || name.contains("/") {
            throw TreeCopyError.unsafeLayout(name)
        }
        let parent = try Descriptor.open(root.deletingLastPathComponent().path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let fd = try openNode(parent: parent.value, name: root.lastPathComponent, expectedDevice: nil)
        let rootInfo = try status(fd.value)
        guard rootInfo.st_mode & S_IFMT != S_IFLNK else {
            throw TreeCopyError.unsupportedNode(root.path, details: "扫描入口是符号链接，不能作为真实目录读取。".localized)
        }
        let ownershipIsIgnored = try ignoresOwnership(fd: fd.value, path: root.path)
        var entries: [TreeCopySnapshot.Entry] = []
        var hardlinks: [TreeCopySnapshot.Identity: ScannedHardlinks] = [:]
        try walk(fd: fd.value, parent: parent.value, name: root.lastPathComponent, path: "", device: rootInfo.st_dev,
                 exclusions: exclusions, entries: &entries, hardlinks: &hardlinks, profile: profile,
                 includeFinderMetadata: includeFinderMetadata,
                 concurrentReads: profile.recordsContentDigests ? min(4, max(1, concurrentScanReads)) : 1)
        // A count and canonical name prove the same hardlink relationships as
        // grouping whole entries, without a second manifest and one array for
        // every ordinary single-link file.
        for links in hardlinks.values {
            guard Int(links.reportedCount) == links.count else {
                throw TreeCopyError.hardlinkOutsideSelection(links.canonicalPath)
            }
        }
        for index in entries.indices {
            if let links = hardlinks[entries[index].identity], links.count > 1 {
                entries[index] = entries[index].withHardlinkGroup(links.canonicalPath)
            }
        }
        entries.sort { $0.path < $1.path }
        // A mount-option change during traversal could mix projected and real
        // UID/GID observations in one manifest. Retry with a stable contract.
        guard try ignoresOwnership(fd: fd.value, path: root.path) == ownershipIsIgnored else {
            throw TreeCopyError.sourceChanged(root.path)
        }
        let compatibility: TreeCopySnapshot.OwnershipCompatibility? = ownershipIsIgnored
            ? .init(sourceIgnoresOwnership: true, destinationIgnoresOwnership: true,
                    projectedSourceOwner: .init(uid: geteuid(), gid: getegid())) : nil
        return TreeCopySnapshot(ownershipCompatibility: compatibility, entries: entries, excludedRootEntries: exclusions)
    }

    private struct ScannedHardlinks {
        let reportedCount: UInt16
        var count: Int
        var canonicalPath: String
    }

    private typealias CapturedNode = (before: stat, entry: TreeCopySnapshot.Entry)
    private struct SerialCaptureRequired: Error {}

    private final class ScanReadCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func checkpoint() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
    }

    private struct ScanRead: @unchecked Sendable {
        let descriptor: Descriptor
        let name: String
        let path: String
    }

    private final class ScanReadResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Result<CapturedNode, Error>?]
        private var nextIndex = 0

        init(count: Int) { values = Array(repeating: nil, count: count) }
        func claim() -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard nextIndex < values.count else { return nil }
            defer { nextIndex += 1 }
            return nextIndex
        }
        func set(_ value: Result<CapturedNode, Error>, at index: Int) {
            lock.lock(); defer { lock.unlock() }
            values[index] = value
        }
        func result(at index: Int) throws -> Result<CapturedNode, Error> {
            lock.lock(); defer { lock.unlock() }
            guard let value = values[index] else { throw TreeCopyError.verificationFailed("") }
            return value
        }
    }

    /// Descriptors are bounded by the batch size, and remain owned until every
    /// worker has joined. No worker changes the manifest or hardlink inventory.
    nonisolated private static func captureBatch(_ reads: [ScanRead], parent: Int32,
                                                 profile: TreeCopyProfile, workerCount: Int) throws -> ScanReadResults {
        let results = ScanReadResults(count: reads.count)
        if reads.count == 1 {
            let read = reads[0]
            results.set(Result {
                try captureStableNode(fd: read.descriptor.value, parent: parent,
                    name: read.name, path: read.path, hardlinkGroup: nil, profile: profile)
            }, at: 0)
            return results
        }
        let group = DispatchGroup()
        let cancellation = ScanReadCancellation()
        let session = DataTransferSession.current
        let progress = DataTransferSession.progress
        let control = MigrationExecution.control
        // Workers pull the next file as soon as they finish; a slow file no
        // longer stalls every subsequent group of four. Keep enumeration order
        // in the result slots and keep scratch buffers private to each worker.
        for _ in 0..<min(workerCount, reads.count) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let hasher = FileContentHasher()
                DataTransferSession.$current.withValue(session) {
                    DataTransferSession.$progress.withValue(progress) {
                        MigrationExecution.$control.withValue(control) {
                            $scanReadCancellation.withValue(cancellation) {
                                $isParallelScanRead.withValue(true) {
                                    while let index = results.claim() {
                                        let read = reads[index]
                                        let result = Result {
                                            try scanReadCheckpoint()
                                            return try captureStableNode(fd: read.descriptor.value, parent: parent,
                                                name: read.name, path: read.path, hardlinkGroup: nil,
                                                profile: profile, contentHasher: hasher)
                                        }
                                        results.set(result, at: index)
                                        if case .failure(is CancellationError) = result { break }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Dispatch threads have no Swift task. Bridge cancellation only for
        // this joined batch, never into a later independent recovery task.
        while group.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            if Task.isCancelled {
                cancellation.cancel()
                // A paused worker is sleeping on this control's condition;
                // the batch flag alone cannot wake it to observe cancellation.
                control?.cancel()
            }
        }
        try MigrationExecution.checkpoint()
        return results
    }

    nonisolated private static func scanReadCheckpoint() throws {
        try scanReadCancellation?.checkpoint()
        try MigrationExecution.checkpoint()
    }

    nonisolated private static func walk(fd: Int32, parent: Int32, name: String, path: String, device: Int32,
                                        exclusions: Set<String>, entries: inout [TreeCopySnapshot.Entry],
                                        hardlinks: inout [TreeCopySnapshot.Identity: ScannedHardlinks],
                                        profile: TreeCopyProfile, includeFinderMetadata: Bool,
                                        concurrentReads: Int = 1, capturedNode: CapturedNode? = nil) throws {
        try MigrationExecution.checkpoint()
        let captured = try capturedNode ?? captureStableNode(fd: fd, parent: parent, name: name, path: path,
            hardlinkGroup: nil, profile: profile)
        let before = captured.before
        let entry = captured.entry
        entries.append(entry)
        DataTransferSession.progress?.activity(completedItem: true)
        if entry.kind == .file || entry.kind == .namedPipe {
            if var links = hardlinks[entry.identity] {
                guard links.reportedCount == before.st_nlink else { throw TreeCopyError.sourceChanged(path) }
                links.count += 1
                links.canonicalPath = min(links.canonicalPath, path)
                hardlinks[entry.identity] = links
            } else {
                hardlinks[entry.identity] = .init(reportedCount: before.st_nlink, count: 1, canonicalPath: path)
            }
        }
        if entry.kind == .directory {
            var names = try directoryNames(fd)
            if path.isEmpty { try validateExcludedEntries(parent: fd, names: names.filter(exclusions.contains)) }
            // A filesystem that stores extended attributes in AppleDouble
            // sidecars (ExFAT, FAT) exposes those `._name` files to readdir.
            // They are the destination's own encoding of metadata we just wrote,
            // not content the source carries, so a relaxed copy ignores them.
            if profile.toleratesUnsupportedResourceFork {
                names.removeAll { $0.hasPrefix("._") && !exclusions.contains($0) }
            }
            var pending: [ScanRead] = []
            func finishPending() throws {
                guard !pending.isEmpty else { return }
                let results = try captureBatch(pending, parent: fd, profile: profile, workerCount: concurrentReads)
                for (index, read) in pending.enumerated() {
                    let captured: CapturedNode?
                    switch try results.result(at: index) {
                    case .success(let value): captured = value
                    case .failure(is SerialCaptureRequired): captured = nil
                    case .failure(let error): throw error
                    }
                    try walk(fd: read.descriptor.value, parent: fd, name: read.name, path: read.path,
                        device: device, exclusions: exclusions, entries: &entries, hardlinks: &hardlinks,
                        profile: profile, includeFinderMetadata: includeFinderMetadata, capturedNode: captured)
                }
                pending.removeAll(keepingCapacity: true)
            }
            for child in names where !path.isEmpty || !exclusions.contains(child) {
                if !includeFinderMetadata, try isFinderMetadata(parent: fd, name: child) { continue }
                let childFD = try openNode(parent: fd, name: child, expectedDevice: device)
                let childPath = path.isEmpty ? child : path + "/" + child
                if concurrentReads > 1, try status(childFD.value).st_mode & S_IFMT == S_IFREG {
                    pending.append(ScanRead(descriptor: childFD, name: child, path: childPath))
                    if pending.count == concurrentReads * 8 { try finishPending() }
                    continue
                }
                try finishPending()
                try walk(fd: childFD.value, parent: fd, name: child, path: path.isEmpty ? child : path + "/" + child,
                         device: device, exclusions: exclusions, entries: &entries, hardlinks: &hardlinks,
                         profile: profile, includeFinderMetadata: includeFinderMetadata, concurrentReads: concurrentReads)
            }
            try finishPending()
        }
        try assertStable(before, try status(fd), path: path, profile: profile)
    }

    nonisolated private static func capture(fd: Int32, parent: Int32, name: String, path: String,
                                           hardlinkGroup: String?,
                                           profile: TreeCopyProfile = .strictData) throws -> TreeCopySnapshot.Entry {
        try captureStableNode(fd: fd, parent: parent, name: name, path: path,
            hardlinkGroup: hardlinkGroup, profile: profile).entry
    }

    /// 系统访问授权等元数据可能在首次读取时更新。只重读不稳定的节点，
    /// 每次仍检查同一个文件身份并重新读取完整内容；不放宽与原清单的比对。
    nonisolated private static func captureStableNode(fd: Int32, parent: Int32, name: String, path: String,
                                                      hardlinkGroup: String?, profile: TreeCopyProfile,
                                                      contentHasher: FileContentHasher? = nil) throws
        -> (before: stat, entry: TreeCopySnapshot.Entry) {
        let identityBeforeReading = identity(try status(fd))
        for attempt in 0..<3 {
            try scanReadCheckpoint()
            try requireNamedIdentity(parent: parent, name: name, expected: identityBeforeReading)
            let before = try status(fd)
            do {
                let entry = try captureOnce(fd: fd, parent: parent, name: name, path: path,
                    hardlinkGroup: hardlinkGroup, profile: profile, contentHasher: contentHasher)
                try assertStable(before, try status(fd), path: path, profile: profile)
                return (before, entry)
            } catch TreeCopyError.sourceChanged(_) where attempt < 2 {
                let after = try status(fd)
                // 只吸收变化时间更新；内容大小、修改时间、权限或身份变化立即停止。
                guard identity(before) == identity(after), before.st_mode == after.st_mode,
                      before.st_size == after.st_size, before.st_nlink == after.st_nlink,
                      before.st_uid == after.st_uid, before.st_gid == after.st_gid,
                      before.st_flags == after.st_flags,
                      timestamp(before.st_birthtimespec) == timestamp(after.st_birthtimespec),
                      timestamp(before.st_mtimespec) == timestamp(after.st_mtimespec),
                      timestamp(before.st_ctimespec) != timestamp(after.st_ctimespec) else {
                    throw TreeCopyError.sourceChanged(path)
                }
                try requireNamedIdentity(parent: parent, name: name, expected: identityBeforeReading)
            }
        }
        throw TreeCopyError.sourceChanged(path)
    }

    nonisolated private static func captureOnce(fd: Int32, parent: Int32, name: String, path: String,
                                               hardlinkGroup: String?, profile: TreeCopyProfile,
                                               contentHasher: FileContentHasher?) throws -> TreeCopySnapshot.Entry {
        DataTransferSession.progress?.activity(file: path.isEmpty ? name : path)
        let before = try status(fd)
        let kind: TreeCopySnapshot.Entry.Kind
        switch before.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        case S_IFIFO: kind = .namedPipe
        default:
            throw TreeCopyError.unsupportedNode(diagnosticPath(fd: fd, fallback: path),
                details: String(format: "读取文件类型失败：不支持此类型，mode=%@。".localized, String(before.st_mode, radix: 8)))
        }
        try validateFlags(before, path: path, descriptor: fd)
        let attributeNames = try extendedAttributeNames(fd: fd, path: path)
        // Resource-fork loops retain their existing Swift-task cancellation
        // semantics. Retry this node on the caller, including a fork added
        // after enumeration, rather than moving those loops to Dispatch.
        if isParallelScanRead, attributeNames.contains(ResourceForkStream.attributeName) {
            throw SerialCaptureRequired()
        }
        let attributes = try extendedAttributes(fd: fd, names: attributeNames, path: path)
        let resourceFork: TreeCopySnapshot.ResourceFork?
        if attributeNames.contains(ResourceForkStream.attributeName) {
            let fork = ResourceForkStream.Handle(fileDescriptor: fd, parentDescriptor: parent, name: name, path: path)
            guard let size = try fork.size() else { throw TreeCopyError.sourceChanged(path) }
            resourceFork = .init(size: size, digest: try ResourceForkStream.digest(in: fork, byteCount: size))
            guard try fork.size() == size else { throw TreeCopyError.sourceChanged(path) }
        } else { resourceFork = nil }
        let acl = try aclText(fd: fd, path: path)
        // A signed bundle already carries a publisher manifest, so hashing every
        // file here would only restate what codesign proves more cheaply. The
        // strict profile keeps the digest because data directories have no
        // other content proof.
        let digest = kind == .file && profile.recordsContentDigests
            ? try (contentHasher ?? FileContentHasher()).digest(fd: fd, byteCount: before.st_size, path: path,
                checkpoint: { try scanReadCheckpoint() },
                didRead: { DataTransferSession.progress?.activity(bytesRead: $0) }) : nil
        let target: String?
        if kind == .symbolicLink {
            var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlinkat(parent, name, &bytes, bytes.count)
            guard count >= 0, count < bytes.count else { throw posix(path) }
            guard let decoded = String(bytes: bytes.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                throw TreeCopyError.unsupportedMetadata(diagnosticPath(fd: fd, fallback: path),
                    details: "读取符号链接失败：链接目标不是有效的 UTF-8 文本。".localized)
            }
            target = decoded
        } else { target = nil }
        try assertStable(before, try status(fd), path: path, profile: profile)
        DataTransferSession.current?.didReadContent(bytes: (kind == .file ? before.st_size : 0) + (resourceFork?.size ?? 0))
        return TreeCopySnapshot.Entry(path: path, kind: kind, identity: identity(before), mode: before.st_mode & 0o7777,
                                      // `UF_COMPRESSED` is storage detail, not content: the
                                      // destination is written uncompressed, so replaying it
                                      // would both fail to apply and break verification.
                                      // `UF_TRACKED` belongs to macOS document tracking;
                                      // do not replay or compare it across filesystem objects.
                                      uid: before.st_uid, gid: before.st_gid, flags: before.st_flags & UInt32(UF_HIDDEN | UF_NODUMP),
                                      birthTime: timestamp(before.st_birthtimespec), modificationTime: timestamp(before.st_mtimespec),
                                      extendedAttributes: attributes, resourceFork: resourceFork, acl: acl, size: kind == .file ? before.st_size : 0,
                                      digest: digest, linkTarget: target, hardlinkGroup: hardlinkGroup)
    }

    nonisolated private static func applyMetadata(_ entry: TreeCopySnapshot.Entry, fd: Int32,
                                                 ownership: MetadataOwnership,
                                                 profile: TreeCopyProfile = .strictData) throws {
        try setACL(nil, fd: fd, path: entry.path, profile: profile)
        if ownership != .unchanged, fchown(fd, entry.uid, entry.gid) != 0 {
            // The file is still usable on noowners when a non-root process
            // cannot assign a foreign owner. This exception is recorded only
            // for the destination; I/O errors and all other metadata stay strict.
            throw posix(entry.path)
        }
        let current = try extendedAttributeNames(fd: fd, path: entry.path)
        let fork = try recordedResourceFork(entry)
        for name in current where !systemManagedAttributes.contains(name) && entry.extendedAttributes[name] == nil {
            if name == ResourceForkStream.attributeName, fork != nil { continue }
            guard fremovexattr(fd, name, 0) == 0 else {
                throw metadataPOSIXError(fd: fd, path: entry.path, operation: .removeAttribute(name))
            }
        }
        // A compact manifest describes the expected fork; copying installed
        // its bytes from the source. Root metadata replay preserves those bytes
        // and the following capture verifies them rather than recreating data.
        if fork != nil, !current.contains(ResourceForkStream.attributeName) { throw TreeCopyError.verificationFailed(entry.path) }
        for (name, data) in portableAttributes(entry.extendedAttributes) {
            guard data.withUnsafeBytes({ fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }) == 0 else {
                throw metadataPOSIXError(fd: fd, path: entry.path, operation: .writeAttribute(name))
            }
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
        try setACL(entry.acl, fd: fd, path: entry.path, profile: profile)
    }

    nonisolated private static func extendedAttributeNames(fd: Int32, path: String) throws -> [String] {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 else { throw metadataPOSIXError(fd: fd, path: path, operation: .listAttributes) }
        var names = [UInt8](repeating: 0, count: size)
        let actual = names.withUnsafeMutableBytes { flistxattr(fd, $0.baseAddress?.assumingMemoryBound(to: CChar.self), size, 0) }
        guard actual == size else { throw TreeCopyError.sourceChanged(path) }
        return try names.split(separator: 0).map { raw in
            guard let name = String(bytes: raw, encoding: .utf8) else {
                throw TreeCopyError.unsupportedMetadata(diagnosticPath(fd: fd, fallback: path),
                    details: "读取扩展属性名称失败：属性名称不是有效的 UTF-8 文本。".localized)
            }
            return name
        }
    }

    nonisolated private static func extendedAttributes(fd: Int32, names: [String], path: String) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in names where name != ResourceForkStream.attributeName && !systemManagedAttributes.contains(name) {
            try scanReadCheckpoint()
            let count = fgetxattr(fd, name, nil, 0, 0, 0)
            guard count >= 0 else {
                throw metadataPOSIXError(fd: fd, path: path, operation: .readAttributeSize(name))
            }
            var bytes = Data(count: count)
            let read = bytes.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }
            guard read >= 0 else {
                throw metadataPOSIXError(fd: fd, path: path, operation: .readAttribute(name))
            }
            guard read == count else { throw TreeCopyError.sourceChanged(path) }
            result[name] = bytes
        }
        return result
    }

    nonisolated private static func aclText(fd: Int32, path: String) throws -> String? {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // `ENOENT` means "this object has no extended ACL". `ENOTSUP` means
            // the filesystem cannot report one at all (ExFAT, FAT); both are
            // "nothing to preserve", not a read failure.
            if errno == ENOENT || errno == ENOTSUP { return nil }
            throw posix(path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        if acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 { return nil }
        guard let text = acl_to_text(acl, nil) else { throw posix(path) }
        defer { acl_free(text) }
        return String(cString: text)
    }

    /// Applies an entry's ACL, tolerating storage that cannot carry one.
    ///
    /// A destination filesystem without extended ACLs (ExFAT, FAT) rejects every
    /// `acl_set_fd_np`, including the empty ACL used to mean "no ACL". Refusing
    /// the whole copy there would forbid migrating an application to a disk that
    /// runs it perfectly well, so an entry that has no ACL simply keeps the
    /// destination's default. An entry that *does* carry an ACL still fails: that
    /// is real metadata the user's application may rely on.
    ///
    /// This mirrors the tolerance the previous bundle copier had, and it is
    /// limited to the relaxed profile — a data directory keeps the strict
    /// contract, where an unsupported ACL means the copy cannot be proven.
    nonisolated private static func setACL(_ text: String?, fd: Int32, path: String,
                                           profile: TreeCopyProfile = .strictData) throws {
        let acl = text.map { acl_from_text($0) } ?? acl_init(0)
        guard let acl else { throw posix(path) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else {
            if text == nil, profile.toleratesUnsupportedACL, errno == ENOTSUP { return }
            throw posix(path)
        }
    }

    nonisolated private static func copyData(from source: Int32, to destination: Int32, size: Int64, path: String,
                                           extentSeek: @escaping ExtentSeek,
                                           progress: @Sendable (Int64) async -> Void) async throws {
        // Pass the source's compression state so the stream decodes instead of
        // copying physical extents (see FileDataCopyStream.init).
        var info = stat()
        let compressed = fstat(source, &info) == 0 && info.st_flags & UInt32(UF_COMPRESSED) != 0
        var stream = FileDataCopyStream(from: source, to: destination, size: size, path: path,
                                        extentSeek: extentSeek, isCompressed: compressed)
        while let offset = try stream.copyNextChunk() {
            // Preserve the verified data copier's existing progress behavior:
            // fallback files yield between chunks; native extents report once
            // their complete file and metadata have been verified by copyNode.
            if stream.usesExtentFallback, offset < size { await progress(offset) }
        }
    }

    nonisolated private static func openNode(parent: Int32, name: String, expectedDevice: Int32?) throws -> Descriptor {
        var before = stat()
        guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(name) }
        guard [S_IFDIR, S_IFREG, S_IFLNK, S_IFIFO].contains(before.st_mode & S_IFMT) else {
            throw TreeCopyError.unsupportedNode(diagnosticPath(fd: parent, child: name, fallback: name),
                details: String(format: "打开文件失败：不支持此文件类型，mode=%@。".localized, String(before.st_mode, radix: 8)))
        }
        try validateFlags(before, path: name, descriptor: parent, child: name)
        if let expectedDevice, before.st_dev != expectedDevice { throw TreeCopyError.mountBoundary(name) }
        // O_NONBLOCK prevents an intervening replacement by a FIFO from blocking.
        let linkOption = before.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW
        let descriptor = try Descriptor.openAt(parent, name, flags: O_RDONLY | O_NONBLOCK | linkOption)
        let after = try status(descriptor.value)
        guard identity(before) == identity(after), before.st_mode & S_IFMT == after.st_mode & S_IFMT else { throw TreeCopyError.sourceChanged(name) }
        return descriptor
    }

    /// macOS 12 has no mkfifoat. A child process can use the already-open
    /// directory as its working directory without changing this process's cwd
    /// or resolving a mutable absolute path. mkfifo still creates exclusively.
    nonisolated static func createNamedPipeUsingSystemUtility(parent: Int32, name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw TreeCopyError.unsafeLayout(name)
        }
        var actions: posix_spawn_file_actions_t?
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        result = posix_spawn_file_actions_addfchdir_np(&actions, parent)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        // Build argv with an explicit element type: inferring it from a trailing
        // `[nil]` makes Xcode 26 reject the String literals.
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for argument in ["/usr/bin/mkfifo", "-m", "600", "--", name] {
            guard let copy = strdup(argument) else { throw posix(name) }
            pointers.append(copy)
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        result = posix_spawn(&pid, "/usr/bin/mkfifo", &actions, nil, &pointers, &environment)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno == EINTR { continue }
            throw posix(name)
        }
        guard status == 0 else {
            throw TreeCopyError.unsupportedNode(diagnosticPath(fd: parent, child: name, fallback: name),
                details: String(format: "目标端创建命名管道失败：mkfifo 进程返回状态 %@。".localized, String(status)))
        }
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
            guard let name else {
                throw TreeCopyError.unsupportedMetadata(diagnosticPath(fd: fd, fallback: "（路径不可用）".localized),
                    details: "读取子项名称失败：名称不是有效的 UTF-8 文本。".localized)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    nonisolated private static func validateExcludedEntries(parent: Int32, names: [String]) throws {
        for name in names {
            var value = stat()
            guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(name) }
            guard value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else {
                throw TreeCopyError.unsupportedNode(diagnosticPath(fd: parent, child: name, fallback: name),
                    details: String(format: "检查保留项失败：只允许普通文件或目录，mode=%@。".localized, String(value.st_mode, radix: 8)))
            }
        }
    }

    nonisolated private static func ignoresOwnership(at url: URL) throws -> Bool {
        let fd = try Descriptor.open(url.path, flags: O_RDONLY | O_NOFOLLOW)
        return try ignoresOwnership(fd: fd.value, path: url.path)
    }

    nonisolated private static func ignoresOwnership(fd: Int32, path: String) throws -> Bool {
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw posix(path) }
        return filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
    }

    nonisolated private static func requireOwnership(fd: Int32, path: String, allowingIgnored: Bool) throws {
        if try ignoresOwnership(fd: fd, path: path), !allowingIgnored { throw TreeCopyError.ownershipDisabled(path) }
    }

    nonisolated private static func permitsProjectedOwnership(_ snapshot: TreeCopySnapshot, role: OwnershipRole) throws -> Bool {
        guard let compatibility = snapshot.ownershipCompatibility else { return false }
        guard compatibility.sourceIgnoresOwnership == (compatibility.projectedSourceOwner != nil) else {
            throw TreeCopyError.unsupportedMetadata("（路径未记录）".localized, details: "检查所有权记录失败：忽略所有权状态与记录的用户信息不一致。".localized)
        }
        return role == .source ? compatibility.sourceIgnoresOwnership : compatibility.destinationIgnoresOwnership
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

    nonisolated private static func compare(_ actual: TreeCopySnapshot, _ expected: TreeCopySnapshot, identities: Bool,
                                           ownershipRole: OwnershipRole = .source, rootPath: String,
                                           profile: TreeCopyProfile = .strictData) throws {
        let ownershipIsIgnored = try permitsProjectedOwnership(expected, role: ownershipRole)
        if !ownershipIsIgnored, actual.ownershipCompatibility?.sourceIgnoresOwnership == true {
            throw TreeCopyError.ownershipDisabled(rootPath)
        }
        // Also normalize older journals that included Finder display settings.
        let actualEntries = contentEntries(actual)
        let expectedEntries = contentEntries(expected)
        guard actualEntries.map(\.path) == expectedEntries.map(\.path) else { throw TreeCopyError.verificationFailed("") }
        for (actual, entry) in zip(actualEntries, expectedEntries) {
            try compareEntry(actual, ownershipRole == .destination ? expected.destinationEntry(entry) : entry,
                             identities: identities, compareOwnership: !ownershipIsIgnored, profile: profile)
        }
    }

    nonisolated private static func compareEntry(_ a: TreeCopySnapshot.Entry, _ b: TreeCopySnapshot.Entry,
                                                identities: Bool, compareOwnership: Bool = true,
                                                profile: TreeCopyProfile = .strictData) throws {
        // 时间戳仍按原值复制，但不单独作为内容不一致的依据。
        // 数据内容由摘要证明；读取期间的变化仍由 assertStable 检查。
        // A directory may carry a temporary owner-write bit while it is being
        // emptied; deletion restores it before reporting success. A filesystem
        // that cannot store POSIX permissions (ExFAT, FAT) reports a fixed mode
        // for everything, so the relaxed profile accepts what it cannot express.
        let modeMatches = a.mode == b.mode
            || (a.kind == .directory && a.mode == (b.mode | 0o700))
            || profile.toleratesUnsupportedPermissions
        // The relaxed profile accepts a destination that had to drop metadata
        // its filesystem cannot represent: an absent ACL, an absent resource
        // fork, or a materialised hardlink. The presence of extra metadata is
        // still a failure, so a genuine copy error is never hidden.
        let aclMatches = a.acl == b.acl
            || (profile.toleratesUnsupportedACL && a.acl == nil && b.acl != nil)
        let forkMatches = try recordedResourceFork(a) == recordedResourceFork(b)
            || (profile.toleratesUnsupportedResourceFork && recordedResourceFork(a) == nil)
        guard (!identities || a.identity == b.identity), a.path == b.path, a.kind == b.kind,
              modeMatches, (!compareOwnership || (a.uid == b.uid && a.gid == b.gid)), a.flags == b.flags,
              portableAttributes(a.extendedAttributes) == portableAttributes(b.extendedAttributes), aclMatches, a.size == b.size,
              forkMatches,
              a.digest == b.digest, a.linkTarget == b.linkTarget,
              (a.hardlinkGroup == b.hardlinkGroup
                || (profile.toleratesUnsupportedHardlink && a.kind == .file)) else {
            let checks: [(String, Bool)] = [
                ("identity", !identities || a.identity == b.identity), ("path", a.path == b.path),
                ("kind", a.kind == b.kind), ("mode", modeMatches),
                ("ownership", !compareOwnership || (a.uid == b.uid && a.gid == b.gid)),
                ("flags", a.flags == b.flags),
                ("extended_attributes", portableAttributes(a.extendedAttributes) == portableAttributes(b.extendedAttributes)),
                ("acl", aclMatches), ("size", a.size == b.size), ("resource_fork", forkMatches),
                ("content_digest", a.digest == b.digest), ("link_target", a.linkTarget == b.linkTarget),
                ("hardlinks", a.hardlinkGroup == b.hardlinkGroup || (profile.toleratesUnsupportedHardlink && a.kind == .file))
            ]
            AppLogger.shared.logContext("文件校验不一致，保留副本",
                details: [("relative_path", b.path), ("differences", checks.filter { !$0.1 }.map { $0.0 }.joined(separator: ", "))],
                level: "WARN")
            throw TreeCopyError.verificationFailed(b.path)
        }
    }

    nonisolated private static func portableAttributes(_ attributes: [String: Data]) -> [String: Data] {
        attributes.filter { !systemManagedAttributes.contains($0.key) && $0.key != ResourceForkStream.attributeName }
    }

    nonisolated private static func recordedResourceFork(_ entry: TreeCopySnapshot.Entry) throws -> TreeCopySnapshot.ResourceFork? {
        var result = entry.resourceFork
        // Decoding normalizes old manifests. Also accept an in-memory legacy
        // entry without silently allowing contradictory representations.
        if let raw = entry.extendedAttributes[ResourceForkStream.attributeName] {
            let legacy = TreeCopySnapshot.ResourceFork(size: Int64(raw.count), digest: try ResourceForkStream.digest(of: raw))
            guard result == nil || result == legacy else { throw TreeCopyError.verificationFailed(entry.path) }
            result = legacy
        }
        if let result, result.size < 0 || result.digest.count != 32 { throw TreeCopyError.verificationFailed(entry.path) }
        return result
    }

    nonisolated private static func validateLinks(_ snapshot: TreeCopySnapshot, source: URL, finalDestination: URL) throws {
        var linkTargets: [String: String] = [:]
        for entry in snapshot.entries where entry.kind == .symbolicLink {
            if let target = entry.linkTarget { linkTargets[entry.path] = target }
        }
        for entry in snapshot.entries where entry.kind == .symbolicLink {
            guard let target = entry.linkTarget, !target.hasPrefix("/") else { continue }
            let sourceLink = source.appendingPathComponent(entry.path)
            let finalLink = finalDestination.appendingPathComponent(entry.path)
            let sourceTarget = try projectedResolution(sourceLink.deletingLastPathComponent().appendingPathComponent(target).path,
                                                       root: source.path, linkTargets: linkTargets)
            let finalTarget = try projectedResolution(finalLink.deletingLastPathComponent().appendingPathComponent(target).path,
                                                      root: finalDestination.path, linkTargets: linkTargets)
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
                                                        linkTargets: [String: String], depth: Int = 0) throws -> String {
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
                if let target = linkTargets[relative] {
                    let next = target.hasPrefix("/") ? target : ((resolved as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
                    let combined = remaining.reduce(next) { ($0 as NSString).appendingPathComponent($1) }
                    return try projectedResolution(combined, root: root, linkTargets: linkTargets, depth: depth + 1)
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
    /// Resolve copy-operation text only after the failed syscall's errno is captured.
    private enum MetadataOperation {
        case removeAttribute(String)
        case writeAttribute(String)
        case listAttributes
        case readAttributeSize(String)
        case readAttribute(String)

        var localizedDescription: String {
            switch self {
            case .removeAttribute(let name):
                return String(format: "移除目标端扩展属性失败：%@".localized, name)
            case .writeAttribute(let name):
                return String(format: "写入扩展属性失败：%@".localized, name)
            case .listAttributes:
                return "读取扩展属性列表失败".localized
            case .readAttributeSize(let name):
                return String(format: "读取扩展属性大小失败：%@".localized, name)
            case .readAttribute(let name):
                return String(format: "读取扩展属性失败：%@".localized, name)
            }
        }
    }

    nonisolated private static func metadataPOSIXError(fd: Int32, path: String, operation: MetadataOperation) -> NSError {
        // F_GETPATH can change errno; capture the failed operation first.
        let code = errno
        let fullPath = diagnosticPath(fd: fd, fallback: path)
        let reason = String(cString: strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: fullPath,
            NSLocalizedDescriptionKey: String(format: "%@\n路径：%@\n系统错误：%@（errno=%@）".localized, operation.localizedDescription, fullPath, reason, String(code))
        ])
    }

    /// Resolve only for an error; traversal continues to use anchored descriptors.
    nonisolated private static func diagnosticPath(fd: Int32, child: String? = nil, fallback: String) -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &bytes) == 0 else { return fallback }
        let path = String(cString: bytes)
        return child.map { URL(fileURLWithPath: path).appendingPathComponent($0).path } ?? path
    }

    nonisolated private static func withCopyDiagnostics<T>(_ context: String, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { throw copyDiagnosticError(error, context: context) }
    }

    nonisolated private static func copyDiagnosticError(_ error: Error, context: String) -> Error {
        if let error = error as? TreeCopyError { return error.addingCopyContext(context) }
        let native = error as NSError
        guard native.domain == NSPOSIXErrorDomain else { return error }
        var details = native.userInfo
        details[NSLocalizedDescriptionKey] = context + "\n" + native.localizedDescription
        return NSError(domain: native.domain, code: native.code, userInfo: details)
    }

    nonisolated private static func validateFlags(_ value: stat, path: String,
                                                 descriptor: Int32, child: String? = nil) throws {
        // Validate before opening: opening a dataless item can hydrate it, and
        // opening an unsupported compression representation can alter flags.
        // `UF_COMPRESSED` is accepted: macOS compresses installed files on its
        // own (App Store executables, idle binaries), and a decmpfs stream is
        // decoded by an ordinary read. The data stream below reads such files
        // sequentially instead of trusting physical extents, and the flag is not
        // replayed, so the copy is stored as its logical bytes. `UF_TRACKED`
        // is OS-managed document tracking and is likewise not replayed or
        // compared. Every other flag still fails closed.
        let supported = UInt32(UF_HIDDEN | UF_NODUMP | UF_COMPRESSED | UF_TRACKED)
        let unsupported = value.st_flags & ~supported
        guard unsupported == 0 else {
            let knownFlags: [(String, UInt32)] = [
                ("UF_HIDDEN", UInt32(UF_HIDDEN)), ("UF_NODUMP", UInt32(UF_NODUMP)),
                ("UF_COMPRESSED", UInt32(UF_COMPRESSED)), ("UF_IMMUTABLE", UInt32(UF_IMMUTABLE)),
                ("UF_APPEND", UInt32(UF_APPEND)), ("UF_TRACKED", UInt32(UF_TRACKED)),
                ("UF_DATAVAULT", UInt32(UF_DATAVAULT)), ("SF_RESTRICTED", UInt32(SF_RESTRICTED)),
                ("SF_NOUNLINK", UInt32(SF_NOUNLINK))
            ]
            let names = knownFlags.filter { value.st_flags & $0.1 != 0 }.map(\.0).joined(separator: ", ")
            throw TreeCopyError.unsupportedMetadata(diagnosticPath(fd: descriptor, child: child, fallback: path),
                details: String(format: "检查文件标记失败：存在当前复制器不支持的标记。\n实际标记：0x%@%@\n不支持的位：0x%@\n允许的标记：UF_HIDDEN、UF_NODUMP、UF_COMPRESSED、UF_TRACKED；无标记也允许。".localized, String(value.st_flags, radix: 16), names.isEmpty ? "" : "（\(names)）", String(unsupported, radix: 16)))
        }
    }
    nonisolated private static func contains(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    nonisolated private static func status(_ fd: Int32) throws -> stat { var value = stat(); guard fstat(fd, &value) == 0 else { throw posix("") }; return value }
    nonisolated private static func identity(_ value: stat) -> TreeCopySnapshot.Identity { .init(device: value.st_dev, inode: value.st_ino) }
    nonisolated private static func timestamp(_ value: timespec) -> TreeCopySnapshot.Timestamp { .init(seconds: Int64(value.tv_sec), nanoseconds: Int64(value.tv_nsec)) }
    nonisolated private static func nativeTimestamp(_ value: TreeCopySnapshot.Timestamp) -> timespec { timespec(tv_sec: Int(value.seconds), tv_nsec: Int(value.nanoseconds)) }
    nonisolated private static func assertStable(_ a: stat, _ b: stat, path: String,
                                                 profile: TreeCopyProfile = .strictData) throws {
        // Identity, mode, size and link count always prove the same object was
        // read. The strict data profile additionally requires both timestamps to
        // be untouched, because a data directory has no publisher manifest to
        // fall back on. An application bundle tolerates timestamp drift: the
        // copy is verified against the baseline and the code signature.
        guard identity(a) == identity(b), a.st_mode == b.st_mode, a.st_size == b.st_size, a.st_nlink == b.st_nlink else {
            throw TreeCopyError.sourceChanged(path)
        }
        if profile.requiresStableTimestamps {
            guard timestamp(a.st_mtimespec) == timestamp(b.st_mtimespec),
                  timestamp(a.st_ctimespec) == timestamp(b.st_ctimespec) else {
                AppLogger.shared.logContext("读取期间文件时间发生变化",
                    details: [("relative_path", path),
                              ("mtime_changed", String(timestamp(a.st_mtimespec) != timestamp(b.st_mtimespec))),
                              ("ctime_changed", String(timestamp(a.st_ctimespec) != timestamp(b.st_ctimespec)))], level: "TRACE")
                throw TreeCopyError.sourceChanged(path)
            }
        }
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
    case unsupportedNode(String, details: String = "")
    case unsupportedMetadata(String, details: String = "")
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
             resourceFork: resourceFork,
             acl: acl, size: size, digest: digest, linkTarget: linkTarget, hardlinkGroup: group)
    }
}
