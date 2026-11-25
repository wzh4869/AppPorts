import AppKit
import Darwin
import Foundation

/// Execution guards are independent from scanner/UI eligibility. All persistent
/// reads throw: a corrupt document can never authorize a destructive operation.
struct DataOperationSafety: Sendable {
    enum Failure: LocalizedError {
        case protectedPath(String, DataPathPolicy.Reason? = nil)
        case conflict(String), occupied(String), inspection(String)
        case inspectionTimedOut(String)
        case writers(String, [String])
        case accessDenied(String)
        var errorDescription: String? {
            switch self {
            case .protectedPath(let path, let reason):
                if reason == .weChatCompatibility {
                    return String(
                        format: "为保证微信数据稳定，不支持直接迁移此目录：%@。请在“应用数据”页选择微信，对账号目录迁移或开启“微信账号拆分迁移”。".localized,
                        path
                    )
                }
                return String(format: "此目录受迁移策略保护，请选择允许的子目录：%@".localized, path)
            case .conflict(let path):
                return String(format: "此目录与已有迁移或保留副本重叠，请先处理原迁移：%@".localized, path)
            case .occupied(let path):
                return String(format: "相关应用或进程仍在使用数据，请退出后重试：%@".localized, path)
            case .inspection(let path):
                return String(format: "无法完成数据安全检查，已停止操作并保留数据：%@".localized, path)
            case .inspectionTimedOut(let path):
                return String(format: "数据安全检查超时，已停止操作并保留数据：%@".localized, path)
            case .writers(let path, let processes):
                return String(format: "以下进程正在写入数据，请退出后继续：%@\n%@".localized,
                    processes.joined(separator: "、"), path)
            case .accessDenied(let path):
                return "AppPorts 暂时无法访问这个位置，请在系统设置中检查访问权限，然后继续：".localized + path
            }
        }
    }

