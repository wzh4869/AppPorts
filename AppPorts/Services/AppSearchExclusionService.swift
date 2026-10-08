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
    }

    struct Result: Sendable {
        let destination: URL
        let dockSynchronized: Bool
    }
}
