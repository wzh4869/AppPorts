import Foundation
import Darwin

/// 首页展示专用。规则变更时递增 revision，旧记录保留行名但重新识别组件。
struct AppUpdateInspection: Codable, Equatable, Sendable {
    struct Key: Codable, Equatable, Sendable {
        let revision: Int
        let realPath: String
        let bundleIdentifier: String
        let version: String?
        let build: String?
        let device: dev_t
        let inode: ino_t

        init?(_ identity: ResolvedAppIdentity, info: stat?) {
            guard let info,
                  identity.shortVersion?.isEmpty == false || identity.buildVersion?.isEmpty == false else { return nil }
            revision = 1
            realPath = identity.realAppURL.path
            bundleIdentifier = identity.bundleIdentifier
            version = identity.shortVersion
            build = identity.buildVersion
            device = info.st_dev
            inode = info.st_ino
        }
    }

    struct Frameworks: Codable, Equatable, Sendable {
        let electron: Bool
        let sparkle: Bool
        let selfUpdater: Bool
        let needsLock: Bool

        func apply(to app: inout AppItem) {
            app.isElectronApp = electron
            app.isSparkleApp = sparkle
            app.hasSelfUpdater = selfUpdater
            app.needsLock = needsLock
        }
    }

    let key: Key
    let mechanism: AppUpdateRoute.Mechanism
    let frameworks: Frameworks?
    let localEntry: URL?
    let isAppStoreApp: Bool
    let isIOSApp: Bool
    let isSystemApp: Bool

    /// A lock or a prepared Tauri portal can change without changing the installed version.
    static func apply(_ mechanism: AppUpdateRoute.Mechanism, to app: inout AppItem, identity: ResolvedAppIdentity,
                      info: stat?, bundleURL: URL, localEntry: URL?) {
        let beforeMigration = mechanism == .tauriSameVolume && localEntry == nil && app.status == AppStatus.local
            && (try? bundleURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
            && bundleURL.resolvingSymlinksInPath() == identity.realAppURL
        app.updateRoute = mechanism.route(for: identity, localEntry: localEntry ?? bundleURL, beforeMigration: beforeMigration)
        app.bodyMigrationPolicy = identity.bodyMigrationPolicy
        app.bundleIsLocked = info.map { $0.st_flags & UInt32(UF_IMMUTABLE) != 0 }
        if AppMigrationService.usesOrdinaryUpdateMigration(bundleIdentifier: identity.bundleIdentifier) {
            app.needsLock = false
        } else if [.sparkle, .shipIt, .nativeShipIt].contains(app.updateRoute) {
            app.needsLock = true
        }
    }

    func verifiedPreview(_ row: AppItem) -> AppItem? {
        let url = row.displayURL
        guard case .success(let identity) = AppIdentityResolver.resolve(at: url),
              let info = try? SignatureSnapshot.info(at: identity.realAppURL),
              Key(identity, info: info) == key else { return nil }
        var app = row
        app.isAppStoreApp = isAppStoreApp
        app.isIOSApp = isIOSApp
        app.isSystemApp = isSystemApp
        if app.appCount == 1 && !app.isFolder { app.containerKind = .singleAppContainer }
        Self.apply(mechanism, to: &app, identity: identity, info: info, bundleURL: url, localEntry: localEntry)
        return app
    }
}