    let homeDirectory: URL
    let store: ContainerMountStore
    let partialWeChatMigrationEnabled: Bool
    let weChatContainerIdentifier: String
    var runner: any ShellCommandRunning = ProcessCommandRunner()

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()), store: ContainerMountStore = .shared,
         runner: any ShellCommandRunning = ProcessCommandRunner(),
         partialWeChatMigrationEnabled: Bool = false,
         weChatContainerIdentifier: String = PartialWeChatMigrationPolicy.bundleIdentifier) {
        self.homeDirectory = homeDirectory
        self.store = store
        self.runner = runner
        self.partialWeChatMigrationEnabled = partialWeChatMigrationEnabled
        self.weChatContainerIdentifier = weChatContainerIdentifier
    }

    func requireNewMigration(at source: URL, destination: URL? = nil, bundleIdentifier: String? = nil,
                             ownedTransferIDs: Set<UUID> = [], resumingRecordedMigration: Bool = false) async throws {
        if resumingRecordedMigration {
            try requireExistingMigrationPolicy(at: source, bundleIdentifier: bundleIdentifier)
        } else {
            try requirePolicy(at: source)
        }
        try requireNoOverlap(at: source, ownedTransferIDs: ownedTransferIDs)
        if let destination {
            guard !DataPathTopology.overlaps(DataPathTopology.relationship(source.path, destination.path)) else {
                throw Failure.conflict(destination.path)
            }
            try requireNoOverlap(at: destination)
        }
        try requireNoManagedFileSystemAncestor(at: source)
        try requireNoManagedDescendants(at: source)
        try await requireNoKnownWriters(at: source, bundleIdentifier: bundleIdentifier)
    }

    /// Existing journaled media migrations remain mountable after the UI switch is turned off.
    /// Callers must first verify that the mount/transfer belongs to the persistent store.
    func requireExistingMigrationPolicy(at url: URL, bundleIdentifier: String?) throws {
        guard let identifier = bundleIdentifier else {
            try requirePolicy(at: url)
            return
        }
        let policy = PartialWeChatMigrationPolicy(homeDirectory: homeDirectory, containerIdentifier: identifier)
        guard policy.account(forMember: url) != nil else {
            try requirePolicy(at: url)
            return
        }
        try DataOperationSafety(homeDirectory: homeDirectory, store: store, runner: runner,
                                partialWeChatMigrationEnabled: true, weChatContainerIdentifier: identifier)
            .requirePolicy(at: url)
    }

    func requirePolicy(at url: URL) throws {
        let policy = DataPathPolicy(homeDirectory: homeDirectory, partialWeChatMigrationEnabled: partialWeChatMigrationEnabled,
                                    weChatContainerIdentifier: weChatContainerIdentifier)
        let protectedRoots = ["Library/Containers", "Library/Group Containers"].map {
            homeDirectory.appendingPathComponent($0).path
        }
        let decision = policy.evaluate(url)
        guard decision.canMigrate,
              !protectedRoots.contains(where: { [.same, .ancestor].contains(DataPathTopology.relationship(url.path, $0)) }) else {
            throw Failure.protectedPath(url.path, decision.reason)
        }
    }

    func requireNoOverlap(at url: URL, ownedMount: ContainerMountRecord? = nil,
                          ownedTransferIDs: Set<UUID> = [], ownedLinkPath: String? = nil,
                          ownedRetainedPath: String? = nil) throws {
        var entries: [DataPathTopology.Entry] = []
        for record in try store.recordsStrict() {
            if let own = ownedMount, own == record,
               DataPathTopology.relationship(url.path, record.mountPointPath) == .same { continue }
            entries.append(.init(path: record.mountPointPath, origin: .mount, volumeUUID: record.volumeUUID))
        }
        for transfer in try store.transfers() {
            // Only exact roots of a proven related operation are exempted. Its
            // staging and backup paths still reserve their entire subtrees.
            for entry in transfer.topologyEntries {
                if ownedTransferIDs.contains(transfer.operationID), let ownedRetainedPath,
                   entry.path == ownedRetainedPath, url.path == ownedRetainedPath,
                   [transfer.backupPath, transfer.stagingPath].contains(ownedRetainedPath) { continue }
                if ownedTransferIDs.contains(transfer.operationID),
                   [transfer.originalPath, transfer.activePath, transfer.destinationPath].contains(entry.path),
                   DataPathTopology.relationship(url.path, entry.path) == .same { continue }
                entries.append(entry)
            }
        }
        for link in try store.managedLinks() {
            if ownedLinkPath == link.originalPath,
               [link.originalPath, link.destinationPath].contains(where: { DataPathTopology.relationship(url.path, $0) == .same }) { continue }
            entries.append(.init(path: link.originalPath, origin: .link, operationID: link.operationID))
            entries.append(.init(path: link.destinationPath, origin: .link, operationID: link.operationID))
        }
        for cleanup in try store.pendingCleanups() {
            entries.append(.init(path: cleanup.localPath, origin: .retained))
            if let staging = cleanup.restoreStagingPath { entries.append(.init(path: staging, origin: .retained)) }
        }
        if let conflict = DataPathTopology(entries: entries).conflicts(with: url.path).first {
            throw Failure.conflict(conflict.entry.path)
        }
    }

    /// Read-only observation, not a lock against future writers. Checks run again
    /// before switching/cleanup; verified originals remain retained afterwards.
    func requireNoKnownWriters(at url: URL, bundleIdentifier: String? = nil,
                               preferWholeVolumeInspection: Bool = false,
                               excludingRootEntries: Set<String> = []) async throws {
        try requireApplicationStopped(at: url, bundleIdentifier: bundleIdentifier)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            if errno == EACCES || errno == EPERM {
                AppLogger.shared.logContext("数据写入者检查被拒绝访问", details: [
                    ("path", url.path),
                    ("errno", String(errno))
                ], level: "WARN")
                throw Failure.accessDenied(url.path)
            }
            throw Failure.inspection(url.path)
        }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        let selection: [String]
        let timeout: TimeInterval
        if preferWholeVolumeInspection, directory,
           let mountPoint = DiskUtility.mountedVolumePath(containing: url),
           DiskUtility.pathsMatch(mountPoint, url.path) {
            // Select open handles by filesystem instead of enumerating its files.
            selection = ["+f", "--", mountPoint]
            timeout = 30
        } else {
            // +D walks the tree before reporting any open handles.
            selection = directory ? ["+D", url.path] : ["--", url.path]
            timeout = directory ? 1800 : 30
        }
        let result = try await runner.run(executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-F", "pcfa"] + selection, timeout: timeout)
        let unexplained = Self.unexplainedLsofDiagnostics(in: result.stderrText, root: url,
                                                          excludingRootEntries: excludingRootEntries)
        func boundedDiagnostic(_ lines: [String]) -> String {
            let joined = lines.joined(separator: "\n")
            guard joined.count > 512 else { return joined }
            return String(joined.prefix(512)) + "…"
        }
        let permissionLines = unexplained.filter {
            let lower = $0.lowercased()
            return lower.contains("permission denied") || lower.contains("operation not permitted")
        }
        if !permissionLines.isEmpty {
            let failingPath = permissionLines.compactMap(Self.lsofWarningTargetPath(in:)).first ?? url.path
            AppLogger.shared.logContext("数据写入者检查被拒绝访问", details: [
                ("path", url.path),
                ("failing_path", failingPath),
                ("status", String(result.status)),
                ("stderr", boundedDiagnostic(unexplained))
            ], level: "WARN")
            throw Failure.accessDenied(failingPath)
        }
        guard !result.timedOut else {
            AppLogger.shared.logContext("数据写入者检查超时", details: [
                ("path", url.path),
                ("status", String(result.status)),
                ("stderr", boundedDiagnostic(unexplained))
            ], level: "WARN")
            throw Failure.inspectionTimedOut(url.path)
        }
        guard [0, 1].contains(result.status), unexplained.isEmpty else {
            AppLogger.shared.logContext("数据写入者检查失败", details: [
                ("path", url.path),
                ("status", String(result.status)),
                ("stderr", boundedDiagnostic(unexplained))
            ], level: "WARN")
            throw Failure.inspection(url.path)
        }
        let writers = Self.writingProcesses(in: result.stdoutText, ownPID: ProcessInfo.processInfo.processIdentifier)
        guard writers.isEmpty else { throw Failure.writers(url.path, writers) }
    }

    static func unexplainedLsofDiagnostics(in stderr: String, root: URL,
                                            excludingRootEntries: Set<String>) -> [String] {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !excludingRootEntries.isEmpty else { return lines }
        var allowedRoots: Set<String> = [
            root.standardizedFileURL.path,
            root.resolvingSymlinksInPath().standardizedFileURL.path
        ]
        // URL.resolvingSymlinksInPath() strips `/private` from `/private/var` and `/private/tmp`,
        // whereas `lsof` reports POSIX realpath prefixes.
        if let resolved = realpath(root.path, nil) {
            allowedRoots.insert(String(cString: resolved))
            free(resolved)
        }
        return lines.filter { line in
            !isExcludedVolumeArtifactWarning(line, allowedRoots: allowedRoots, excludingRootEntries: excludingRootEntries)
        }
    }

    private static func isExcludedVolumeArtifactWarning(_ line: String, allowedRoots: Set<String>,
                                                        excludingRootEntries: Set<String>) -> Bool {
        guard let parsed = parseLsofWarning(in: line) else { return false }
        let reason = parsed.reason.lowercased()
        guard reason.contains("permission denied") || reason.contains("operation not permitted") else { return false }
        return allowedRoots.contains { rootPath in
            let suffix: Substring
            if rootPath == "/" {
                guard parsed.path.hasPrefix("/") else { return false }
                suffix = parsed.path.dropFirst()
            } else {
                guard parsed.path.hasPrefix(rootPath + "/") else { return false }
                suffix = parsed.path.dropFirst(rootPath.count + 1)
            }
            let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
            return excludingRootEntries.contains(String(components[0]))
        }
    }

    static func lsofWarningTargetPath(in line: String) -> String? {
        parseLsofWarning(in: line)?.path
    }

    private static func parseLsofWarning(in line: String) -> (path: String, reason: String)? {
        let prefix = "lsof: warning: can't "
        let lower = line.lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        let afterPrefix = line.index(line.startIndex, offsetBy: prefix.count)
        guard let openParen = line[afterPrefix...].firstIndex(of: "(") else { return nil }
        let syscall = line[afterPrefix..<openParen].trimmingCharacters(in: .whitespaces).lowercased()
        guard ["opendir", "lstat", "stat", "readlink"].contains(syscall) else { return nil }
        let pathStart = line.index(after: openParen)
        guard let closeRange = line.range(of: "): ", options: .backwards, range: pathStart..<line.endIndex) else {
            return nil
        }
        let path = String(line[pathStart..<closeRange.lowerBound])
        let reason = String(line[closeRange.upperBound...])
        guard !path.isEmpty else { return nil }
        return (path, reason)
    }

    /// A leased empty, locked mount point has no data tree to enumerate. Its
    /// lease guards the directory while this check guards the associated app.
    func requireApplicationStopped(at url: URL, bundleIdentifier: String?) throws {
        if let bundleIdentifier, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            throw Failure.occupied(url.path)
        }
    }

    /// A mounted external root can be readable even when TCC denies its local
    /// container parent. Prove that the parent can be opened before removing
    /// the overlay; statfs/lstat of the mounted root cannot prove this access.
    func requireMountPointParentAccess(at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        func failure() -> Failure {
            errno == EACCES || errno == EPERM ? .accessDenied(parent.path) : .inspection(parent.path)
        }
        let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        guard let directory = fdopendir(descriptor) else {
            let error = failure()
            close(descriptor)
            throw error
        }
        defer { closedir(directory) }
        // One entry is enough to exercise directory access. Do not rescan the
        // application's data or enumerate the entire parent for this preflight.
        errno = 0
        _ = readdir(directory)
        guard errno == 0 else { throw failure() }
    }

    /// Access fields belong to individual descriptors, not to the process.
    /// Unknown file access remains conservative; executable/cwd handles and
    /// explicit read-only descriptors do not imply that data is being written.
    static func writingProcesses(in output: String, ownPID: Int32) -> [String] {
        var pid: Int32?, name: String?, descriptor: String?, access: String?
        var sawDescriptor = false, writes = false
        var result: [String] = []
        func finishDescriptor() {
            guard let descriptor else { return }
            if access == "r" { return }
            if access == "w" || access == "u" { writes = true; return }
            if !["cwd", "rtd", "txt"].contains(descriptor) { writes = true }
        }
        func finishProcess() {
            finishDescriptor()
            if let pid, pid != ownPID, writes || !sawDescriptor {
                result.append(name.map { "\($0) (\(pid))" } ?? String(pid))
            }
        }
        for line in output.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p":
                finishProcess()
                pid = Int32(value); name = nil; descriptor = nil; access = nil
                sawDescriptor = false; writes = false
            case "c": name = value
            case "f":
                finishDescriptor()
                descriptor = value; access = nil; sawDescriptor = true
            case "a": access = value
            default: break
            }
        }
        finishProcess()
        return result
    }

    /// Legacy symlinks predate the index. A managed ancestor still blocks child
    /// operations; ordinary system path aliases are not treated as migrations.
    func requireNoManagedFileSystemAncestor(at url: URL) throws {
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: parent.path)) != nil {
                let target = parent.resolvingSymlinksInPath()
                let marker = target.appendingPathComponent(".appports-link-metadata.plist")
                if FileManager.default.fileExists(atPath: marker.path) { throw Failure.conflict(parent.path) }
            }
            parent.deleteLastPathComponent()
        }
    }

    /// Restore copies must land on local storage, never through a migrated parent.
    /// Check again before switching because a parent may change while copying.
    func requireLocalRestoreParent(at url: URL,
                                   isMountPoint: (URL) -> Bool = { DiskUtility.isMountPoint($0) }) throws {
        try requireNoManagedFileSystemAncestor(at: url)
        let fileManager = FileManager.default
        var nearest = url.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: nearest.path), nearest.path != "/" { nearest.deleteLastPathComponent() }
        nearest.removeAllCachedResourceValues()
        if try nearest.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal == false {
            throw Failure.conflict(nearest.path)
        }
        var parent = url.deletingLastPathComponent()
        while parent.path != "/", parent.path != homeDirectory.standardizedFileURL.path {
            if (try? fileManager.destinationOfSymbolicLink(atPath: parent.path)) != nil || isMountPoint(parent) {
                throw Failure.conflict(parent.path)
            }
            parent.deleteLastPathComponent()
        }
    }

    func requireNoManagedDescendants(at url: URL) throws {
        var root = stat()
        guard lstat(url.path, &root) == 0 else {
            if errno == ENOENT { return }
            if errno == EACCES || errno == EPERM { throw Failure.accessDenied(url.path) }
            throw Failure.inspection(url.path)
        }
        guard root.st_mode & S_IFMT == S_IFDIR else { return }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else { throw Failure.inspection(url.path) }
        for case let child as URL in enumerator {
            var info = stat()
            guard lstat(child.path, &info) == 0 else {
                if errno == EACCES || errno == EPERM { throw Failure.accessDenied(child.path) }
                throw Failure.inspection(child.path)
            }
            guard info.st_dev == root.st_dev else { throw Failure.conflict(child.path) }
            if info.st_mode & S_IFMT == S_IFLNK {
                enumerator.skipDescendants()
                let target = child.resolvingSymlinksInPath()
                let markers = [target.appendingPathComponent(".appports-link-metadata.plist"),
                               URL(fileURLWithPath: target.path + ".appports-link-metadata.plist")]
                if markers.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    throw Failure.conflict(child.path)
                }
            }
        }
        if let enumerationError { throw enumerationError }
    }
}
