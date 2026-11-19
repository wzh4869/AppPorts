import Foundation

/// 评估应用数据目录是否允许读写展示大小缓存，并生成包含子目录挂载/链接拓扑的缓存身份。
struct AppDataSizeCachePolicy: Sendable {
    struct MountState: Sendable {
        let path: String
        let volumeUUID: String
        let isMounted: Bool
    }

    struct ManagedLinkState: Sendable {
        let sourcePath: String
        let destinationPath: String
    }

    let allowCaching: Bool
    let uncacheablePaths: Set<String>
    let mountStates: [MountState]
    let managedLinks: [ManagedLinkState]

    static let empty = AppDataSizeCachePolicy(
        allowCaching: true,
        uncacheablePaths: [],
        mountStates: [],
        managedLinks: []
    )

    init(
        allowCaching: Bool,
        uncacheablePaths: Set<String>,
        mountStates: [MountState],
        managedLinks: [ManagedLinkState]
    ) {
        self.allowCaching = allowCaching
        self.uncacheablePaths = uncacheablePaths
        self.mountStates = mountStates
        self.managedLinks = managedLinks
    }

    init(
        inspection: ContainerMountStore.Inspection?,
        pausedMountDirectories: Set<URL>,
        isMountPoint: (URL) -> Bool
    ) {
        allowCaching = inspection != nil && inspection?.validationError == nil

        var blockedPaths: Set<String> = []
        for url in pausedMountDirectories {
            let standardized = url.standardizedFileURL
            blockedPaths.insert(standardized.path)
            blockedPaths.insert(standardized.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        for transfer in inspection?.transfers ?? []
        where transfer.retainedCopyRemovedAt == nil && transfer.rollbackCompletedAt == nil {
            blockedPaths.insert(URL(fileURLWithPath: transfer.originalPath).standardizedFileURL.path)
            blockedPaths.insert(URL(fileURLWithPath: transfer.activePath).standardizedFileURL.path)
            if let backupPath = transfer.backupPath {
                blockedPaths.insert(URL(fileURLWithPath: backupPath).standardizedFileURL.path)
            }
            if let stagingPath = transfer.stagingPath {
                blockedPaths.insert(URL(fileURLWithPath: stagingPath).standardizedFileURL.path)
            }
        }
        for cleanup in inspection?.cleanups ?? [] {
            blockedPaths.insert(URL(fileURLWithPath: cleanup.localPath).standardizedFileURL.path)
            blockedPaths.insert(URL(fileURLWithPath: cleanup.mountRecord.mountPointPath).standardizedFileURL.path)
            if let stagingPath = cleanup.restoreStagingPath {
                blockedPaths.insert(URL(fileURLWithPath: stagingPath).standardizedFileURL.path)
            }
        }
        uncacheablePaths = blockedPaths

        mountStates = (inspection?.mounts ?? []).map { record in
            let url = record.mountPointURL.standardizedFileURL
            return MountState(
                path: url.path,
                volumeUUID: record.volumeUUID.uppercased(),
                isMounted: isMountPoint(url)
            )
        }
        managedLinks = (inspection?.managedLinks ?? []).map { link in
            ManagedLinkState(
                sourcePath: URL(fileURLWithPath: link.originalPath).standardizedFileURL.path,
                destinationPath: URL(fileURLWithPath: link.destinationPath).standardizedFileURL.path
            )
        }
    }

    static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        if a == "/" || b == "/" { return true }
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    func isCacheable(item: DataDirItem) -> Bool {
        guard allowCaching,
              item.weChatSplitMembers.isEmpty,
              let measurementURL = item.sizeMeasurementURL else {
            return false
        }
        if DataDirStatus.mountStatuses.contains(item.status),
           item.status != DataDirStatus.mounted {
            return false
        }
        let sourcePath = item.path.standardizedFileURL.path
        let measurePath = measurementURL.standardizedFileURL.path
        let canonicalMeasurePath = measurementURL.resolvingSymlinksInPath().standardizedFileURL.path
        return !uncacheablePaths.contains {
            Self.pathsOverlap($0, sourcePath)
                || Self.pathsOverlap($0, measurePath)
                || Self.pathsOverlap($0, canonicalMeasurePath)
        }
    }

    func topologyFingerprint(for item: DataDirItem) -> String {
        let sourcePath = item.path.standardizedFileURL.path
        var tokens: [String] = []
        for mount in mountStates where mount.path == sourcePath || mount.path.hasPrefix(sourcePath + "/") {
            tokens.append("M:\(mount.path):\(mount.volumeUUID):\(mount.isMounted ? 1 : 0)")
        }
        for link in managedLinks where link.sourcePath == sourcePath || link.sourcePath.hasPrefix(sourcePath + "/") {
            tokens.append("L:\(link.sourcePath)->\(link.destinationPath)")
        }
        return tokens.sorted().joined(separator: ";")
    }

    func cacheIdentity(for item: DataDirItem) -> String? {
        guard isCacheable(item: item) else { return nil }
        return ToolDirectorySizeCacheStore.identity(for: item, topologyFingerprint: topologyFingerprint(for: item))
    }
}

/// 仅供界面展示的目录大小，不参与迁移校验。
final class ToolDirectorySizeCacheStore: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let identity: String
        let sourcePath: String
        let targetPath: String
        let bytes: Int64
        let measuredAt: Date
    }

