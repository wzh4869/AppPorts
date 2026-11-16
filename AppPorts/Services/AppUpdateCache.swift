import Darwin
import Foundation

/// Updaters can carry the application's immutable flags into independently copied caches.
struct AppUpdateCache {
    let directory: URL

    @discardableResult
    func unlockCaches(for application: URL, isFolder: Bool = false,
                       recheckAdmission: () throws -> Void) throws -> Int {
        let applications = isFolder
            ? try FileManager.default.contentsOfDirectory(at: application, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
            : [application]
        var unlocked = 0
        for app in applications {
            unlocked += try unlockCaches(forApp: app, recheckAdmission: recheckAdmission)
        }
        return unlocked
    }

    private func unlockCaches(forApp app: URL, recheckAdmission: () throws -> Void) throws -> Int {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.isEmpty, identifier != ".", identifier != "..", !identifier.contains("/"),
              app.pathExtension == "app" else { return 0 }
        var unlocked = 0
        for name in [identifier, identifier + ".ShipIt"] {
            unlocked += try unlockCache(at: directory.appendingPathComponent(name), identifier: identifier,
                                        recheckAdmission: recheckAdmission)
        }
        return unlocked
    }

    private func unlockCache(at cached: URL, identifier: String, recheckAdmission: () throws -> Void) throws -> Int {
        guard cached.standardizedFileURL == cached.resolvingSymlinksInPath(),
              try SignatureSnapshot.entryExists(cached),
              try SignatureSnapshot.info(at: cached).st_mode & S_IFMT == S_IFDIR else { return 0 }
        let entries = try SignatureSnapshot.items(in: cached).map { url in
            (url: url, info: try SignatureSnapshot.info(at: url), identity: try DataPathIdentity.capture(url))
        }
        guard entries.contains(where: { $0.info.st_flags & UInt32(UF_IMMUTABLE) != 0 }) else { return 0 }
        let cacheIdentity = try DataPathIdentity.capture(cached)
        // Unlock parents before their children; preserve every flag other than UF_IMMUTABLE.
        for entry in entries where entry.info.st_flags & UInt32(UF_IMMUTABLE) != 0 {
            let kind = entry.info.st_mode & S_IFMT
            // Do not change flags shared with an independent file outside this application's cache.
            guard entry.info.st_uid == getuid(), kind == S_IFDIR || kind == S_IFLNK
                || (kind == S_IFREG && entry.info.st_nlink == 1) else {
                AppLogger.shared.logContext("缓存项目无法单独解锁，保留此项目的锁",
                                           details: [("bundle_id", identifier), ("path", entry.url.path)], level: "WARN")
                continue
            }
            try recheckAdmission()
            guard cached.standardizedFileURL == cached.resolvingSymlinksInPath(),
                  try cacheIdentity.matchesFilesystemObject(DataPathIdentity.capture(cached)),
                  try entry.identity.matchesFilesystemObject(DataPathIdentity.capture(entry.url)) else {
                throw CodeSigner.SigningError.applicationChanged
            }
            let info = try SignatureSnapshot.info(at: entry.url)
            guard lchflags(entry.url.path, info.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: entry.url.path])
            }
        }
        AppLogger.shared.logContext("已解除应用缓存的更新保护锁",
                                   details: [("bundle_id", identifier), ("cache", cached.path)])
        return 1
    }
}
