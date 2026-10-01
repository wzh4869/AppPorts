import AppKit
import Darwin
import Foundation

/// Execution guards are independent from scanner/UI eligibility. All persistent
/// reads throw: a corrupt document can never authorize a destructive operation.
struct DataOperationSafety: Sendable {
    enum Failure: LocalizedError {
        case protectedPath(String), conflict(String), occupied(String), inspection(String)
        var errorDescription: String? {
            switch self {
            case .protectedPath(let path):
                return String(format: "此目录受迁移策略保护，请选择允许的子目录：%@".localized, path)
            case .conflict(let path):
                return String(format: "此目录与已有迁移或保留副本重叠，请先处理原迁移：%@".localized, path)
            case .occupied(let path):
                return String(format: "相关应用或进程仍在使用数据，请退出后重试：%@".localized, path)
            case .inspection(let path):
                return String(format: "无法完成数据安全检查，已停止操作并保留数据：%@".localized, path)
            }
        }
    }

    let homeDirectory: URL
    let store: ContainerMountStore
    var runner: any ShellCommandRunning = ProcessCommandRunner()

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()), store: ContainerMountStore = .shared,
         runner: any ShellCommandRunning = ProcessCommandRunner()) {
        self.homeDirectory = homeDirectory
        self.store = store
        self.runner = runner
    }

    func requireNewMigration(at source: URL, destination: URL? = nil, bundleIdentifier: String? = nil) async throws {
        try requirePolicy(at: source)
        try requireNoOverlap(at: source)
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

    func requirePolicy(at url: URL) throws {
        let policy = DataPathPolicy(homeDirectory: homeDirectory)
        let protectedRoots = ["Library/Containers", "Library/Group Containers"].map {
            homeDirectory.appendingPathComponent($0).path
        }
        guard policy.evaluate(url).canMigrate,
              !protectedRoots.contains(where: { [.same, .ancestor].contains(DataPathTopology.relationship(url.path, $0)) }) else {
            throw Failure.protectedPath(url.path)
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
    func requireNoKnownWriters(at url: URL, bundleIdentifier: String? = nil) async throws {
        if let bundleIdentifier, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            throw Failure.occupied(url.path)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw Failure.inspection(url.path)
        }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        let result = try await runner.run(executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-F", "p"] + (directory ? ["+D", url.path] : ["--", url.path]), timeout: 30)
        guard !result.timedOut, [0, 1].contains(result.status), result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.inspection(url.path)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = result.stdoutText.split(separator: "\n").compactMap { line -> Int32? in
            guard line.first == "p" else { return nil }
            return Int32(line.dropFirst())
        }
        guard processes.allSatisfy({ $0 == ownPID }) else { throw Failure.occupied(url.path) }
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
            throw Failure.inspection(url.path)
        }
        guard root.st_mode & S_IFMT == S_IFDIR else { return }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else { throw Failure.inspection(url.path) }
        for case let child as URL in enumerator {
            var info = stat()
            guard lstat(child.path, &info) == 0 else { throw Failure.inspection(child.path) }
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
        if enumerationError != nil { throw Failure.inspection(url.path) }
    }
}
