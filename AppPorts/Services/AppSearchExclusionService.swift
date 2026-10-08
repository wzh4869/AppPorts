import Foundation

/// Only application bundles belong in this directory. Never exclude the selected volume/root.
enum AppSearchExclusionService {
    static let libraryName = "AppPorts.noindex"

    static func library(in directory: URL) -> URL {
        directory.lastPathComponent == libraryName ? directory : directory.appendingPathComponent(libraryName)
    }

    static func isExcluded(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == libraryName
    }

    /// Inspect the bundle again at execution time; scan flags may be stale or from older versions.
    static func unsupportedReason(for app: AppItem) -> String? {
        guard !app.usesFolderOperation, app.path.pathExtension.lowercased() == "app" else {
            return "套件目录可能包含文档，暂不自动排除。".localized
        }
        let fm = FileManager.default
        if app.isAppStoreApp || app.isMASExternal || app.isIOSApp
            || fm.fileExists(atPath: app.path.appendingPathComponent("Contents/_MASReceipt/receipt").path)
            || fm.fileExists(atPath: app.path.appendingPathComponent("Wrapper").path)
            || fm.fileExists(atPath: app.path.appendingPathComponent("WrappedBundle").path) {
            return "App Store 和 iOS 应用保留原安装路径，暂不自动排除。".localized
        }
        guard let values = try? app.path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let plist = NSDictionary(contentsOf: app.path.appendingPathComponent("Contents/Info.plist")),
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              !AppMigrationService().isManagedPortal(at: app.path) else {
            return "无法确认真实应用身份，未更改存储位置。".localized
        }
        return nil
    }

    /// Shared by the UI's operation result and migration service, so records use the actual path.
    static func destination(for app: AppItem, in directory: URL) -> URL {
        if app.isAppStoreApp && AppMigrationService.isMASExternalInstallSupported {
            return AppMigrationService.masApplicationsURL(for: directory).appendingPathComponent(app.name)
        }
        let parent = unsupportedReason(for: app) == nil ? library(in: directory) : directory
        return parent.appendingPathComponent(app.name)
    }

    /// Used by both external discovery and local-version comparisons.
    static func applicationItems(in directory: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let rootItems = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return rootItems.flatMap { item -> [URL] in
            guard item.lastPathComponent == libraryName else { return [item] }
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return [] }
            return ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? [])
                .filter { $0.pathExtension == "app" }
        }
    }

    static func prepareLibrary(_ directory: URL, fileManager fm: FileManager = .default) throws {
        let parent = directory.deletingLastPathComponent()
        guard directory.lastPathComponent == libraryName,
              parent.resolvingSymlinksInPath().standardizedFileURL == parent.standardizedFileURL else {
            throw failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
        }
        // lstat-style attributes also see a dangling symlink.
        if let attributes = try? fm.attributesOfItem(atPath: directory.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        guard (try directory.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject)
            == (try parent.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject) else {
            throw failure("应用存储路径存在冲突或已改变，未执行操作。".localized)
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "AppPorts.SearchExclusion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// A recovery record reserves only its app and portals. Unknown records remain blocking;
    /// never infer completion from the .noindex path or discard recovery material here.
    static func blockingJournal(in library: URL, affecting paths: [URL],
                                fileManager fm: FileManager = .default) throws -> URL? {
        let pending = try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".appports-exclusion-") && $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
        guard !pending.isEmpty else { return nil }
        let volume = try library.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        let affectedPaths = paths.flatMap { [$0.standardizedFileURL, $0.resolvingSymlinksInPath().standardizedFileURL] }
        let identities = affectedPaths.compactMap { try? FileIdentity.read($0, fileManager: fm) }
        for url in pending {
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let data = try? Data(contentsOf: url),
                  let journal = try? JSONDecoder().decode(Journal.self, from: data),
                  journal.hasValidScope(in: library, volumeUUID: volume) else { return url }
            let reserved = [journal.source, journal.destination]
                + journal.portals.flatMap { [$0.local, $0.backup, $0.stage, $0.stage.deletingLastPathComponent()] }
            let reservedPaths = reserved.flatMap { [$0.standardizedFileURL, $0.resolvingSymlinksInPath().standardizedFileURL] }
            if reservedPaths.contains(where: { reserved in
                affectedPaths.contains { pathsOverlap(reserved, $0) }
            }) || identities.contains(journal.sourceIdentity)
                || journal.portals.contains(where: { identities.contains($0.identity) }) {
                return url
            }
        }
        return nil
    }

    private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path == rhs.path || lhs.path.hasPrefix(rhs.path + "/") || rhs.path.hasPrefix(lhs.path + "/")
    }

    struct FileIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        static func read(_ url: URL, fileManager: FileManager = .default) throws -> Self {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                throw failure("无法确认真实应用身份，未更改存储位置。".localized)
            }
            return Self(device: device.uint64Value, inode: inode.uint64Value)
        }
    }

    /// Kept on failure if rollback encounters a conflicting user file. Never discard recoverable data.
    struct Journal: Codable {
        struct Portal: Codable {
            let local: URL
            let backup: URL
            let stage: URL
            let identity: FileIdentity
        }
        let source: URL
        let destination: URL
        let sourceIdentity: FileIdentity
        let volumeUUID: String
        let portals: [Portal]
        var phase = "prepared"

        /// Validate the format before treating a journal as unrelated to another app.
        fileprivate func hasValidScope(in library: URL, volumeUUID currentVolume: String?) -> Bool {
            let library = library.standardizedFileURL
            let urls = [source, destination] + portals.flatMap { [$0.local, $0.backup, $0.stage] }
            guard urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
                && $0.path == $0.standardizedFileURL.path }),
                  currentVolume == volumeUUID, !volumeUUID.isEmpty,
                  ["prepared", "external-moved", "portals-installed"].contains(phase),
                  sourceIdentity.inode > 0,
                  source.deletingLastPathComponent().standardizedFileURL == library.deletingLastPathComponent(),
                  destination.deletingLastPathComponent().standardizedFileURL == library,
                  source.pathExtension.lowercased() == "app",
                  source.lastPathComponent == destination.lastPathComponent else { return false }
            return portals.allSatisfy { portal in
                let parent = portal.local.deletingLastPathComponent().standardizedFileURL
                let stageRoot = portal.stage.deletingLastPathComponent().standardizedFileURL
                let prefix = ".appports-exclusion-"
                return portal.local.pathExtension.lowercased() == "app" && portal.identity.inode > 0
                    && parent.resolvingSymlinksInPath().path == parent.path
                    && stageRoot.deletingLastPathComponent() == parent
                    && stageRoot.lastPathComponent.hasPrefix(prefix)
                    && UUID(uuidString: String(stageRoot.lastPathComponent.dropFirst(prefix.count))) != nil
                    && portal.stage.lastPathComponent == portal.local.lastPathComponent
                    && portal.backup.standardizedFileURL == stageRoot.appendingPathComponent("original")
            }
        }
    }

    struct Result: Sendable {
        let destination: URL
        let dockSynchronized: Bool
    }
}
