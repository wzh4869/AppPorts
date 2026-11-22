import Foundation

/// 首页上次扫描确认的行。大小由 AppSizeCacheStore 提供，实时状态由当前扫描提供。
final class AppListCacheStore: @unchecked Sendable {
    enum Pane: String { case local, external }

    struct Source: Codable, Equatable, Sendable {
        struct Directory: Codable, Equatable, Sendable {
            let path: String
            let volumeUUID: String?
        }

        let directories: [Directory]

        var isIdentified: Bool {
            !directories.isEmpty && directories.allSatisfy { $0.volumeUUID != nil }
        }

        init(_ urls: [URL]) {
            directories = urls.map { Directory(path: $0.standardizedFileURL.path,
                                                volumeUUID: DiskUtility.mountedVolumeUUID(at: $0)) }
        }
    }

    struct Row: Codable, Equatable, Sendable {
        let name: String
        let path: String
        let bundlePath: String?
        let status: String
        let isFolder: Bool
        let appCount: Int
        let badgeLayout: AppBadgeLayout?
        let updateInspection: AppUpdateInspection?

        init(_ app: AppItem, context: UpdateRecommendationContext) {
            updateInspection = app.updateInspection
            badgeLayout = AppBadgeLayout(app: app, context: context)
            name = app.name
            path = app.id
            bundlePath = app.bundleURL?.path
            status = app.status
            isFolder = app.isFolder
            appCount = app.appCount
        }

        func preview(size: AppSizeCacheStore.Entry?, pane: Pane) -> AppItem {
            var app = AppItem(name: name, path: URL(fileURLWithPath: path),
                              bundleURL: bundlePath.map { URL(fileURLWithPath: $0) }, status: status,
                              isFolder: isFolder, appCount: appCount)
            app.cachedBadgeLayout = badgeLayout
            app.updateInspection = updateInspection
            if let size, size.isLocalPortal == (pane == .local && status == AppStatus.linked) {
                app.size = size.size
                app.sizeBytes = size.bytes
            }
            return app
        }
    }

    private struct Snapshot: Codable, Equatable {
        let version: Int
        let source: Source
        let rows: [Row]
    }

    static let shared = AppListCacheStore(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AppPorts", isDirectory: true))
    private let directory: URL
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.app-list-cache", qos: .utility)
    private var snapshots: [Pane: Snapshot] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func load(_ pane: Pane, source: Source, sizes: [String: AppSizeCacheStore.Entry]) -> [AppItem] {
        guard source.isIdentified else { return [] }
        let snapshot = queue.sync { () -> Snapshot? in
            if let cached = snapshots[pane] { return cached }
            guard let data = try? Data(contentsOf: fileURL(pane)),
                  let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
                  saved.version == 1 else { return nil }
            snapshots[pane] = saved
            return saved
        }
        guard let snapshot, snapshot.source == source else { return [] }
        return snapshot.rows.map { $0.preview(size: sizes[$0.path], pane: pane) }
    }

    func save(_ apps: [AppItem], pane: Pane, source: Source, context: UpdateRecommendationContext) {
        guard source.isIdentified else { return }
        queue.async { [self] in
            let snapshot = Snapshot(version: 1, source: source, rows: apps.map { Row($0, context: context) })
            guard snapshots[pane] != snapshot else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: fileURL(pane), options: .atomic)
                snapshots[pane] = snapshot
            } catch {
                AppLogger.shared.logError("保存首页应用清单失败", error: error)
            }
        }
    }

    private func fileURL(_ pane: Pane) -> URL {
        directory.appendingPathComponent("app-list-\(pane.rawValue).json")
    }
}
