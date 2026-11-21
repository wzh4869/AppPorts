import Foundation

extension ResolvedAppIdentity {
    var bodyMigrationPolicy: AppBodyMigrationPolicy { AppBodyMigrationPolicy(bundleIdentifier: bundleIdentifier) }

    var bundleIsLocked: Bool? {
        (try? SignatureSnapshot.info(at: realAppURL)).map { $0.st_flags & UInt32(UF_IMMUTABLE) != 0 }
    }
}

/// Evidence about the real bundle. Update recommendations never authorize a write or a lock.
enum AppUpdateRoute: Equatable, Sendable {
    case appPorts, sparkle, shipIt, nativeShipIt, independent, moveOut, unknown
    case appStore(directory: URL)

    // Only add independent or move-out entries after an update and a cold launch were verified.
    static let verifiedApplications: [String: Self] = [
        "com.netease.163music": .sparkle,
        "com.tencent.workbuddy.mac": .shipIt,
        "com.deepseek.dsh": .shipIt
    ]

    private static let araeliumInstaller = "Frameworks/AraeliumUpdate.framework/Resources/AGUpdateInstaller.app/Contents/MacOS/AGUpdateInstaller"
    private static let mozillaInstaller = "MacOS/updater.app/Contents/MacOS/org.mozilla.updater"
    private static let googleUpdater = "Frameworks/Google Chrome Framework.framework/Versions/Current/Helpers/GoogleUpdater.app/Contents/MacOS/GoogleUpdater"
    private static let sparkle1Installer = "Frameworks/Sparkle.framework/Versions/Current/Resources/Autoupdate.app/Contents/MacOS/Autoupdate"
    private static let sparkle2Installer = "Frameworks/Sparkle.framework/Versions/Current/Autoupdate"
    private static let shipItInstaller = "Frameworks/Squirrel.framework/Resources/ShipIt"
    private static let independentUpdateExecutables = [
        "com.netease.163music": sparkle1Installer,
        "org.m0k.transmission": sparkle1Installer,
        "com.coteditor.CotEditor": sparkle2Installer,
        "com.colliderli.iina": sparkle2Installer,
        "com.aone.keka": sparkle2Installer,
        "uk.co.bzwrd.macperfmonitor": sparkle2Installer,
        "com.portkiller.app": sparkle2Installer,
        "com.qoder.app": shipItInstaller,
        "ai.opencode.desktop": shipItInstaller,
        "com.araelium.dmgcanvas": araeliumInstaller,
        "com.araeliumgroup.querious": araeliumInstaller,
        "com.araeliumgroup.screenflick": araeliumInstaller,
        "org.mozilla.firefox": mozillaInstaller,
        "org.mozilla.thunderbird": mozillaInstaller,
        "com.google.Chrome": googleUpdater,
        "dev.zed.Zed": "MacOS/zed",
        "com.jetbrains.toolbox": "MacOS/jetbrains-toolbox"
    ]

    static func inspect(_ identity: ResolvedAppIdentity, localEntry: URL? = nil, beforeMigration: Bool = true) -> Self {
        if identity.bodyMigrationPolicy == .localOnly { return .appPorts }
        let app = identity.realAppURL
        let contents = app.appendingPathComponent("Contents")
        let fm = FileManager.default
        if fm.fileExists(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path) {
            return .appStore(directory: app.deletingLastPathComponent().standardizedFileURL)
        }
        // An observed native install is stronger evidence than a bundled framework name.
        if let executable = independentUpdateExecutables[identity.bundleIdentifier] {
            let installer = contents.appendingPathComponent(executable).resolvingSymlinksInPath()
            if installer.path.hasPrefix(contents.resolvingSymlinksInPath().path + "/"),
               (try? installer.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
               fm.isExecutableFile(atPath: installer.path) {
                return executable == shipItInstaller ? .nativeShipIt : .independent
            }
        }
        if let verified = verifiedApplications[identity.bundleIdentifier] { return verified }
        let frameworks = contents.appendingPathComponent("Frameworks")
        if fm.fileExists(atPath: frameworks.appendingPathComponent("Squirrel.framework").path) { return .shipIt }
        if fm.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path) { return .sparkle }
        switch TauriUpdateSupport.mode(at: app) {
        case .native: return .independent
        case .sameVolumeTemporaryDirectory:
            if beforeMigration || TauriUpdateSupport.sharesSystemTemporaryVolume(app) == true { return .independent }
            guard let localEntry,
                  AppPortalMaintenance.preparedTauriIdentifier(localURL: localEntry, externalURL: app) == identity.bundleIdentifier
            else { return .unknown }
            return .independent
        case nil: break
        }
        return .unknown
    }

    func availability(in context: UpdateRecommendationContext, beforeStoreMigration: Bool = false) -> UpdateAvailability {
        switch self {
        case .appPorts: return .appPorts
        case .sparkle, .shipIt:
            guard context.guardian == .ready else {
                return context.guardian == .disabled ? .guardianDisabled : .guardianUnavailable
            }
            return self == .sparkle ? .inApp : .shipIt
        case .appStore(let directory):
            guard let destination = context.storeDirectory,
                  beforeStoreMigration || directory.path == destination.path else { return .unknown }
            return .store
        case .nativeShipIt: return context.guardian == .ready ? .shipIt : .inApp
        case .independent: return .inApp
        case .moveOut: return .moveOut
        case .unknown: return .unknown
        }
    }
}

struct UpdateRecommendationContext: Equatable {
    enum Guardian { case disabled, unavailable, ready }
    let guardian: Guardian
    let storeDirectory: URL?

    @MainActor
    init(enabled: Bool, ready: Bool, store: AppStoreExternalInstallSettings) {
        guardian = enabled ? (ready ? .ready : .unavailable) : .disabled
        storeDirectory = store.state == .ready ? store.destinationURL?.resolvingSymlinksInPath().standardizedFileURL : nil
    }

    init(guardian: Guardian, storeDirectory: URL? = nil) {
        self.guardian = guardian
        self.storeDirectory = storeDirectory
    }
}

enum UpdateAvailability {
    case appPorts, inApp, shipIt, store, moveOut, guardianDisabled, guardianUnavailable, unknown

    var badgeTitle: String {
        if self == .appPorts { return "自有" }
        if self == .guardianUnavailable { return "检测中" }
        return isAvailable ? "可用" : "未知"
    }

    var isAvailable: Bool {
        switch self {
        case .inApp, .shipIt, .store, .moveOut: return true
        case .appPorts, .guardianDisabled, .guardianUnavailable, .unknown: return false
        }
    }

    var explanation: String {
        switch self {
        case .appPorts: return "AppPorts 使用自有更新机制，不支持迁移到外部存储。请将它保留在本机的“应用程序”文件夹中。".localized
        case .inApp: return "可在应用内更新外盘副本。".localized
        case .shipIt: return "可在应用内更新。安装失败时，守护可尝试接手。".localized
        case .store: return "通过 App Store 更新外盘副本。".localized
        case .moveOut: return "更新到本机后，请将新版再次迁出。".localized
        case .guardianDisabled: return "更新守护已关闭，仍可尝试应用内更新。".localized
        case .guardianUnavailable: return "当前版本的更新守护尚未就绪。".localized
        case .unknown: return "尚未确认此应用迁移后的更新方式。".localized
        }
    }
}