    struct Snapshot: Codable, Sendable {
        var version = 1
        var entries: [String: Entry] = [:]
        var updatedAt: Date? { entries.values.map(\.measuredAt).max() }
    }

    static let shared = ToolDirectorySizeCacheStore()
    static let customDirectories = ToolDirectorySizeCacheStore(fileName: "custom-directory-sizes.json")
    static let appDataDirectories = ToolDirectorySizeCacheStore(fileName: "app-data-directory-sizes.json")
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.tool-size-cache", qos: .utility)
    private let fileURL: URL
    private var epoch: UInt64 = 0
    private var clearedEpoch: UInt64 = 0
    private var invalidatedEpochByPath: [String: UInt64] = [:]

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }

    init(fileName: String = "tool-directory-sizes.json") {
        if Self.isRunningTests {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppPortsTestCaches-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent(fileName)
        } else {
            fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AppPorts/" + fileName)
        }
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 路径、状态、目标文件系统身份或子目录拓扑变化后，旧大小不再适用。
    static func identity(for item: DataDirItem, topologyFingerprint: String? = nil) -> String? {
        guard let url = item.sizeMeasurementURL?.resolvingSymlinksInPath().standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        var components = [
            item.path.standardizedFileURL.path,
            url.path,
            item.status,
            device.stringValue,
            inode.stringValue
        ]
        if let topologyFingerprint {
            components.append("topo=" + topologyFingerprint)
        }
        return components.joined(separator: "\n")
    }

    func currentEpoch() -> UInt64 {
        queue.sync { epoch }
    }

    func load() -> Snapshot { queue.sync { read() } }

    func save(_ snapshot: Snapshot) { queue.sync { write(snapshot) } }

    func removeAll() {
        queue.sync {
            epoch &+= 1
            clearedEpoch = epoch
            invalidatedEpochByPath.removeAll()
            write(Snapshot())
        }
    }

    func invalidate(for url: URL) {
        queue.sync {
            epoch &+= 1
            let path = url.standardizedFileURL.path
            invalidatedEpochByPath[path] = epoch
            var snapshot = read()
            let oldCount = snapshot.entries.count
            snapshot.entries = snapshot.entries.filter { _, entry in
                !AppDataSizeCachePolicy.pathsOverlap(entry.sourcePath, path)
                    && !AppDataSizeCachePolicy.pathsOverlap(entry.targetPath, path)
            }
            if snapshot.entries.count != oldCount { write(snapshot) }
        }
    }

    func merge(_ entries: [Entry], startedAtEpoch: UInt64) {
        queue.sync {
            guard !entries.isEmpty, clearedEpoch <= startedAtEpoch else { return }
            let newerInvalidations = invalidatedEpochByPath.filter { $0.value > startedAtEpoch }
            let validEntries = entries.filter { entry in
                !newerInvalidations.contains { invPath, _ in
                    AppDataSizeCachePolicy.pathsOverlap(entry.sourcePath, invPath)
                        || AppDataSizeCachePolicy.pathsOverlap(entry.targetPath, invPath)
                }
            }
            guard !validEntries.isEmpty else { return }
            var snapshot = read()
            for entry in validEntries {
                snapshot.entries[entry.sourcePath] = entry
            }
            write(snapshot)
        }
    }

    private func read() -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Snapshot() }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
            return snapshot.version == 1 ? snapshot : Snapshot()
        } catch {
            AppLogger.shared.logError("读取工具目录大小缓存失败，将重新统计", error: error)
            return Snapshot()
        }
    }

    private func write(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.shared.logError("保存工具目录大小缓存失败", error: error)
        }
    }
}
